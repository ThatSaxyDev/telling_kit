import 'dart:async';
import 'dart:convert';
import 'dart:io' show gzip;

import 'package:dartnative/dartnative.dart';
import 'package:http/http.dart' as http;

import 'crash_reporter.dart';
import 'package:dartnative_shared_preferences/dartnative_shared_preferences.dart';
import 'device_info_collector.dart';
import 'models/device_metadata.dart';
import 'models/log_event.dart';
import 'models/session.dart';
import 'models/version_check_result.dart';
import 'rate_limiter.dart';
import 'utils/stack_trace_parser.dart';

/// The HTTP surface [Telling] uses.
///
/// Exists so the *request count* is testable. "How many network calls does this
/// add?" is the first question anyone should ask of an analytics SDK added to
/// an app, and it cannot be answered while `package:http` is called inline.
abstract interface class TellingTransport {
  /// POSTs a batch. Returns the HTTP status code.
  Future<int> postJson(String url, Map<String, String> headers, List<int> body);

  /// GETs JSON. Returns the status code and the decoded body.
  Future<TellingResponse> getJson(String url, Map<String, String> headers);
}

/// A status code plus a decoded JSON body.
class TellingResponse {
  const TellingResponse(this.statusCode, this.body);
  final int statusCode;
  final Map<String, dynamic> body;
}

/// The default transport, over `package:http`.
class HttpTellingTransport implements TellingTransport {
  const HttpTellingTransport();

  @override
  Future<int> postJson(String url, Map<String, String> headers, List<int> body) async {
    final response = await http.post(
      Uri.parse(url),
      headers: headers,
      body: body,
    );
    return response.statusCode;
  }

  @override
  Future<TellingResponse> getJson(String url, Map<String, String> headers) async {
    final response = await http.get(Uri.parse(url), headers: headers);
    final decoded = response.statusCode == 200 && response.body.isNotEmpty
        ? jsonDecode(response.body) as Map<String, dynamic>
        : const <String, dynamic>{};
    return TellingResponse(response.statusCode, decoded);
  }
}

/// True in a release (product) build, false in debug.
///
/// The Flutter original defaulted `enableDebugLogs` to `kDebugMode`. There is
/// no `kDebugMode` in dartnative, but the underlying constant is a VM
/// environment value that the AOT compiler folds, so the debug-log branches
/// still get tree-shaken out of a release build rather than merely disabled.
const bool _kReleaseBuild = bool.fromEnvironment('dart.vm.product');

/// Crash reporting, error tracking and analytics for DartNative apps.
///
/// A port of the Flutter `telling_logger` package. The public API and the wire
/// format are unchanged, so the same dashboard reads the same events:
///
/// ```dart
/// void main() {
///   DartNativePluginRegistrant.registerAll();
///   await Telling.instance.init('YOUR_API_KEY');
///   Telling.instance.enableCrashReporting();
///   Telling.instance.run(() => runApp(const MyApp()));
/// }
/// ```
///
/// ## Differences from `telling_logger`
///
/// * **Error capture is zone-based.** Flutter arms `FlutterError.onError` and
///   `PlatformDispatcher.instance.onError`; neither exists in DartNative, so
///   see [TellingCrashReporter] for what replaced them and [run] for the one
///   wiring requirement it adds.
/// * **Screen tracking is explicit.** `screenTracker` /
///   `goRouterScreenTracker` are gone — DartNative's `NavigatorObserver` is an
///   empty class and `App.navigatorObserver` is never invoked, so there is no
///   hook to subclass. Call [screenView] instead. Time-on-previous-screen is
///   still tracked automatically.
/// * **`.nowTelling()` still works**, reimplemented on dartnative's
///   `StatefulWidget` + `WidgetsBinding.addPostFrameCallback`.
class Telling implements TellingCrashSink {
  static final Telling _instance = Telling._internal();
  static Telling get instance => _instance;

  /// Base URL of the Telling ingestion API.
  ///
  /// Overridable for self-hosted deployments and integration tests; the
  /// Flutter original hardcoded it.
  static String serverUrl = 'https://telling-api.kiishi.space/api/v1';

  String? _apiKey;
  bool _initialized = false;
  DeviceMetadata? _deviceMetadata;
  static const String _storageKey = 'telling_logs_buffer';
  static const String _firstOpenKey = 'telling_first_open';
  static const String _lastAppVersionKey = 'telling_last_app_version';
  static const String _updateSnoozedUntilKey = 'telling_update_snoozed_until';
  static const String _snoozedMinVersionKey = 'telling_snoozed_min_version';
  bool _enableDebugLogs = false;

  // User context
  String? _userId;
  String? _userName;
  String? _userEmail;

  // User properties for segmentation
  final Map<String, dynamic> _userProperties = <String, dynamic>{};

  // Simple buffer to avoid spamming network
  final List<LogEvent> _buffer = <LogEvent>[];
  Timer? _flushTimer;
  Timer? _cleanupTimer;

  // Rate limiter
  final LogRateLimiter _rateLimiter = LogRateLimiter();

  // Session tracking
  Session? _currentSession;

  // Screen tracking
  DateTime? _screenStartTime;
  String? _currentScreen;

  // Crash capture
  TellingCrashReporter? _crashReporter;

  // Breadcrumbs for debugging context
  final List<Map<String, dynamic>> _breadcrumbs = <Map<String, dynamic>>[];
  static const int _maxBreadcrumbs = 20;

  Telling._internal();

  // Retry tracking for failed flushes
  int _consecutiveFailures = 0;
  static const int _maxConsecutiveFailures = 5;
  bool _permanentFailure = false;
  DateTime? _nextRetryTime;

  // Buffer limits
  static const int _maxBufferSize = 500;
  static const int _bufferTrimSize = 400; // Trim to this when max reached
  static const int _batchFlushSize = 20; // Flush when buffer hits this size

  /// How long to coalesce buffered events before sending them as one batch.
  ///
  /// Without this, every `captureException` — a handled failure the app already
  /// recovered from — triggered its own HTTP POST, because the old rule flushed
  /// immediately on `LogLevel.error`. With failure reporting wired into a
  /// per-tap action path and the poll loop, twenty failed taps meant twenty
  /// requests carrying one event each. Debouncing makes the request count a
  /// function of time, not of how chatty the user is.
  static const Duration _flushDebounce = Duration(seconds: 2);

  /// Debounce for the on-disk buffer, which was rewritten on every single log.
  static const Duration _persistDebounce = Duration(seconds: 2);

  Timer? _debouncedFlush;
  Timer? _debouncedPersist;
  bool _flushInFlight = false;

  static TellingTransport _transport = const HttpTellingTransport();

  /// The HTTP transport. Swappable so request counts can be asserted.
  static TellingTransport get transport => _transport;

  /// Route requests through [transport] instead of `package:http`. Test-only.
  static void debugUseTransport(TellingTransport transport) =>
      _transport = transport;

  /// Restore the real transport.
  static void debugResetTransport() => _transport = const HttpTellingTransport();

  /// Row `source` for events the SDK emits on its own lifecycle.
  static const String eventSourceSdk = 'sdk';

  /// Default row `source` for events an app passes in.
  static const String eventSourceApp = 'app';

  /// Whether [init] has completed.
  bool get isInitialized => _initialized;

  /// The app version this build reported, or null if device info could not be
  /// read.
  ///
  /// A null here is why [checkVersion] finds nothing: it short-circuits rather
  /// than asking the server to compare an unknown version.
  String? get currentAppVersion => _deviceMetadata?.appVersion;

  /// Initializes the Telling SDK.
  ///
  /// [apiKey] is the project key from the Telling dashboard. [enableDebugLogs]
  /// defaults to true in debug builds and false in release.
  Future<void> init(
    String apiKey, {
    String? userId,
    String? userName,
    String? userEmail,
    bool? enableDebugLogs,
    String? baseUrl,
  }) async {
    _apiKey = apiKey;
    _userId = userId;
    _userName = userName;
    _userEmail = userEmail;
    _enableDebugLogs = enableDebugLogs ?? !_kReleaseBuild;
    if (baseUrl != null && baseUrl.isNotEmpty) {
      serverUrl = baseUrl;
    }

    _initialized = true;

    final stopwatch = Stopwatch()..start();

    // Collect device metadata
    _deviceMetadata = await DeviceInfoCollector.collect();
    final afterDeviceInfo = stopwatch.elapsedMilliseconds;

    // Track lifecycle events
    await _trackLifecycleEvents();

    // Start new session
    _startNewSession();

    // Load persisted logs
    await _loadPersistedLogs();

    _startFlushTimer();

    // Setup app lifecycle listeners
    _setupAppLifecycleListeners();

    if (_enableDebugLogs) {
      // Timed because this used to run before the app's first frame, when its
      // cost was the splash screen's cost. Now it is off the critical path, and
      // this is how you notice if that changes.
      print(
        'Telling SDK Initialized in ${stopwatch.elapsedMilliseconds}ms '
        '(device info ${afterDeviceInfo}ms)',
      );
    }
  }

  /// Check if the app version meets the minimum required by the dashboard.
  ///
  /// Returns a [VersionCheckResult] indicating whether an update is needed and
  /// whether it is blocking.
  Future<VersionCheckResult> checkVersion() async {
    if (!_initialized || _apiKey == null) {
      if (_enableDebugLogs) print('Telling SDK not initialized');
      return VersionCheckResult.noUpdateRequired;
    }

    final currentVersion = _deviceMetadata?.appVersion;
    if (currentVersion == null) {
      return VersionCheckResult.noUpdateRequired;
    }

    try {
      final platform = _platformQueryName();
      if (platform == null) {
        return VersionCheckResult.noUpdateRequired;
      }

      final uri = Uri.parse('$serverUrl/project/version-check').replace(
        queryParameters: <String, String>{
          'platform': platform,
          'version': currentVersion,
        },
      );

      final response = await transport.getJson(
        uri.toString(),
        <String, String>{
          'x-api-key': _apiKey!,
          'Content-Type': 'application/json',
        },
      );

      if (response.statusCode != 200) {
        if (_enableDebugLogs) {
          print(
            'Failed to check version: ${response.statusCode}',
          );
        }
        return VersionCheckResult.noUpdateRequired;
      }

      final data = response.body;

      final requiresUpdate = data['requiresUpdate'] as bool? ?? false;
      final isRequired = data['isRequired'] as bool? ?? false;
      final minVersion = data['minVersion'] as String?;

      // For non-compulsory updates, check if user has snoozed this version
      if (requiresUpdate && !isRequired && minVersion != null) {
        final isSnoozed = await _isUpdateSnoozed(minVersion);
        if (isSnoozed) {
          if (_enableDebugLogs) {
            print('Telling: Update snoozed for min version $minVersion');
          }
          _sdkLog(
            'update_check_completed',
            level: LogLevel.info,
            type: LogType.analytics,
            metadata: <String, dynamic>{
              'requires_update': true,
              'is_required': false,
              'min_version': minVersion,
              'current_version': currentVersion,
              'is_snoozed': true,
            },
          );
          return VersionCheckResult.noUpdateRequired;
        }
      }

      final result = VersionCheckResult(
        requiresUpdate: requiresUpdate,
        isRequired: isRequired,
        storeUrl: data['storeUrl'] as String?,
        message: data['message'] as String?,
        minVersion: minVersion,
      );

      _sdkLog(
        'update_check_completed',
        level: LogLevel.info,
        type: LogType.analytics,
        metadata: <String, dynamic>{
          'requires_update': result.requiresUpdate,
          'is_required': result.isRequired,
          'min_version': minVersion,
          'current_version': currentVersion,
          'is_snoozed': false,
        },
      );

      if (result.requiresUpdate) {
        _sdkLog(
          'update_prompted',
          level: LogLevel.info,
          type: LogType.analytics,
          metadata: <String, dynamic>{
            'is_required': result.isRequired,
            'min_version': minVersion,
            'current_version': currentVersion,
          },
        );
      }

      return result;
    } catch (e) {
      if (_enableDebugLogs) {
        print('Error checking version: $e');
      }
      return VersionCheckResult.noUpdateRequired;
    }
  }

  /// `'ios'` / `'android'`, or null when the server has nothing to say.
  String? _platformQueryName() {
    final os = _deviceMetadata?.platform;
    return switch (os) {
      'iOS' => 'ios',
      'Android' => 'android',
      _ => null,
    };
  }

  /// Check if the user has snoozed updates for a specific min version.
  Future<bool> _isUpdateSnoozed(String minVersion) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final snoozedUntilStr = prefs.getString(_updateSnoozedUntilKey);
      final snoozedMinVersion = prefs.getString(_snoozedMinVersionKey);

      if (snoozedUntilStr == null || snoozedMinVersion == null) {
        return false;
      }

      // A snooze is scoped to the version that triggered it — bumping the
      // minimum version re-prompts even inside an active snooze window.
      if (snoozedMinVersion != minVersion) {
        return false;
      }

      final snoozedUntil = DateTime.tryParse(snoozedUntilStr);
      if (snoozedUntil == null) {
        return false;
      }

      return DateTime.now().isBefore(snoozedUntil);
    } catch (e) {
      if (_enableDebugLogs) {
        print('Telling: Failed to check snooze state: $e');
      }
      return false;
    }
  }

  /// Suppress the update prompt for [days] days (0-3).
  ///
  /// The snooze is scoped to [minVersion]: bumping the minimum version on the
  /// dashboard re-prompts immediately.
  Future<void> snoozeUpdate({
    required int days,
    required String minVersion,
  }) async {
    if (!_initialized || _apiKey == null) {
      if (_enableDebugLogs) print('Telling SDK not initialized');
      return;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final clampedDays = days.clamp(0, 3);
      final snoozeUntil = DateTime.now().add(Duration(days: clampedDays));

      await prefs.setString(_updateSnoozedUntilKey, snoozeUntil.toIso8601String());
      await prefs.setString(_snoozedMinVersionKey, minVersion);

      if (_enableDebugLogs) {
        print('Telling: Update snoozed for $clampedDays day(s)');
      }

      _sdkLog(
        'update_snoozed',
        level: LogLevel.info,
        type: LogType.analytics,
        metadata: <String, dynamic>{
          'snooze_days': clampedDays,
          'min_version': minVersion,
          'current_version': _deviceMetadata?.appVersion,
        },
      );

      await _flush();
    } catch (e) {
      if (_enableDebugLogs) {
        print('Telling: Failed to snooze update: $e');
      }
    }
  }

  /// Record that the user accepted the update, before opening the store.
  Future<void> acceptUpdate({String? minVersion}) async {
    if (!_initialized || _apiKey == null) {
      if (_enableDebugLogs) print('Telling SDK not initialized');
      return;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_updateSnoozedUntilKey);
      await prefs.remove(_snoozedMinVersionKey);

      _sdkLog(
        'update_accepted',
        level: LogLevel.info,
        type: LogType.analytics,
        metadata: <String, dynamic>{
          'min_version': ?minVersion,
          'current_version': _deviceMetadata?.appVersion,
        },
      );

      await _flush();
    } catch (e) {
      if (_enableDebugLogs) {
        print('Telling: Failed to record update acceptance: $e');
      }
    }
  }

  /// Track first_open, app_update, and app_open lifecycle events.
  Future<void> _trackLifecycleEvents() async {
    // Prefs are a convenience here — they only decide whether this is a first
    // open and which version was last seen. An unwritable store must cost those
    // two lifecycle events, not the whole SDK: init() is awaited by the app's
    // main() before its first frame, so throwing here takes the app down with
    // observability switched off.
    final SharedPreferences prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (e) {
      if (_enableDebugLogs) {
        print('Telling: storage unavailable, skipping lifecycle events: $e');
      }
      _sdkLog(
        'app_open',
        level: LogLevel.info,
        type: LogType.analytics,
        metadata: <String, dynamic>{'storage': 'unavailable'},
      );
      return;
    }

    // Check for first open (new install)
    final hasOpenedBefore = prefs.getBool(_firstOpenKey) ?? false;
    if (!hasOpenedBefore) {
      _sdkLog(
        'first_open',
        level: LogLevel.info,
        type: LogType.analytics,
        metadata: <String, dynamic>{
          'app_version': _deviceMetadata?.appVersion,
          'install_time': DateTime.now().toUtc().toIso8601String(),
        },
      );
      await prefs.setBool(_firstOpenKey, true);
    }

    // Check for app update (version change)
    final lastVersion = prefs.getString(_lastAppVersionKey);
    final currentVersion = _deviceMetadata?.appVersion;
    if (lastVersion != null &&
        currentVersion != null &&
        lastVersion != currentVersion) {
      _sdkLog(
        'app_update',
        level: LogLevel.info,
        type: LogType.analytics,
        metadata: <String, dynamic>{
          'previous_version': lastVersion,
          'current_version': currentVersion,
        },
      );
    }
    if (currentVersion != null) {
      await prefs.setString(_lastAppVersionKey, currentVersion);
    }

    // Always log app_open
    _sdkLog(
      'app_open',
      level: LogLevel.info,
      type: LogType.analytics,
      metadata: <String, dynamic>{
        'app_version': _deviceMetadata?.appVersion,
      },
    );
  }

  /// Enable automatic capture of uncaught errors.
  ///
  /// DartNative replacement for the Flutter original's `FlutterError.onError` /
  /// `PlatformDispatcher.instance.onError` assignment. See
  /// [TellingCrashReporter] for why those hooks are unavailable and what this
  /// uses instead.
  ///
  /// Pair it with [run] around the app body:
  ///
  /// ```dart
  /// Telling.instance.enableCrashReporting();
  /// Telling.instance.run(() => runApp(const MyApp()));
  /// ```
  void enableCrashReporting() {
    if (!_initialized) {
      if (_enableDebugLogs) {
        print(
          'Telling SDK not initialized. Call Telling.instance.init() first.',
        );
      }
      return;
    }

    armCrashCapture();

    if (_enableDebugLogs) {
      print('Telling: Crash reporting enabled');
    }
  }

  /// Installs the zone and isolate listener WITHOUT waiting for [init].
  ///
  /// ## Why this exists
  ///
  /// Capture has always been safe to arm early — the reporter only forwards
  /// through [log], which drops anything before init. What was not safe was the
  /// ordering in `main()`: apps had to `await init(...)` *before* `runApp()`,
  /// so the SDK's device-info and storage reads — a dozen synchronous FFI
  /// round-trips — held the splash screen for the whole of it.
  ///
  /// Arming here and initializing after the first frame moves that cost off the
  /// critical path entirely. The trade is honest and small: a crash in the few
  /// milliseconds between `runApp()` and the deferred `init()` is captured by
  /// the zone and the isolate listener but then dropped by [log], because there
  /// is no session to file it against yet.
  ///
  /// Idempotent, and safe to call with no API key configured.
  void armCrashCapture() {
    (_crashReporter ??= TellingCrashReporter(telling: this)).install();
  }

  /// The crash reporter, once [enableCrashReporting] has run. Null otherwise.
  TellingCrashReporter? get crashReporter => _crashReporter;

  /// Runs [body] inside the zone that captures uncaught async errors.
  ///
  /// Required by [enableCrashReporting] — see [TellingCrashReporter.run].
  /// A no-op passthrough when crash reporting is off, so calling it
  /// unconditionally in `main()` costs nothing.
  void run(void Function() body) {
    final reporter = _crashReporter;
    if (reporter == null) {
      body();
      return;
    }
    reporter.run(body);
  }

  @override
  void reportCrash(
    String message, {
    required Object error,
    StackTrace? stackTrace,
    required LogLevel level,
    required Map<String, dynamic> metadata,
    String? source,
  }) {
    log(
      message,
      level: level,
      error: error,
      stackTrace: stackTrace,
      type: LogType.crash,
      metadata: metadata,
      source: source ?? eventSourceSdk,
    );
  }

  /// Capture and report an exception.
  ///
  /// Use this to report exceptions you have caught in try/catch blocks, so
  /// handled failures still reach the dashboard.
  ///
  /// ```dart
  /// try {
  ///   await riskyOperation();
  /// } catch (e, stackTrace) {
  ///   Telling.instance.captureException(
  ///     error: e,
  ///     stackTrace: stackTrace,
  ///     context: 'checkout_flow',
  ///   );
  /// }
  /// ```
  void captureException({
    required Object error,
    StackTrace? stackTrace,
    String? context,
    Map<String, dynamic>? metadata,
    String source = eventSourceApp,
  }) {
    final enrichedMetadata = <String, dynamic>{
      'exception_type': error.runtimeType.toString(),
      'context': ?context,
      ...?metadata,
    };

    log(
      error.toString(),
      level: LogLevel.error,
      error: error,
      stackTrace: stackTrace,
      metadata: enrichedMetadata,
      type: LogType.crash,
      source: source,
    );
  }

  /// Track an analytics event.
  void event(
    String name, {
    Map<String, dynamic>? properties,
    String source = eventSourceApp,
  }) {
    log(
      name,
      level: LogLevel.info,
      metadata: properties,
      type: LogType.analytics,
      source: source,
    );
  }

  /// Track a funnel step.
  ///
  /// **IMPORTANT:** For accurate funnel analysis, call `setUser()` BEFORE
  /// tracking any funnel steps. If you call `setUser()` mid-funnel the backend
  /// sees the steps as belonging to different users, breaking the funnel.
  void trackFunnel({
    required String funnelName,
    required String stepName,
    int? step,
    Map<String, dynamic>? properties,
    String source = eventSourceApp,
  }) {
    log(
      'Funnel: $funnelName - $stepName',
      level: LogLevel.info,
      type: LogType.analytics,
      metadata: <String, dynamic>{
        'funnel_name': funnelName,
        'funnel_step_name': stepName,
        'funnel_step_number': ?step,
        ...?properties,
        'source': source,
      },
    );
  }

  /// Set user context. Call after the user logs in.
  void setUser({required String userId, String? userName, String? userEmail}) {
    if (!_initialized) {
      if (_enableDebugLogs) {
        print(
          'Telling SDK not initialized. Call Telling.instance.init() first.',
        );
      }
      return;
    }

    _userId = userId;
    _userName = userName;
    _userEmail = userEmail;

    // Start a new session with the updated user context
    _endSession();
    _startNewSession();

    if (_enableDebugLogs) {
      print('Telling: User context updated - $userId');
    }

    _sdkLog(
      'User identified',
      level: LogLevel.info,
      type: LogType.analytics,
      metadata: <String, dynamic>{
        'userId': userId,
        'userName': ?userName,
        'userEmail': ?userEmail,
      },
    );
  }

  /// Clear user context. Call after the user logs out.
  void clearUser() {
    if (!_initialized) {
      if (_enableDebugLogs) {
        print(
          'Telling SDK not initialized. Call Telling.instance.init() first.',
        );
      }
      return;
    }

    if (_enableDebugLogs) {
      print('Telling: User context cleared');
    }

    _sdkLog('User logged out', level: LogLevel.info, type: LogType.analytics);

    _userId = null;
    _userName = null;
    _userEmail = null;

    // Start a new anonymous session
    _endSession();
    _startNewSession();
  }

  /// Updates the display name of the current user WITHOUT ending the session.
  ///
  /// [setUser] is the only other way to change what `userName` reports, and it
  /// deliberately ends the session — correct for a genuinely different user,
  /// wrong for the same person picking a new display name.
  ///
  /// ## Why this exists
  ///
  /// The server chains funnel steps on `session_id`
  /// (`JOIN stepN prev ON l.session_id = prev.session_id`, grouped by session),
  /// so a conversion only counts when both steps share a session. A rename that
  /// went through [setUser] would split a user's onboarding funnel in half —
  /// `account_created` in one session, `steps_connected` in the next, and the
  /// join matching nothing. This keeps the label change out of the session
  /// lifecycle entirely.
  ///
  /// Emits a `name_changed` analytics event carrying both names, so renames are
  /// queryable rather than only inferable from a session boundary.
  ///
  /// No-op when [userName] matches what is already set — otherwise a poll that
  /// re-sends the same name would emit an event on every cycle.
  void setUserName(String? userName) {
    if (!_initialized) return;
    if (userName == _userName) return;

    final previous = _userName;
    _userName = userName;

    _sdkLog(
      'name_changed',
      level: LogLevel.info,
      type: LogType.analytics,
      metadata: <String, dynamic>{
        'previous_name': ?previous,
        'new_name': ?userName,
        'user_id': ?_userId,
      },
    );
  }

  /// Set a single user property.
  void setUserProperty({required String key, required dynamic value}) {
    _userProperties[key] = value;

    _sdkLog(
      'User property set',
      type: LogType.analytics,
      metadata: <String, dynamic>{
        'property_key': key,
        'property_value': value,
      },
    );
  }

  /// Set multiple user properties at once.
  void setUserProperties(Map<String, dynamic> properties) {
    _userProperties.addAll(properties);

    _sdkLog(
      'User properties set',
      type: LogType.analytics,
      metadata: <String, dynamic>{'properties': properties},
    );
  }

  /// Get a user property value.
  dynamic getUserProperty(String key) => _userProperties[key];

  /// Clear a specific user property.
  void clearUserProperty(String key) => _userProperties.remove(key);

  /// Clear all user properties.
  void clearUserProperties() => _userProperties.clear();

  /// Internal: add a breadcrumb for debugging context.
  void _addBreadcrumb(String message, {Map<String, dynamic>? metadata}) {
    if (!_initialized) return;

    final breadcrumb = <String, dynamic>{
      'message': message,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      ...?metadata,
    };

    _breadcrumbs.add(breadcrumb);

    // Circular buffer — drop the oldest past the cap.
    if (_breadcrumbs.length > _maxBreadcrumbs) {
      _breadcrumbs.removeAt(0);
    }
  }

  /// Clear all breadcrumbs (called on new session).
  void _clearBreadcrumbs() => _breadcrumbs.clear();

  /// Record a screen view.
  ///
  /// Replaces the Flutter original's `screenTracker` / `goRouterScreenTracker`
  /// NavigatorObservers. DartNative's `NavigatorObserver` is an empty class and
  /// `App.navigatorObserver` is never invoked, so there is nothing to subclass
  /// — screen changes are reported explicitly:
  ///
  /// ```dart
  /// Telling.instance.screenView('race_detail');
  /// ```
  ///
  /// Re-entering the screen currently recorded is ignored, and the time spent
  /// on the previous screen is logged automatically on every accepted call.
  void screenView(String screenName, {String? previousScreen}) {
    if (screenName == _currentScreen) {
      return;
    }
    _handleScreenView(screenName, previousScreen: previousScreen);
  }

  /// Handle screen view events.
  ///
  /// One row per navigation, carrying the duration of the screen being left.
  /// The Flutter original emitted two — `Screen view: X` plus `Screen view
  /// ended: Y` — which doubled the highest-volume event in the app and, worse,
  /// lost the final screen's duration because the "ended" row only ever fired on
  /// the *next* navigation. Folding the duration into the view row halves the
  /// rows and makes the total add up.
  ///
  /// The message is the constant `'screen_view'` rather than `'Screen view: X'`
  /// because `/analytics/events` returns `DISTINCT message`: a per-screen
  /// message turns every screen into its own entry in the event list.
  void _handleScreenView(String screenName, {String? previousScreen}) {
    final now = DateTime.now();
    final left = _currentScreen;
    final leftAt = _screenStartTime;

    _currentScreen = screenName;
    _screenStartTime = now;

    if (_enableDebugLogs) {
      print('Telling: Screen view - $screenName');
    }

    _sdkLog(
      'screen_view',
      level: LogLevel.info,
      type: LogType.analytics,
      metadata: <String, dynamic>{
        'source': 'navigation',
        'screen': screenName,
        'previous_screen': ?(previousScreen ?? left),
        // Null on the first screen of a session: there is no previous one.
        'seconds_on_previous': left == null || leftAt == null
            ? null
            : now.difference(leftAt).inSeconds,
      },
    );
  }

  /// Records the duration of the screen still open when the session ends.
  ///
  /// Without this the last screen of every session has no recorded duration —
  /// it would only appear on the next navigation, which for a final screen may
  /// never come. One row per session, against the many it replaces.
  void _closeOutScreen() {
    final screen = _currentScreen;
    final openedAt = _screenStartTime;
    if (screen == null || openedAt == null) return;

    _sdkLog(
      'screen_view',
      level: LogLevel.info,
      type: LogType.analytics,
      metadata: <String, dynamic>{
        'source': 'navigation',
        'screen': screen,
        'seconds_on_previous': DateTime.now().difference(openedAt).inSeconds,
        'final': true,
      },
    );
    _currentScreen = null;
    _screenStartTime = null;
  }

  /// Emits an SDK-lifecycle event, stamped [eventSourceSdk].
  ///
  /// Everything the SDK decides on its own — session boundaries, app_open,
  /// first_open, screen views, user-context changes — goes through here so a
  /// database reader can separate it from anything the app asked for.
  void _sdkLog(
    String message, {
    LogLevel level = LogLevel.info,
    Object? error,
    StackTrace? stackTrace,
    Map<String, dynamic>? metadata,
    LogType type = LogType.general,
  }) => log(
    message,
    level: level,
    error: error,
    stackTrace: stackTrace,
    metadata: metadata,
    type: type,
    source: eventSourceSdk,
  );

  /// Log a message.
  ///
  /// This is the single funnel every other method in this class drains
  /// through — [event], [captureException], [screenView] and the `.nowTelling()`
  /// extension all end up here.
  void log(
    String message, {
    LogLevel level = LogLevel.info,
    Object? error,
    StackTrace? stackTrace,
    Map<String, dynamic>? metadata,
    LogType type = LogType.general,
    String source = eventSourceApp,
  }) {
    if (!_initialized) {
      if (_enableDebugLogs) {
        print(
          'Telling SDK not initialized. Call Telling.instance.init() first.',
        );
      }
      return;
    }

    // Build metadata with breadcrumbs for all logs (activity trail context).
    // `source` is stamped on EVERY row so a row in the database says where it
    // came from without the app source open: 'sdk' for the SDK's own lifecycle
    // events, or the emitting subsystem for app-driven ones ('navigation',
    // 'progression', 'onboarding', 'app'). Analytics tables are read far more
    // often than written, and an unattributable row is one you cannot reason
    // about later.
    final enrichedMetadata = <String, dynamic>{
      'source': source,
      ...?metadata,
      if (_breadcrumbs.isNotEmpty)
        'breadcrumbs': List<Map<String, dynamic>>.from(_breadcrumbs),
    };

    // Parse stack trace into structured elements.
    final rawStackTrace =
        stackTrace?.toString() ??
        (error is Error ? error.stackTrace?.toString() : null);

    List<Map<String, String>>? parsedElements;
    if (rawStackTrace != null && rawStackTrace.isNotEmpty) {
      try {
        final frames = parseStackTrace(
          stackTrace ??
              (error is Error ? error.stackTrace! : StackTrace.current),
        );
        if (frames.isNotEmpty) {
          parsedElements = stackFramesToJson(frames);
        }
      } catch (e) {
        // Parsing failed, continue without structured elements.
        if (_enableDebugLogs) {
          print('Telling: Failed to parse stack trace: $e');
        }
      }
    }

    final event = LogEvent(
      type: type,
      level: level,
      message: message,
      timestamp: DateTime.now().toUtc(),
      stackTrace: rawStackTrace,
      stackTraceElements: parsedElements,
      metadata: enrichedMetadata.isNotEmpty ? enrichedMetadata : null,
      deviceMetadata: _deviceMetadata,
      userId: _userId,
      userName: _userName,
      userEmail: _userEmail,
      sessionId: _currentSession?.sessionId,
    );

    if (!_rateLimiter.shouldSendLog(event)) {
      if (_enableDebugLogs) {
        print('Telling: Rate limited log (${event.level}/${event.type})');
      }
      return;
    }

    // Enforce buffer size limit — drop oldest logs if full.
    if (_buffer.length >= _maxBufferSize) {
      final dropCount = _buffer.length - _bufferTrimSize;
      _buffer.removeRange(0, dropCount);
      if (_enableDebugLogs) {
        print('Telling: Buffer full, dropped $dropCount oldest logs');
      }
    }

    _buffer.add(event);
    _rateLimiter.markLogSent(event);
    _schedulePersist();

    // Auto-add breadcrumb for analytics events (activity trail).
    if (type == LogType.analytics) {
      _addBreadcrumb(message, metadata: metadata);
    }

    // A fatal error means the process may be about to die, so that one case is
    // worth an immediate attempt. Everything else — including every handled
    // failure — waits for the debounce or the batch size.
    if (level == LogLevel.fatal || _buffer.length >= _batchFlushSize) {
      _debouncedFlush?.cancel();
      unawaited(_flush());
    } else {
      _scheduleFlush();
    }
  }

  void _scheduleFlush() {
    if (_debouncedFlush?.isActive ?? false) return;
    _debouncedFlush = Timer(_flushDebounce, () {
      _debouncedFlush = null;
      unawaited(_flush());
    });
  }

  void _schedulePersist() {
    if (_debouncedPersist?.isActive ?? false) return;
    _debouncedPersist = Timer(_persistDebounce, () {
      _debouncedPersist = null;
      unawaited(_persistLogs());
    });
  }

  /// Sends any buffered events now. Call before backgrounding.
  Future<void> flush() {
    _debouncedFlush?.cancel();
    _debouncedFlush = null;
    return _flush();
  }

  void _startFlushTimer() {
    _flushTimer?.cancel();
    // A backstop only: normal sends are debounced, so this catches the tail of a
    // quiet period rather than driving traffic on its own.
    _flushTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (_buffer.isNotEmpty) unawaited(_flush());
    });

    _cleanupTimer?.cancel();
    _cleanupTimer = Timer.periodic(const Duration(minutes: 2), (_) {
      _rateLimiter.cleanup();
    });
  }

  Future<void> _flush() async {
    if (_buffer.isEmpty) return;

    // Two overlapping flushes would each drain the buffer and POST separately,
    // which is the same waste the debounce exists to avoid. The in-flight one
    // picks up whatever arrived while it waited.
    if (_flushInFlight) {
      _scheduleFlush();
      return;
    }
    _flushInFlight = true;
    try {
      await _flushBuffer();
    } finally {
      _flushInFlight = false;
    }
    if (_buffer.isNotEmpty) _scheduleFlush();
  }

  /// Identity used for flush-time deduplication. Mirrors the rate limiter's
  /// notion of sameness: same message, level, stack trace AND metadata.
  static String _dedupeKey(LogEvent event) =>
      '${event.message}_${event.level}_${event.stackTrace ?? ''}_'
      '${event.metadata ?? ''}';

  Future<void> _flushBuffer() async {

    // Skip if we've hit permanent failure (e.g. a bad API key).
    if (_permanentFailure) {
      if (_enableDebugLogs) {
        print(
          'Telling: Skipping flush due to permanent failure (check API key)',
        );
      }
      return;
    }

    if (_nextRetryTime != null && DateTime.now().isBefore(_nextRetryTime!)) {
      if (_enableDebugLogs) {
        final waitSeconds =
            _nextRetryTime!.difference(DateTime.now()).inSeconds;
        print('Telling: Waiting ${waitSeconds}s before retry (backoff)');
      }
      return;
    }

    final apiKey = _apiKey;
    if (apiKey == null) {
      return;
    }

    // Deduplicate the buffer before sending.
    //
    // The key MUST include metadata. Hashing on message/level/stackTrace alone
    // — as the Flutter original did — collapses any two events that share a
    // message but differ in properties, keeping only the last. That silently
    // loses rows: `event('thing', {a: 1})` followed by
    // `event('thing', {a: 2})` arrives as one event, so a per-property
    // breakdown quietly under-counts. Metadata is what makes two events
    // different events at all.
    final uniqueLogs = <String, LogEvent>{};
    for (final log in _buffer) {
      uniqueLogs[_dedupeKey(log)] = log; // keeps the last occurrence
    }

    final eventsToSend = uniqueLogs.values.toList();
    final droppedByDedupe = _buffer.length - eventsToSend.length;
    _buffer.clear();

    if (droppedByDedupe > 0 && _enableDebugLogs) {
      print(
        'Telling: Deduplicated buffer: ${_buffer.length + droppedByDedupe} → ${eventsToSend.length} unique logs',
      );
    }

    try {
      final jsonPayload = jsonEncode(
        eventsToSend.map((e) => e.toJson()).toList(),
      );
      final jsonBytes = utf8.encode(jsonPayload);

      // gzip payloads over 1 KB to cut network overhead.
      final bool useCompression = jsonBytes.length > 1024;
      final List<int> body;
      final Map<String, String> headers = <String, String>{
        'Content-Type': 'application/json',
        'x-api-key': apiKey,
      };

      if (useCompression) {
        body = gzip.encode(jsonBytes);
        headers['Content-Encoding'] = 'gzip';
      } else {
        body = jsonBytes;
      }

      final statusCode = await transport.postJson(
        '$serverUrl/logs',
        headers,
        body,
      );

      if (statusCode == 200) {
        _consecutiveFailures = 0;
        _nextRetryTime = null;
        await _persistLogs();
      } else if (statusCode == 403) {
        // Forbidden — likely an invalid API key. Discard rather than retry.
        _consecutiveFailures++;

        if (_consecutiveFailures >= _maxConsecutiveFailures) {
          _permanentFailure = true;
          _buffer.clear();
          await _persistLogs();

          if (_enableDebugLogs) {
            print('━' * 60);
            print('🚨 Telling SDK: INVALID API KEY');
            print('━' * 60);
            print('Your API key is not recognized by the backend.');
            print('');
            print('To fix this:');
            print('1. Create a project in your Telling dashboard');
            print('2. Copy the project API key');
            print('3. Update Telling.instance.init() with the correct key');
            print('');
            print('Current API key: ${apiKey.substring(0, 8)}...');
            print('━' * 60);
          }
        } else {
          if (_enableDebugLogs) {
            print(
              'Telling: Invalid API key (attempt $_consecutiveFailures/$_maxConsecutiveFailures)',
            );
          }
          _buffer.clear();
          await _persistLogs();
        }
      } else {
        _consecutiveFailures++;
        _setBackoff();

        if (_consecutiveFailures >= _maxConsecutiveFailures) {
          if (_enableDebugLogs) {
            print(
              'Telling: Giving up after $_maxConsecutiveFailures failures. Status: $statusCode',
            );
          }
          _consecutiveFailures = 0;
          _nextRetryTime = null;
          // Keep logs in the buffer for the next app session.
        } else {
          if (_enableDebugLogs) {
            final backoffSeconds =
                _nextRetryTime!.difference(DateTime.now()).inSeconds;
            print(
              'Telling: Failed ($statusCode). Retry $_consecutiveFailures/$_maxConsecutiveFailures in ${backoffSeconds}s',
            );
          }
          _buffer.addAll(eventsToSend); // Retry.
        }
        await _persistLogs();
      }
    } catch (e) {
      _consecutiveFailures++;
      _setBackoff();

      if (_consecutiveFailures >= _maxConsecutiveFailures) {
        if (_enableDebugLogs) {
          print(
            'Telling: Connection issue, giving up after $_consecutiveFailures attempts. Logs persisted.',
          );
        }
        _consecutiveFailures = 0;
        _nextRetryTime = null;
        // Keep logs in the buffer for the next app session.
      } else {
        if (_enableDebugLogs) {
          final backoffSeconds =
              _nextRetryTime!.difference(DateTime.now()).inSeconds;
          print(
            'Telling: Connection issue. Retry $_consecutiveFailures/$_maxConsecutiveFailures in ${backoffSeconds}s',
          );
        }
        _buffer.addAll(eventsToSend); // Retry.
      }
      await _persistLogs();
    }
  }

  /// Exponential backoff: 5s, 10s, 20s, 40s, 80s.
  void _setBackoff() {
    final backoffSeconds = 5 * (1 << (_consecutiveFailures - 1));
    _nextRetryTime = DateTime.now().add(Duration(seconds: backoffSeconds));
  }

  Future<void> _persistLogs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final logsJson = _buffer.map((e) => jsonEncode(e.toJson())).toList();
      await prefs.setStringList(_storageKey, logsJson);
    } catch (e) {
      if (_enableDebugLogs) {
        print('Telling: Failed to persist logs: $e');
      }
    }
  }

  Future<void> _loadPersistedLogs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final logsJson = prefs.getStringList(_storageKey);

      if (logsJson != null && logsJson.isNotEmpty) {
        if (_enableDebugLogs) {
          print('Telling: Found ${logsJson.length} unsent logs on disk.');
        }
        for (final logString in logsJson) {
          try {
            final map = jsonDecode(logString) as Map<String, dynamic>;
            _buffer.add(LogEvent.fromJson(map));
          } catch (e) {
            if (_enableDebugLogs) {
              print('Telling: Error parsing persisted log: $e');
            }
          }
        }
        unawaited(_flush());
      }
    } catch (e) {
      if (_enableDebugLogs) {
        print('Telling: Failed to load persisted logs: $e');
      }
    }
  }

  // ===== Session Management =====

  /// Start a new session.
  void _startNewSession() {
    // Clear breadcrumbs for a fresh activity trail.
    _clearBreadcrumbs();

    _currentSession = Session(
      sessionId: _generateSessionId(),
      startTime: DateTime.now(),
      userId: _userId,
      userEmail: _userEmail,
      userName: _userName,
    );

    if (_enableDebugLogs) {
      print('Telling: Started session ${_currentSession!.sessionId}');
    }

    _sdkLog(
      'Session started',
      level: LogLevel.info,
      type: LogType.analytics,
      metadata: <String, dynamic>{
        'sessionId': _currentSession!.sessionId,
        'startTime': _currentSession!.startTime.toIso8601String(),
      },
    );
  }

  /// End the current session.
  void _endSession() {
    final session = _currentSession;
    if (session != null && session.isActive) {
      session.endTime = DateTime.now();

      if (_enableDebugLogs) {
        print(
          'Telling: Ended session ${session.sessionId} (duration: ${session.duration?.inSeconds}s)',
        );
      }

      _sdkLog(
        'Session ended',
        level: LogLevel.info,
        type: LogType.analytics,
        metadata: session.toJson(),
      );

      // Close out the open screen first, so its duration lands in this session
      // rather than being lost when the session id changes.
      _closeOutScreen();

      unawaited(_flush());
    }
  }

  DateTime? _lastBackgroundTime;
  static const Duration _sessionTimeout = Duration(minutes: 5);

  void _onAppPaused() {
    _lastBackgroundTime = DateTime.now();
    unawaited(_flush()); // Get logs out before a potential OS kill.
  }

  void _onAppResumed() {
    if (_lastBackgroundTime != null) {
      final timeInBackground = DateTime.now().difference(_lastBackgroundTime!);

      if (timeInBackground > _sessionTimeout) {
        // Session timed out — end the old one and start a new one.
        if (_enableDebugLogs) {
          print(
            'Telling: Session timed out (${timeInBackground.inMinutes}m). Starting new session.',
          );
        }
        _endSession();
        _startNewSession();
      } else if (_enableDebugLogs) {
        print(
          'Telling: Resuming session (backgrounded for ${timeInBackground.inSeconds}s)',
        );
      }
      _lastBackgroundTime = null;
    } else if (_currentSession == null) {
      _startNewSession();
    }
  }

  /// Generate a unique session ID.
  String _generateSessionId() {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final userPrefix = _userId ?? 'anon';
    return '${userPrefix}_$timestamp';
  }

  /// Setup app lifecycle listeners for session tracking.
  void _setupAppLifecycleListeners() {
    WidgetsBinding.instance.addObserver(_AppLifecycleObserver(
      onPause: _onAppPaused,
      onResume: _onAppResumed,
      onDetach: handleAppDetached,
    ));
  }

  /// Ends the session and makes a final flush attempt.
  ///
  /// Wired to `AppLifecycleState.detached`, and called by the crash reporter on
  /// the same transition — teardown can arrive through either path and the
  /// buffer should get one last chance onto the wire.
  @override
  void handleAppDetached() {
    _endSession();
  }

  /// Tears down timers and error capture. Does not clear the persisted buffer.
  void dispose() {
    _flushTimer?.cancel();
    _cleanupTimer?.cancel();
    _crashReporter?.uninstall();
  }
}

/// Observer for app lifecycle changes to manage sessions.
class _AppLifecycleObserver extends WidgetsBindingObserver {
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onDetach;

  _AppLifecycleObserver({
    required this.onPause,
    required this.onResume,
    required this.onDetach,
  });

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      onPause();
    } else if (state == AppLifecycleState.resumed) {
      onResume();
    } else if (state == AppLifecycleState.detached) {
      onDetach();
    }
  }
}

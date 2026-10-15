import 'dart:async';
import 'dart:isolate';

import 'package:dartnative/dartnative.dart';

import 'models/log_event.dart';
import 'telling.dart';

/// What [TellingCrashReporter] needs from the SDK.
///
/// A deliberately tiny interface rather than a `Telling` parameter: `Telling`
/// has a private constructor, so a reporter typed against it could not be
/// exercised in a unit test without standing up the whole singleton (device
/// info, prefs, timers, network). Against this interface the reporter's
/// classification and dedupe logic is testable in isolation, which is the only
/// part of it that carries real logic.
abstract interface class TellingCrashSink {
  /// Reports one captured crash.
  void reportCrash(
    String message, {
    required Object error,
    StackTrace? stackTrace,
    required LogLevel level,
    required Map<String, dynamic> metadata,
  });

  /// The process is going away — flush before it does.
  void handleAppDetached();
}

/// Wires uncaught-error capture onto Dart zones and the isolate error port.
///
/// ## Why this exists
///
/// The Flutter original arms two framework hooks in `enableCrashReporting()`:
///
/// ```dart
/// FlutterError.onError = ...                  // framework / build errors
/// PlatformDispatcher.instance.onError = ...  // uncaught async errors
/// ```
///
/// Neither exists in DartNative — there is no `FlutterError`, no
/// `PlatformDispatcher`, and dartnative renders synchronously on the main
/// thread with no separate framework error pipeline. `NavigatorObserver` is an
/// empty class for the same reason: the Flutter-compatible names exist so
/// imported code compiles, not because there is a hook behind them.
///
/// So capture is rebuilt on the two mechanisms that DO work on any Dart
/// runtime, both pure Dart and neither needing native support:
///
/// 1. [Isolate.addErrorListener] over a [RawReceivePort] — the only way to see
///    an error that escaped every `try`/`catch` and every zone handler, up to
///    and including a synchronous throw during `main()`. Closest equivalent to
///    `PlatformDispatcher.instance.onError`, and strictly stronger: it also
///    catches errors thrown outside any zone.
/// 2. [runZonedGuarded] — installed by [run] around the app body, so an async
///    gap (a `Future` with no `errorHandler`, a bare `await` that throws) is
///    reported rather than becoming an unhandled rejection the isolate reports
///    asynchronously with no user context.
///
/// ## Why both
///
/// The isolate listener alone is not enough in the common case: once the app
/// body runs inside `runZonedGuarded`, async errors land in the ZONE handler,
/// not the isolate port. The zone alone misses errors thrown before the zone is
/// entered, and errors from other isolates. Registering both means every path
/// terminates somewhere Telling sees.
///
/// ## Duplicate suppression
///
/// One fatal error is commonly reported twice: once by the zone handler and
/// once by the isolate port, because an error propagating out of
/// `runZonedGuarded` reaches the isolate anyway. Fingerprints (type + message +
/// top stack frame) are collapsed inside a short window, so a crash is one
/// crash report rather than two.
///
/// ## Usage
///
/// ```dart
/// void main() {
///   DartNativePluginRegistrant.registerAll();
///   Telling.instance.init('API_KEY');
///   Telling.instance.enableCrashReporting();
///   Telling.instance.run(() => runApp(const MyApp()));
/// }
/// ```
///
/// `run` must wrap the whole app body. `init` deliberately stays outside it so
/// an error thrown during initialization is still caught.
class TellingCrashReporter with WidgetsBindingObserver {
  /// Creates a reporter that forwards to [telling].
  TellingCrashReporter({this.telling});

  /// Where captured crashes go. Defaults to [Telling.instance].
  final TellingCrashSink? telling;

  /// How long a fingerprint stays suppressed, collapsing the zone + isolate
  /// double-report of one error into one report.
  static const Duration dedupeWindow = Duration(seconds: 2);

  final Map<String, DateTime> _recentFingerprints = <String, DateTime>{};
  RawReceivePort? _errorPort;
  bool _installed = false;

  TellingCrashSink get _target => telling ?? Telling.instance;

  /// Arms both capture paths. Idempotent.
  ///
  /// Call AFTER `Telling.instance.init()`, since a captured error is logged
  /// through the SDK and a not-yet-initialized SDK would drop it.
  ///
  /// `Isolate.current.addErrorListener` must run on the app's root isolate, so
  /// call this from `main()` rather than from inside a zone this package made.
  void install() {
    if (_installed) {
      return;
    }
    _installed = true;

    // Path 1: the isolate error port.
    final port = RawReceivePort(_onIsolateError);
    _errorPort = port;
    Isolate.current.addErrorListener(port.sendPort);

    // Path 2: lifecycle, so a session ends when the app is torn down.
    // WidgetsBindingObserver IS genuinely implemented in dartnative, unlike
    // the error hooks.
    WidgetsBinding.instance.addObserver(this);
  }

  /// Removes the isolate listener and the lifecycle observer.
  void uninstall() {
    if (!_installed) {
      return;
    }
    _installed = false;

    final port = _errorPort;
    if (port != null) {
      Isolate.current.removeErrorListener(port.sendPort);
      port.close();
      _errorPort = null;
    }

    WidgetsBinding.instance.removeObserver(this);
  }

  /// Runs [body] inside a guarded zone, reporting anything that escapes.
  ///
  /// Use this INSTEAD of a bare `runZonedGuarded` — nesting the app body in a
  /// second zone is exactly what produces the duplicate reports described
  /// above, and it guarantees the zone handler is installed even if [install]
  /// ran in a different zone.
  ///
  /// Deliberately `void`-typed rather than generic: the body is always an app
  /// entry point like `runApp`, and a generic `R` would have to reconcile
  /// `runZonedGuarded`'s `R?` (null when the body throws) with a non-nullable
  /// `R`, silently converting a reported crash into a bogus null. An app that
  /// owns its own zone can forward through [handleZoneError] instead.
  void run(void Function() body) {
    runZonedGuarded<void>(body, handleZoneError);
  }

  /// The zone handler. Exposed so an app that owns its own `runZonedGuarded`
  /// can forward into Telling instead of nesting zones.
  void handleZoneError(Object error, StackTrace stackTrace) {
    _report(error, stackTrace, source: 'zone', level: _severityFor(error));
  }

  void _onIsolateError(dynamic message) {
    // The port delivers `[errorString, stackTraceString]` — both already
    // stringified, so the original objects are gone. `stack_trace` can still
    // parse the text, which is what the dashboard groups on.
    final parts = message is List ? message : const <dynamic>[];
    final errorText =
        parts.isNotEmpty ? parts.first.toString() : 'Unknown error';
    final stackText =
        parts.length > 1 && parts[1] != null ? parts[1].toString() : null;

    _report(
      errorText,
      stackText == null ? null : StackTrace.fromString(stackText),
      source: 'isolate',
      // Reached only for errors that escaped every zone, which are fatal by
      // definition. This is the Flutter original's PlatformDispatcher path.
      fatal: true,
    );
  }

  void _report(
    Object error,
    StackTrace? stackTrace, {
    required String source,
    LogLevel? level,
    bool fatal = false,
  }) {
    if (!_shouldReport(error, stackTrace)) {
      return;
    }

    _target.reportCrash(
      'Uncaught ${error.runtimeType}: $error',
      error: error,
      stackTrace: stackTrace,
      level: fatal ? LogLevel.fatal : (level ?? LogLevel.fatal),
      metadata: <String, dynamic>{
        'capture_source': source,
        'uncaught': true,
      },
    );
  }

  /// Severity split carried over from the Flutter original: framework build and
  /// layout failures were logged as warnings, everything else fatal.
  ///
  /// DartNative has no framework error pipeline to classify, so this keys off
  /// the same substrings the original matched on. It matters because layout
  /// noise is common and would otherwise flood the crash list.
  static LogLevel _severityFor(Object error) {
    final text = error.toString().toLowerCase();
    const layoutMarkers = <String>[
      'overflow',
      'renderflex',
      'renderbox',
      'constraints',
      'disposed',
      'trying to render',
    ];
    return layoutMarkers.any(text.contains) ? LogLevel.warning : LogLevel.fatal;
  }

  bool _shouldReport(Object error, StackTrace? stackTrace) {
    final now = DateTime.now();
    _expireFingerprints(now);

    final fingerprint = _fingerprint(error, stackTrace);
    final previous = _recentFingerprints[fingerprint];
    if (previous != null && now.difference(previous) < dedupeWindow) {
      return false;
    }
    _recentFingerprints[fingerprint] = now;
    return true;
  }

  void _expireFingerprints(DateTime now) {
    if (_recentFingerprints.length < 32) {
      return;
    }
    _recentFingerprints.removeWhere(
      (_, DateTime at) => now.difference(at) > dedupeWindow,
    );
  }

  /// Type + message + top stack frame. Enough to collapse one crash's zone +
  /// isolate double-report, without collapsing two genuinely different crashes
  /// that happen to share an error type.
  String _fingerprint(Object error, StackTrace? stackTrace) {
    final frames = stackTrace?.toString().trim().split('\n') ?? const <String>[];
    final top =
        frames.isNotEmpty && frames.first.trim().isNotEmpty ? frames.first.trim() : '';
    return '${error.runtimeType}|$error|$top';
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      // The process is going away — get what we have on the wire before it
      // does. `_flush` is fire-and-forget by design, so this is the last
      // chance the buffer gets sent.
      _target.handleAppDetached();
    }
  }
}

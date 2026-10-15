import 'package:dartnative/dartnative.dart';

import 'dartnative_plugin_registrant.dart';
import 'package:telling_kit/telling_kit.dart';

/// Pass your key at run time — never commit it:
///
/// ```sh
/// dn run --dart-define=TELLING_API_KEY=your_key
/// ```
///
/// With no key the app still runs: every `Telling` call degrades to a no-op, so
/// the example is safe to run before you have one.
const _apiKey = String.fromEnvironment('TELLING_API_KEY');

/// Point the SDK at a different ingestion host if you are self-hosting.
const _baseUrl = String.fromEnvironment('TELLING_BASE_URL');

void main() {
  // Platform bindings + (once you add plugins) their FFI symbols. Keep this
  // as the FIRST line of main().
  DartNativePluginRegistrant.registerAll();

  // Arm crash capture before anything else can throw. `armCrashCapture()`
  // installs the isolate error listener, which — unlike Flutter's
  // PlatformDispatcher.onError — also catches a synchronous throw here in
  // main(). It is safe to call before `init()`: events are buffered until the
  // SDK has a key to send them with.
  Telling.instance.armCrashCapture();

  // `run` installs the zone that catches the async gaps (an await that throws,
  // a Future with no error handler) the isolate reports without context. It
  // wraps the whole app body, so keep it outside `runApp`.
  Telling.instance.run(() {
    SystemChrome.defaultStyle = const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarBrightness: Brightness.light,
      statusBarIconBrightness: Brightness.dark,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.dark,
    );
    runApp(const ExampleApp());
  });
}

class ExampleApp extends StatefulWidget {
  const ExampleApp({super.key});

  @override
  State<ExampleApp> createState() => _ExampleAppState();
}

class _ExampleAppState extends State<ExampleApp> {
  @override
  void initState() {
    super.initState();
    _initTelling();
  }

  Future<void> _initTelling() async {
    if (_apiKey.isEmpty) return;

    await Telling.instance.init(
      _apiKey,
      baseUrl: _baseUrl.isEmpty ? null : _baseUrl,
      enableDebugLogs: true,
    );

    // Only now that the SDK can receive them: these are the two paths that
    // report uncaught errors.
    Telling.instance.enableCrashReporting();

    // Identify the user before tracking a funnel, or the backend sees the
    // steps as belonging to different people.
    Telling.instance.setUser(userId: 'example-user', userName: 'Example');

    // Explicit, because DartNative's NavigatorObserver is an empty class and
    // App.navigatorObserver is never invoked — there is no observer hook to
    // subclass, so screens are reported by hand.
    Telling.instance.screenView('example_home');
  }

  @override
  Widget build(BuildContext context) {
    return App(
      home: const _Home(),
    );
  }
}

class _Home extends StatelessWidget {
  const _Home();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('telling_kit')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _Section('Analytics'),
          _Action(
            'Track an event',
            () => Telling.instance.event(
              'example_tapped',
              properties: {'button': 'event', 'count': 1},
            ),
          ),
          _Action(
            'Track a funnel step',
            () => Telling.instance.trackFunnel(
              funnelName: 'onboarding',
              stepName: 'example_home',
              step: 1,
            ),
          ),
          _Action(
            'Identify a user',
            () => Telling.instance.setUser(
              userId: 'example-user-${DateTime.now().millisecondsSinceEpoch}',
              userName: 'Example',
            ),
          ),
          _Action(
            'Report a screen',
            () => Telling.instance.screenView('example_detail'),
          ),
          _Section('Logs'),
          for (final level in LogLevel.values)
            _Action('log(${level.name})', () => Telling.instance.log(
                  'hello at ${level.name}',
                  level: level,
                )),
          _Section('Errors'),
          _Action(
            'Capture a handled exception',
            () {
              try {
                throw StateError('a failure the app handled itself');
              } catch (error, stackTrace) {
                Telling.instance.captureException(
                  error: error,
                  stackTrace: stackTrace,
                  context: 'example_button',
                );
              }
            },
          ),
          _Action(
            'Crash for real',
            () {
              // Reaches the isolate error listener installed by
              // armCrashCapture(), and the example dies on purpose.
              Future<void>.delayed(
                Duration.zero,
                () => throw StateError('uncaught, on purpose'),
              );
            },
          ),
          _Section('Transport'),
          _Action(
            'Flush now',
            () => Telling.instance.flush(),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 8),
      child: Text(
        title,
        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action(this.label, this.onPressed);

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      // DartNative's native button. `ElevatedButton` / `TextButton` exist only
      // as Flutter-compat wrappers and are not on this import surface.
      child: SizedBox(
        width: double.infinity,
        child: Button(title: label, onPressed: onPressed),
      ),
    );
  }
}

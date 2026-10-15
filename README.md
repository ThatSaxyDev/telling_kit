# telling_kit

Telling for [DartNative](https://dartnative.com) — crash reporting, error
tracking and analytics, with the
[`telling_logger`](https://pub.dev/packages/telling_logger) API. Code written
against the Flutter package ports by changing one import.

```dart
// import 'package:telling_logger/telling_logger.dart';
import 'package:telling_kit/telling_kit.dart';
```

`telling_logger` declares `flutter: {sdk: flutter}` and depends on Flutter
plugins, so it cannot resolve in a DartNative app — DartNative omits
`flutter: sdk:` from its own pubspec to keep consumer lockfiles Flutter-free,
and its Zero engine calls native code over FFI instead of platform channels.
`telling_kit` keeps the API and the ingestion contract and replaces the five
Flutter-bound pieces:

| `telling_logger` | `telling_kit` |
| --- | --- |
| `shared_preferences` | `dartnative_shared_preferences` |
| `package_info_plus` | `dartnative_system`'s `PackageInfo` |
| `device_info_plus` | libc via `dart:ffi` — see [No native code](#no-native-code) |
| `FlutterError.onError`, `PlatformDispatcher.instance.onError` | Dart zones + an isolate error port |
| `NavigatorObserver` screen tracking | explicit `Telling.instance.screenView(...)` |
| `kDebugMode`, `kIsWeb` | `bool.fromEnvironment('dart.vm.product')` |

## Setup

```yaml
dependencies:
  telling_kit:
    hosted: https://dartpub.dev
    version: ^1.0.0
```

```sh
dn pub get
```

`dn pub get` picks the package up and generates the plugin registrant for you —
app developers add one dependency and touch nothing else. There is nothing to
link: no `.xcframework`, no `.aar`, no podspec, no gradle module.

## Quickstart

```dart
import 'package:dartnative/dartnative.dart';
import 'dartnative_plugin_registrant.dart';
import 'package:telling_kit/telling_kit.dart';

void main() {
  DartNativePluginRegistrant.registerAll();

  // Arm the isolate error listener before anything else can throw.
  Telling.instance.armCrashCapture();

  Telling.instance.run(() => runApp(const MyApp()));
}

Future<void> startTelling(String apiKey) async {
  await Telling.instance.init(apiKey);
  Telling.instance.enableCrashReporting();
}
```

Two rules, both load-bearing:

1. **`run(...)` must wrap the app body.** It installs the zone that catches the
   async gaps the isolate reports without user context. It is a no-op
   passthrough when crash reporting was never enabled, so calling it
   unconditionally is safe. An app that owns its own zone should forward into
   `TellingCrashReporter.handleZoneError` rather than nesting a second zone.
2. **Identify the user before tracking a funnel.** `setUser()` ends the current
   session, so calling it mid-funnel makes the backend see the steps as
   belonging to different people.

`init` is safe to call with no key at all — every `Telling` call then degrades
to a no-op, which is what makes this package testable in CI and debug builds
without a key.

### Self-hosting

`init` takes a `baseUrl`, which overrides the default ingestion host:

```dart
await Telling.instance.init(apiKey, baseUrl: 'https://your-host/api/v1');
```

Keep the key out of source. Read it from a build-time define:

```dart
const apiKey = String.fromEnvironment('TELLING_API_KEY');
```

## What you get

- **Analytics** — `event`, `trackFunnel`, `screenView`, and user identity
  (`setUser`, `clearUser`, `setUserName`, `setUserProperty`,
  `setUserProperties`).
- **Logs** — `log` at six levels (`trace` … `fatal`), typed `general` /
  `analytics` / `crash` / `performance`.
- **Errors** — `captureException` for handled failures, plus automatic capture
  of uncaught ones. `TellingTryCatch` (`tryRun`, `tryRunVoid`, `tryRunSync`)
  wraps calls that should report and carry on.
- **Version checks** — `checkVersion`, `snoozeUpdate`, `acceptUpdate`.
- **Transport** — gzip past 1 KB, offline persistence through
  `dartnative_shared_preferences`, replay with exponential backoff (5s → 80s).
  A burst of handled failures costs one request, not one per event.
- **Rate limiting** — 10 events/second, a 5s dedupe window and a 5s crash
  throttle, so a hot loop cannot flood ingestion.

## No native code

Device metadata does not need a plugin either. Both platforms expose what
`device_info_plus` reports through **libc**, which `DynamicLibrary.process()`
resolves directly:

- Apple: `sysctlbyname("hw.machine")` → `iPhone17,1`, the same string
  `IosInfo.utsname.machine` returns, so dashboards group identically.
- Android: `__system_property_get("ro.product.model")` and
  `ro.product.manufacturer`, joined the way `AndroidInfo` formats them.

Every lookup degrades to `null` on failure. Observability must never be the
thing that takes an app down.

## Crash capture

This is the one place the port is a genuine rewrite rather than a swap.
`enableCrashReporting()` arms both paths that work on any Dart runtime:

1. **`Isolate.addErrorListener`** over a `RawReceivePort` — sees anything that
   escaped every `try`/`catch` and every zone handler, *including* a synchronous
   throw during `main()`. Strictly stronger than Flutter's
   `PlatformDispatcher.instance.onError`, which only sees errors inside a zone.
   Call `armCrashCapture()` before `init()` so early throws are buffered rather
   than lost.
2. **`runZonedGuarded`**, installed by `Telling.instance.run(...)` around the app
   body — catches the async gaps (`Future` with no `errorHandler`, a bare
   `await` that throws) that the isolate reports asynchronously with no user
   context.

One fatal error is commonly reported by **both**, because an error propagating
out of `runZonedGuarded` still reaches the isolate. Crashes are fingerprinted
(type + message + top stack frame) and repeats inside a 2-second window are
collapsed, so a crash is one report.

Layout failures (`RenderFlex overflowed`, `constraints`, `disposed`, …) are
classified as **warnings**, everything else as **fatal** — the same substring
heuristic the Flutter version used, so an existing dashboard keeps separating
layout noise from real crashes.

## Screen tracking

`screenTracker` and `goRouterScreenTracker` are **gone**. DartNative's
`NavigatorObserver` is an empty class and `App.navigatorObserver` is never
invoked, so there is no hook to subclass — the Flutter-compatible name exists
so imported code compiles, not because anything calls it.

```dart
Telling.instance.screenView('race_detail');
```

Re-entering the current screen is ignored, and time-on-previous-screen is still
logged automatically.

## Example

`example/` is a runnable DartNative app wired to every feature — events,
funnels, logs at each level, a handled exception, and a real uncaught crash.

```sh
cd example
dn pub get
dn run --dart-define=TELLING_API_KEY=your_key
```

## Testing

```sh
dn test
```

`debugUseTransport` / `debugResetTransport` swap in a fake transport, so tests
can assert on request volume and payloads without a network.

## Relationship to `telling_logger`

Same API, same wire format, same dashboard. The Flutter package remains the
right choice for a Flutter app; this one exists because a DartNative app cannot
load it.

Files carried across unchanged — `lib/src/models/`, `lib/src/rate_limiter.dart`,
`lib/src/utils/stack_trace_parser.dart`, `lib/src/telling_try_catch.dart` —
are kept in the old `if (field != null) 'field': field` form rather than the
newer `?'field': field` marker, deliberately, so they stay diffable against the
Flutter original when re-syncing. Only `stack_trace_parser.dart`'s `column`
entry must keep the old form: `column.toString()` is never null, so the
null-aware marker would be a type error there.

## License

MIT — see [LICENSE](LICENSE).

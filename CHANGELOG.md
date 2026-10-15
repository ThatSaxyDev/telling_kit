## 1.0.0 (2026-10-15)

First release. The DartNative edition of
[`telling_logger`](https://pub.dev/packages/telling_logger) — same public API,
same wire format, same dashboard — with no Flutter and no method channels.

- `Telling.instance` with `init`, `run`, `flush`, `captureException`, `event`,
  `trackFunnel`, `log`, `screenView`, and user identity (`setUser`,
  `clearUser`, `setUserName`, `setUserProperty`, `setUserProperties`).
- **Uncaught-error capture** without Flutter. `enableCrashReporting()` arms an
  `Isolate.addErrorListener` over a `RawReceivePort` — which also sees a
  synchronous throw during `main()`, something Flutter's
  `PlatformDispatcher.instance.onError` cannot — and `run(...)` installs a
  `runZonedGuarded` around the app body to catch the async gaps the isolate
  reports with no user context. Crashes are fingerprinted by type, message and
  top stack frame, so one crash is one report rather than two.
- **Layout failures classified as warnings**, not crashes, by the same
  substring heuristic the Flutter edition used, so a dashboard keeps separating
  layout noise from real faults.
- **No native code.** `platform: {platforms: {}}` — no `.xcframework`, no
  `.aar`, no podspec, no gradle module. Adding this package costs nothing at
  build time.
- **Device metadata straight from libc** over `dart:ffi`:
  `sysctlbyname("hw.machine")` on Apple (the same string
  `IosInfo.utsname.machine` returns, so dashboards group identically) and
  `__system_property_get` for `ro.product.model` / `ro.product.manufacturer` on
  Android. Every lookup degrades to `null` on failure — observability must never
  be the thing that takes an app down.
- **Batching and offline persistence.** Events are gzipped past 1 KB, buffered
  through `dartnative_shared_preferences` when the network is unavailable, and
  replayed with exponential backoff (5s → 80s). A handled-failure burst costs
  one request, not one per event.
- **Rate limiting** — 10 events/second, a 5-second dedupe window, and a 5-second
  crash throttle — so a hot loop cannot flood the ingestion endpoint.
- **Sessions and funnels**, plus `TellingTryCatch` (`tryRun`, `tryRunVoid`,
  `tryRunSync`) for wrapping calls that auto-report.
- `checkVersion` / `snoozeUpdate` / `acceptUpdate` for in-app update checks, and
  `VersionCheckResult`.
- Test hooks `debugUseTransport` / `debugResetTransport` for asserting on
  request volume without a network.

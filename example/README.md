# telling_kit_example

A **dartnative** app exercising [`telling_kit`](../). `lib/main.dart` wires
crash capture in `main()` and puts a button on every feature: analytics events,
funnel steps, user identity, screen views, logs at each of the six levels, a
handled exception, a real uncaught crash, and a manual flush.

## Run it

```sh
dn pub get
dn run -d <device-id> --dart-define=TELLING_API_KEY=your_key
```

`TELLING_API_KEY` is optional — without it the SDK stays uninitialised and every
call is a no-op, so the app runs fine and simply reports nothing.

Hit **Crash for real** to watch an uncaught error travel: it reaches the isolate
error listener armed by `armCrashCapture()`, and the example dies on purpose.

dartnative apps require a license. Subscribe at
[dartpub.dev/framework](https://dartpub.dev/framework), copy your license key
(`dnk_...`) from the Framework panel, and configure it once:

```sh
dn config --license-key dnk_...
```

After that `dn run` just works, on every platform. (Prefer not to store the
key? Pass it per run instead: `dn run --dart-define=DN_LICENSE_KEY=dnk_...`.)

Always use **`dn`** for run/build/pub commands — not the underlying SDK CLI.

## Make it yours

- **Your UI** — edit `lib/main.dart`.
- **App icon + launch logo** — replace `assets/dn-logo.png` with your logo, then
  regenerate icon **and** splash in one step:
  ```sh
  dart run tool/generate_app_assets.dart --source=assets/dn-logo.png --bg=#000000
  ```
  (Splash only: `dart run dartnative_splash:setup`.)
- **Plugins** — browse **[dartpub.dev](https://dartpub.dev)**. Add a package to
  `pubspec.yaml`, run `dn pub get`, and import it — pure-Dart packages and
  dartnative plugins both work as-is.

## Don't touch (unless you know the runtime)

These files are the dartnative runner glue — they're why the app renders:
`ios/Runner/{AppDelegate,SceneDelegate}.swift` + the scene block in `Info.plist`,
and `android/.../{Application,MainActivity}.kt` + the Material3 themes in
`android/app/src/main/res/values*/styles.xml`.

> Dependency paths in `pubspec.yaml` assume this app sits beside
> `dartnative_framework`. Fix them if you created it elsewhere.

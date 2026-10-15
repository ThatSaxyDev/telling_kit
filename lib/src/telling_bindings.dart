import 'device_info_ffi.dart';

/// Idempotent warm-up for this package's native surface.
///
/// This package ships no native library of its own — the only FFI it performs
/// is against libc, which is already resident in the process — so there are no
/// plugin symbols to resolve here. `loadSymbols()` exists because the
/// generated `lib/dartnative_plugin_registrant.dart` calls it inside its
/// per-plugin guard on every `dn pub get`-driven launch, and a plugin that
/// declares a registrant block is expected to expose one.
///
/// It deliberately does NOT resolve the libc symbols eagerly. `dart:ffi`
/// symbol lookup throws on a host where the symbol is missing, and doing that
/// here would make a launch-time registrant call throw for a package whose
/// native needs are optional. The lookups happen lazily on first use inside
/// [DeviceInfoFFI], where each one already degrades to `null`.
///
/// Safe to call any number of times, from any thread, at any point in the
/// lifecycle — including in a unit test on the Dart VM, where it is a no-op.
abstract final class TellingBindings {
  static void loadSymbols() {
    // Intentionally empty. See the doc comment above: device metadata is read
    // lazily through DeviceInfoFFI, which handles its own failures.
  }
}

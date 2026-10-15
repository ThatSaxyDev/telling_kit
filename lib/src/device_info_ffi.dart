import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart';

/// Device metadata read straight out of libc through [dart:ffi].
///
/// Neither platform needs a native plugin for this: Apple exposes the hardware
/// identifier via `sysctlbyname("hw.machine")` and Android exposes the model
/// and manufacturer as read-only system properties. Both symbols live in libc,
/// so [DynamicLibrary.process] resolves them with no plugin, no podspec and no
/// `.aar` — which is what keeps this package free of native build steps.
///
/// Every lookup is best-effort. A missing symbol, an unsupported property or a
/// sandboxed host yields `null` rather than an exception; observability must
/// never be the thing that takes an app down.
abstract final class DeviceInfoFFI {
  static final DynamicLibrary _libc = DynamicLibrary.process();

  // sysctlbyname(name, oldp, oldlenp, newp, newlen) -> int
  // 0 on success, -1 on failure with errno set.
  //
  // `oldp`/`newp` are declared `Pointer<Void>` (the null pointers passed below
  // are nullptr) and `oldlenp` stays `Pointer<IntPtr>`; the Dart-side signature
  // must mirror that exactly or the FFI trampoline cannot be built.
  static final _sysctlbyname =
      _libc.lookupFunction<
          Int32 Function(Pointer<Utf8>, Pointer<Void>, Pointer<IntPtr>, Pointer<Void>, IntPtr),
          int Function(Pointer<Utf8>, Pointer<Void>, Pointer<IntPtr>, Pointer<Void>, int)>(
        'sysctlbyname',
      );

  // __system_property_get(name, value) -> int
  // Writes at most PROP_VALUE_MAX (92) bytes including the NUL and returns the
  // string length, or 0 when the property does not exist.
  static final _systemPropertyGet =
      _libc.lookupFunction<Int32 Function(Pointer<Utf8>, Pointer<Utf8>), int Function(Pointer<Utf8>, Pointer<Utf8>)>(
        '__system_property_get',
      );

  static const int _propValueMax = 92;

  /// True when [name] resolved in libc. False on a host where the platform's
  /// lookup symbol is unavailable, which makes both getters return `null`.
  static bool get available {
    try {
      _sysctlbyname;
      return true;
    } on ArgumentError {
      return false;
    }
  }

  /// The hardware identifier on Apple platforms — `iPhone17,1`,
  /// `arm64`/`x86_64` on the simulator, `MacBookPro18,3`.
  ///
  /// This is the same string `device_info_plus` reports as
  /// `IosInfo.utsname.machine`, so dashboards group the same devices.
  static String? appleHardwareIdentifier() {
    if (!Platform.isIOS && !Platform.isMacOS) {
      return null;
    }
    try {
      const maxLen = 256;
      final value = calloc<Char>(maxLen);
      final sizePtr = malloc<IntPtr>();
      try {
        sizePtr.value = maxLen;
        final name = 'hw.machine'.toNativeUtf8();
        try {
          final result = _sysctlbyname(
            name,
            value.cast<Void>(),
            sizePtr,
            nullptr,
            0,
          );
          if (result != 0) {
            return null;
          }
          final identifier = value.cast<Utf8>().toDartString();
          return identifier.isEmpty ? null : identifier;
        } finally {
          malloc.free(name);
        }
      } finally {
        calloc
          ..free(value)
          ..free(sizePtr);
      }
    } on Object {
      // Unresolved symbol, or an allocation failure. Neither is worth
      // failing a log flush over.
      return null;
    }
  }

  /// An Android system property, or `null` when it is unset or unreadable.
  static String? androidSystemProperty(String name) {
    if (!Platform.isAndroid) {
      return null;
    }
    try {
      final value = calloc<Uint8>(_propValueMax);
      try {
        final namePtr = name.toNativeUtf8();
        try {
          final length = _systemPropertyGet(namePtr, value.cast<Utf8>());
          if (length <= 0) {
            return null;
          }
          final property = value.cast<Utf8>().toDartString();
          return property.isEmpty ? null : property;
        } finally {
          malloc.free(namePtr);
        }
      } finally {
        calloc.free(value);
      }
    } on Object {
      return null;
    }
  }

  /// `"<manufacturer> <model>"` on Android — the same string
  /// `device_info_plus` builds from `AndroidInfo`.
  static String? androidDeviceModel() {
    final manufacturer = androidSystemProperty('ro.product.manufacturer');
    final model = androidSystemProperty('ro.product.model');
    final parts = <String>[
      ?manufacturer,
      ?model,
    ].where((part) => part.isNotEmpty).toSet().toList();
    return parts.isEmpty ? null : parts.join(' ');
  }
}

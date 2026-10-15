import 'dart:io' show Platform;

import 'package:dartnative_system/dartnative_system.dart';

import 'device_info_ffi.dart';
import 'models/device_metadata.dart';

/// Collects device metadata once during SDK initialization.
///
/// Ported from `telling_logger`'s `DeviceInfoCollector`. The upstream version
/// pulls from `device_info_plus` (a MethodChannel plugin) and
/// `package_info_plus`; here the app version comes from `dartnative_system`'s
/// FFI `PackageInfo` and the hardware fields come from libc via
/// [DeviceInfoFFI], so no Flutter plugin is involved.
///
/// The web, Windows and Linux branches are gone — DartNative targets iOS and
/// Android — and `kIsWeb` has no equivalent. Every field is nullable and a
/// failure anywhere degrades to a partial record rather than throwing.
class DeviceInfoCollector {
  /// Collects device metadata once during SDK initialization.
  ///
  /// Note: sessionId is managed separately in the Telling class.
  static Future<DeviceMetadata> collect() async {
    final platform = switch (Platform.operatingSystem) {
      'ios' => 'iOS',
      'macos' => 'macOS',
      'android' => 'Android',
      final other => other.isEmpty ? 'Unknown' : other,
    };

    final osVersion = Platform.operatingSystemVersion.trim().isEmpty
        ? null
        : Platform.operatingSystemVersion.trim();

    final deviceModel = switch (Platform.operatingSystem) {
      'ios' || 'macos' => DeviceInfoFFI.appleHardwareIdentifier(),
      'android' => DeviceInfoFFI.androidDeviceModel(),
      _ => null,
    };

    // PackageInfo is a synchronous native read behind a Future for API parity
    // with package_info_plus. It throws when the native side is missing from
    // the build, which must not cost us the metadata already collected.
    String? appVersion;
    String? appBuildNumber;
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      appVersion = packageInfo.version;
      appBuildNumber = packageInfo.buildNumber;
    } on Object {
      // Version reporting degrades; logging continues.
    }

    return DeviceMetadata(
      platform: platform,
      osVersion: osVersion,
      deviceModel: deviceModel,
      appVersion: appVersion,
      appBuildNumber: appBuildNumber,
    );
  }
}

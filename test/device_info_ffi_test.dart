import 'dart:io' show Platform;

import 'package:telling_kit/telling_kit.dart';
import 'package:test/test.dart';

void main() {
  group('DeviceInfoFFI', () {
    test('resolves libc and reports availability', () {
      // The whole point of doing this through libc rather than a native plugin:
      // no xcframework, no .aar, and the symbols are present on any host.
      expect(DeviceInfoFFI.available, isTrue);
    });

    test('appleHardwareIdentifier is gated to Apple platforms', () {
      final result = DeviceInfoFFI.appleHardwareIdentifier();
      if (Platform.isIOS || Platform.isMacOS) {
        expect(result, isNotNull);
        expect(result, isNotEmpty);
        // 'iPhone17,1', 'MacBookPro18,3' — never the literal 'Unknown'.
        expect(result, isNot('Unknown'));
      } else {
        expect(result, isNull, reason: 'must not read hw.machine off-Apple');
      }
    });

    test('__system_property_get returns a real model on Android', () {
      final model = DeviceInfoFFI.androidDeviceModel();
      if (Platform.isAndroid) {
        expect(model, isNotNull);
        expect(model, isNotEmpty);
      } else {
        expect(model, isNull, reason: 'must not read Android props off-Android');
      }
    });

    test('androidSystemProperty returns null for an unset property', () {
      // A property that certainly does not exist must come back null, not
      // throw and not an empty string.
      expect(DeviceInfoFFI.androidSystemProperty('ro.nope.definitely_unset'), isNull);
    });

    test('androidDeviceModel de-duplicates a manufacturer repeated in the model', () {
      // Many Android devices report model == manufacturer (Pixel 8 -> "Google
      // Pixel 8" from the Google/Pixel 8 pair). The join must not double it.
      if (!Platform.isAndroid) {
        expect(DeviceInfoFFI.androidDeviceModel(), isNull);
        return;
      }
      final model = DeviceInfoFFI.androidDeviceModel()!;
      final halves = model.split(' ');
      expect(halves.length, lessThanOrEqualTo(2));
    });
  });
}

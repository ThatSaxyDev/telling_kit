/// telling_kit — crash reporting, error tracking and analytics for
/// DartNative apps.
///
/// A DartNative port of the Flutter `telling_logger` package. Same API, same
/// wire format, same dashboard — with no Flutter and no MethodChannel.
///
/// ```dart
/// import 'package:telling_kit/telling_kit.dart';
///
/// void main() {
///   DartNativePluginRegistrant.registerAll();
///   Telling.instance.init('YOUR_API_KEY');
///   Telling.instance.enableCrashReporting();
///   Telling.instance.run(() => runApp(const MyApp()));
/// }
/// ```
library;

export 'src/crash_reporter.dart' show TellingCrashReporter, TellingCrashSink;
export 'src/device_info_ffi.dart' show DeviceInfoFFI;
export 'src/extensions/widget_tracking_extension.dart';
export 'src/models/device_metadata.dart';
export 'src/models/log_event.dart';
export 'src/models/session.dart' show Session;
export 'src/models/version_check_result.dart';
export 'src/telling.dart';
export 'src/telling_bindings.dart' show TellingBindings;
export 'src/telling_try_catch.dart';

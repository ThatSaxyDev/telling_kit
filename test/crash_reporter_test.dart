import 'dart:async';

import 'package:telling_kit/telling_kit.dart';
import 'package:test/test.dart';

import 'test_helpers.dart';

/// A [TellingCrashSink] that records what the reporter sent.
///
/// `Telling` itself cannot be used here: its constructor is private and
/// standing up the singleton would drag in device info, prefs, timers and the
/// network. The reporter is written against [TellingCrashSink] precisely so
/// its classification and dedupe logic — the only part of it with real logic —
/// is testable without any of that.
class RecordingCrashSink implements TellingCrashSink {
  final List<CapturedCrash> captured = <CapturedCrash>[];

  /// Take everything captured so far, leaving the sink empty.
  List<CapturedCrash> drain() {
    final out = List<CapturedCrash>.from(captured);
    captured.clear();
    return out;
  }

  @override
  void reportCrash(
    String message, {
    required Object error,
    StackTrace? stackTrace,
    required LogLevel level,
    required Map<String, dynamic> metadata,
  }) {
    captured.add(CapturedCrash(
      message: message,
      error: error,
      stackTrace: stackTrace,
      level: level,
      metadata: metadata,
    ));
  }

  @override
  void handleAppDetached() {}
}

/// One captured crash, flattened for assertion.
class CapturedCrash {
  final String message;
  final Object error;
  final StackTrace? stackTrace;
  final LogLevel level;
  final Map<String, dynamic> metadata;

  CapturedCrash({
    required this.message,
    required this.error,
    required this.stackTrace,
    required this.level,
    required this.metadata,
  });
}

void main() {
  group('severity classification', () {
    // Layout failures are warnings rather than fatal, matching the Flutter
    // original's substring heuristic. Layout noise is common and fatal-classing
    // it would drown real crashes.
    const layoutErrors = <String>[
      'A RenderFlex overflowed by 42 pixels',
      'RenderBox was not laid out',
      'Constraints violated',
      'This widget was disposed',
    ];

    test('classifies layout failures as warnings, not fatal', () {
      final sink = RecordingCrashSink();
      final reporter = TellingCrashReporter(telling: sink);

      for (final message in layoutErrors) {
        reporter.handleZoneError(StateError(message), StackTrace.current);
      }

      final captured = sink.drain();
      expect(captured, hasLength(layoutErrors.length));
      expect(captured.map((c) => c.level), everyElement(LogLevel.warning));
    });

    test('classifies everything else as fatal', () {
      final sink = RecordingCrashSink();
      final reporter = TellingCrashReporter(telling: sink);

      reporter.handleZoneError(
        const FormatException('bad payload'),
        StackTrace.current,
      );

      final captured = sink.drain();
      expect(captured.single.level, LogLevel.fatal);
    });

    test('marks the event as an uncaught crash with its capture path', () {
      final sink = RecordingCrashSink();
      final reporter = TellingCrashReporter(telling: sink);

      reporter.handleZoneError(StateError('boom'), StackTrace.current);

      final captured = sink.drain().single;
      expect(captured.metadata['uncaught'], isTrue);
      expect(captured.metadata['capture_source'], 'zone');
      expect(captured.message, contains('StateError'));
    });
  });

  group('deduplication', () {
    test('reports the same error once, not once per capture path', () {
      final sink = RecordingCrashSink();
      final reporter = TellingCrashReporter(telling: sink);

      // One crash, arriving via the zone handler twice (as it does in
      // practice, because it also propagates to the isolate port).
      final error = StateError('boom');
      final stack = StackTrace.current;
      reporter.handleZoneError(error, stack);
      reporter.handleZoneError(error, stack);

      expect(
        sink.drain(),
        hasLength(1),
        reason: 'one crash must not become two reports',
      );
    });

    test('reports distinct errors separately', () {
      final sink = RecordingCrashSink();
      final reporter = TellingCrashReporter(telling: sink);

      reporter.handleZoneError(StateError('first'), StackTrace.current);
      reporter.handleZoneError(StateError('second'), StackTrace.current);

      expect(sink.drain(), hasLength(2));
    });

    test('distinguishes errors by type even with the same message', () {
      final sink = RecordingCrashSink();
      final reporter = TellingCrashReporter(telling: sink);

      reporter.handleZoneError(StateError('same'), StackTrace.current);
      reporter.handleZoneError(
        const FormatException('same'),
        StackTrace.current,
      );

      expect(sink.drain(), hasLength(2));
    });
  });

  group('run', () {
    test('runs the body', () {
      final sink = RecordingCrashSink();
      final reporter = TellingCrashReporter(telling: sink);

      var ran = false;
      reporter.run(() => ran = true);

      expect(ran, isTrue);
      expect(sink.drain(), isEmpty);
    });

    test('captures a synchronous throw from the body', () {
      final sink = RecordingCrashSink();
      final reporter = TellingCrashReporter(telling: sink);

      reporter.run(() => throw StateError('from the app body'));

      final captured = sink.drain();
      expect(captured, hasLength(1));
      expect(captured.single.level, LogLevel.fatal);
      expect(captured.single.message, contains('from the app body'));
    });

    test('captures an unhandled async error raised inside the zone', () async {
      final sink = RecordingCrashSink();
      final reporter = TellingCrashReporter(telling: sink);

      reporter.run(() {
        // A future whose error has no errorHandler — the case Flutter only
        // saw through PlatformDispatcher.instance.onError.
        unawaited(Future<void>.error(StateError('async boom')));
      });

      // The zone handler runs on a later microtask; let it drain.
      await Future<void>.delayed(Duration.zero);

      final captured = sink.drain();
      expect(captured, hasLength(1));
      expect(captured.single.message, contains('async boom'));
    });
  });

  group('Telling.run', () {
    test('is a passthrough when crash reporting was never enabled', () {
      // main.dart calls Telling.instance.run unconditionally, so with no API
      // key configured it must not install a zone or change behaviour.
      final telling = Telling.instance;
      expect(telling.isInitialized, isFalse);

      var ran = false;
      telling.run(() => ran = true);

      expect(ran, isTrue);
      expect(telling.crashReporter, isNull);
    });
  });

  group('log level / type helpers', () {
    test('severity values match the dashboard contract', () {
      expect(LogLevel.trace.severity, 0);
      expect(LogLevel.debug.severity, 1);
      expect(LogLevel.info.severity, 2);
      expect(LogLevel.warning.severity, 3);
      expect(LogLevel.error.severity, 4);
      expect(LogLevel.fatal.severity, 5);
    });

    test('isError and isWarningOrAbove agree with severity', () {
      expect(LogLevel.error.isError, isTrue);
      expect(LogLevel.fatal.isError, isTrue);
      expect(LogLevel.warning.isError, isFalse);
      expect(LogLevel.warning.isWarningOrAbove, isTrue);
      expect(LogLevel.error.isWarningOrAbove, isTrue);
      expect(LogLevel.info.isWarningOrAbove, isFalse);
    });
  });

  group('LogEvent wire format', () {
    test('round-trips through JSON with the fields the server expects', () {
      final event = TestHelpers.createLogEvent(
        message: 'boom',
        level: LogLevel.fatal,
        type: LogType.crash,
        stackTrace: 'frame one',
        metadata: <String, dynamic>{'context': 'checkout'},
        deviceMetadata: TestHelpers.createDeviceMetadata(),
        userId: 'user_1',
        sessionId: 'session_1',
      );

      final restored = LogEvent.fromJson(event.toJson());

      expect(restored.id, event.id);
      expect(restored.message, 'boom');
      expect(restored.level, LogLevel.fatal);
      expect(restored.type, LogType.crash);
      expect(restored.stackTrace, 'frame one');
      expect(restored.metadata?['context'], 'checkout');
      expect(restored.userId, 'user_1');
      expect(restored.sessionId, 'session_1');
      expect(restored.deviceMetadata?.deviceModel, 'Pixel 7');
    });

    test('serializes level and type as bare names, not enum paths', () {
      final json = TestHelpers.createLogEvent(level: LogLevel.warning).toJson();
      expect(json['level'], 'warning');
      expect(json['type'], 'general');
    });
  });
}

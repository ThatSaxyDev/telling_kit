import 'dart:async';
import 'package:test/test.dart';
import 'package:telling_kit/src/models/version_check_result.dart';
import 'package:telling_kit/src/version_check.dart';

void main() {
  final body = <String, dynamic>{
    'requiresUpdate': true,
    'isRequired': false,
    'minVersion': '1.0.4',
    'minBuild': 24,
    'target': '1.0.4+24',
    'decisionSource': 'build',
    'storeUrl': 'https://example.com/update',
    'message': 'Update',
  };
  Future<VersionCheckResult> check({
    String? build = '23',
    String platform = 'ios',
    Future<Map<String, dynamic>?> Function(Uri, Map<String, String>)? get,
    Duration timeout = const Duration(seconds: 10),
  }) => fetchVersionCheck(
    serverUrl: 'https://example.com/api/v1',
    platform: platform,
    version: '1.0.4',
    build: build,
    apiKey: 'project-key',
    timeout: timeout,
    get: get ?? (_, _) async => body,
  );
  test(
    'sends project API key, version and installed build separately',
    () async {
      final result = await check(
        get: (uri, headers) async {
          expect(uri.path, '/api/v1/project/version-check');
          expect(uri.queryParameters, {
            'platform': 'ios',
            'version': '1.0.4',
            'build': '23',
          });
          expect(headers['x-api-key'], 'project-key');
          return body;
        },
      );
      expect(result.requiresUpdate, true);
      expect(result.isRequired, false);
      expect(result.minBuild, 24);
      expect(result.snoozeTarget, '1.0.4+24');
      expect(result.decisionSource, 'build');
    },
  );
  test('missing builds and old server responses remain compatible', () async {
    for (final build in [null, '']) {
      final result = await check(
        build: build,
        get: (uri, _) async {
          expect(uri.queryParameters.containsKey('build'), false);
          return {
            'requiresUpdate': true,
            'isRequired': false,
            'minVersion': '1.0.4',
          };
        },
      );
      expect(result.minBuild, isNull);
      expect(result.snoozeTarget, '1.0.4');
    }
  });
  test(
    'HTTP failure, parse failure, exception and timeout fail open',
    () async {
      expect((await check(get: (_, _) async => null)).requiresUpdate, false);
      expect(
        (await check(
          get: (_, _) async => {'requiresUpdate': 'invalid'},
        )).requiresUpdate,
        false,
      );
      expect(
        (await check(
          get: (_, _) async => throw StateError('offline'),
        )).requiresUpdate,
        false,
      );
      expect(
        (await check(
          get: (_, _) => Completer<Map<String, dynamic>?>().future,
          timeout: const Duration(milliseconds: 5),
        )).requiresUpdate,
        false,
      );
      expect(
        (await check(
          platform: 'web',
          get: (_, _) async => throw StateError('must not call'),
        )).requiresUpdate,
        false,
      );
    },
  );
  test(
    'snoozes match exact targets, expire and never hide mandatory updates',
    () {
      final now = DateTime.utc(2026, 10, 17);
      final until = now.add(const Duration(days: 1)).toIso8601String();
      bool snoozed(
        Map<String, dynamic> response,
        String target, {
        String? end,
      }) => isUpdateSnoozed(
        result: VersionCheckResult.fromJson(response),
        storedTarget: target,
        storedUntil: end ?? until,
        now: now,
      );
      expect(snoozed(body, '1.0.4+24'), true);
      expect(
        snoozed({...body, 'minBuild': 25, 'target': '1.0.4+25'}, '1.0.4+24'),
        false,
      );
      expect(
        snoozed(body, '1.0.4'),
        false,
        reason: 'legacy version snooze cannot hide a build update',
      );
      expect(snoozed({...body, 'isRequired': true}, '1.0.4+24'), false);
      expect(snoozed(body, '1.0.4+24', end: now.toIso8601String()), false);
      expect(snoozed(body, '1.0.4+24', end: 'corrupt'), false);
      expect(
        snoozed({
          'requiresUpdate': true,
          'isRequired': false,
          'minVersion': '1.0.4',
        }, '1.0.4'),
        true,
      );
    },
  );
}

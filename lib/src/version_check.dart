import 'package:telling_kit/src/models/version_check_result.dart';

/// Transport-independent release check shared by the SDK's platform adapters.
/// A null response means a non-success HTTP status. Errors never block startup.
Future<VersionCheckResult> fetchVersionCheck({
  required String serverUrl,
  required String platform,
  required String version,
  required String apiKey,
  required Future<Map<String, dynamic>?> Function(Uri, Map<String, String>) get,
  String? build,
  Duration timeout = const Duration(seconds: 10),
}) async {
  if (!['ios', 'android'].contains(platform) || version.isEmpty) {
    return VersionCheckResult.noUpdateRequired;
  }
  try {
    final uri = Uri.parse('$serverUrl/project/version-check').replace(
      queryParameters: {
        'platform': platform,
        'version': version,
        if (build != null && build.isNotEmpty) 'build': build,
      },
    );
    final data = await get(uri, {
      'x-api-key': apiKey,
      'Content-Type': 'application/json',
    }).timeout(timeout);
    return data == null
        ? VersionCheckResult.noUpdateRequired
        : VersionCheckResult.fromJson(data);
  } catch (_) {
    return VersionCheckResult.noUpdateRequired;
  }
}

/// Legacy version snoozes never match a new build target. Forced updates ignore
/// every snooze, including one granted while the same target was optional.
bool isUpdateSnoozed({
  required VersionCheckResult result,
  required String? storedTarget,
  required String? storedUntil,
  DateTime? now,
}) {
  if (!result.requiresUpdate ||
      result.isRequired ||
      result.snoozeTarget == null ||
      result.snoozeTarget != storedTarget) {
    return false;
  }
  final until = DateTime.tryParse(storedUntil ?? '');
  return until != null && (now ?? DateTime.now()).isBefore(until);
}

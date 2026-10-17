/// Release requirements returned by a project version check.
class VersionCheckResult {
  /// Whether the installed version or build is below a configured minimum.
  final bool requiresUpdate;
  final bool isRequired;
  final String? storeUrl;
  final String? message;
  final String? minVersion;

  /// The minimum build, when the build threshold triggered the update.
  final int? minBuild;

  /// Exact update target used to scope optional-update snoozes.
  final String? target;

  /// `version`, `build`, or `version+build` when an update is needed.
  final String? decisionSource;

  const VersionCheckResult({
    required this.requiresUpdate,
    this.isRequired = true,
    this.storeUrl,
    this.message,
    this.minVersion,
    this.minBuild,
    this.target,
    this.decisionSource,
  });

  factory VersionCheckResult.fromJson(Map<String, dynamic> data) {
    return VersionCheckResult(
      requiresUpdate: data['requiresUpdate'] as bool? ?? false,
      isRequired: data['isRequired'] as bool? ?? false,
      storeUrl: data['storeUrl'] as String?,
      message: data['message'] as String?,
      minVersion: data['minVersion'] as String?,
      minBuild: data['minBuild'] as int?,
      target: data['target'] as String?,
      decisionSource: data['decisionSource'] as String?,
    );
  }

  /// Falls back to the version for servers without build support.
  String? get snoozeTarget =>
      target ??
      (minVersion == null
          ? null
          : minBuild == null
          ? minVersion
          : '$minVersion+$minBuild');

  static const noUpdateRequired = VersionCheckResult(requiresUpdate: false);

  @override
  String toString() =>
      'VersionCheckResult(requiresUpdate: $requiresUpdate, '
      'isRequired: $isRequired, minVersion: $minVersion, minBuild: $minBuild, '
      'target: $target, decisionSource: $decisionSource, storeUrl: $storeUrl, message: $message)';
}

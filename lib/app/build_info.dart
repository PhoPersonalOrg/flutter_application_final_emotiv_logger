import 'package:package_info_plus/package_info_plus.dart';

/// Compile-time build timestamp from `--dart-define=BUILD_TIME=…` (ISO-8601 UTC).
const String kBuildTime = String.fromEnvironment('BUILD_TIME', defaultValue: '');

/// App version / build metadata for the Record-screen caption.
class BuildInfo {
  const BuildInfo({
    required this.version,
    required this.buildNumber,
    this.builtAt = '',
  });

  final String version;
  final String buildNumber;

  /// Raw `BUILD_TIME` define, or empty when not injected at compile time.
  final String builtAt;

  /// One-line caption, e.g. `1.0.1+42 · 2026-11-19 19:03 UTC`.
  String get label {
    final ver = version.trim().isEmpty ? 'unknown' : version.trim();
    final build = buildNumber.trim();
    final versionPart = build.isEmpty ? ver : '$ver+$build';
    final time = formatBuiltAt(builtAt);
    if (time.isEmpty) return versionPart;
    return '$versionPart · $time';
  }

  /// Formats ISO-8601 UTC (e.g. `2026-11-19T19:03:00Z`) as `2026-11-19 19:03 UTC`.
  /// Returns the trimmed input when it does not match; empty when blank.
  static String formatBuiltAt(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return '';
    final match = RegExp(
      r'^(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2})(?::\d{2})?(?:\.\d+)?Z?$',
    ).firstMatch(s);
    if (match != null) {
      return '${match.group(1)} ${match.group(2)} UTC';
    }
    return s;
  }
}

/// Loads [PackageInfo] and pairs it with the compile-time [kBuildTime].
Future<BuildInfo> loadBuildInfo() async {
  try {
    final info = await PackageInfo.fromPlatform();
    return BuildInfo(
      version: info.version.isNotEmpty ? info.version : 'unknown',
      buildNumber: info.buildNumber,
      builtAt: kBuildTime,
    );
  } catch (_) {
    return BuildInfo(
      version: 'unknown',
      buildNumber: '',
      builtAt: kBuildTime,
    );
  }
}

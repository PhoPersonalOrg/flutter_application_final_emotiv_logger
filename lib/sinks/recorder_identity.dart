import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Host / recorder identity written into `session.json`.
class RecorderIdentity {
  const RecorderIdentity({
    required this.deviceId,
    required this.appVersionName,
    this.gps,
    this.gpsStatus,
  });

  /// On iOS: model class (e.g. `iPhone`, `iPad`). Elsewhere: hostname /
  /// computer name when available.
  final String deviceId;

  /// Flutter `version` name from pubspec / platform (e.g. `1.0.1`).
  final String appVersionName;

  /// One-shot GPS fix at session start, when available.
  final Map<String, Object?>? gps;

  /// Why [gps] is null: `ok`, `denied`, `disabled`, `timeout`, `unavailable`.
  final String? gpsStatus;
}

/// Resolves recorder `device_id`, app version, and optional GPS for session meta.
Future<RecorderIdentity> resolveRecorderIdentity({
  Duration gpsTimeout = const Duration(seconds: 4),
}) async {
  final versionName = await _appVersionName();
  final deviceId = await _recorderDeviceId();
  final gpsResult = await _tryCaptureGps(timeout: gpsTimeout);
  return RecorderIdentity(
    deviceId: deviceId,
    appVersionName: versionName,
    gps: gpsResult.gps,
    gpsStatus: gpsResult.status,
  );
}

class _GpsCapture {
  const _GpsCapture({this.gps, required this.status});
  final Map<String, Object?>? gps;
  final String status;
}

/// Best-effort single GPS fix. Never throws; never blocks longer than [timeout].
Future<_GpsCapture> _tryCaptureGps({
  Duration timeout = const Duration(seconds: 4),
}) async {
  try {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      return const _GpsCapture(status: 'disabled');
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return const _GpsCapture(status: 'denied');
    }

    final position = await Geolocator.getCurrentPosition(
      locationSettings: LocationSettings(
        accuracy: LocationAccuracy.medium,
        timeLimit: timeout,
      ),
    );
    return _GpsCapture(
      status: 'ok',
      gps: {
        'latitude': position.latitude,
        'longitude': position.longitude,
        'altitude_m': position.altitude,
        'accuracy_m': position.accuracy,
        'capturedAt': DateTime.now().toIso8601String(),
      },
    );
  } on TimeoutException {
    return const _GpsCapture(status: 'timeout');
  } catch (_) {
    return const _GpsCapture(status: 'unavailable');
  }
}

Future<String> _appVersionName() async {
  try {
    final info = await PackageInfo.fromPlatform();
    if (info.version.isNotEmpty) return info.version;
  } catch (_) {}
  return 'unknown';
}

Future<String> _recorderDeviceId() async {
  final plugin = DeviceInfoPlugin();
  try {
    if (Platform.isIOS) {
      final ios = await plugin.iosInfo;
      final model = ios.model.trim();
      if (model.isNotEmpty) return model;
      return 'iPhone';
    }
    if (Platform.isMacOS) {
      final mac = await plugin.macOsInfo;
      final name = mac.computerName.trim();
      if (name.isNotEmpty) return name;
    } else if (Platform.isWindows) {
      final win = await plugin.windowsInfo;
      final name = win.computerName.trim();
      if (name.isNotEmpty) return name;
    } else if (Platform.isLinux) {
      final linux = await plugin.linuxInfo;
      final pretty = linux.prettyName.trim();
      if (pretty.isNotEmpty) {
        final host = _localHostnameOrNull();
        if (host != null) return host;
        return pretty;
      }
    } else if (Platform.isAndroid) {
      final host = _localHostnameOrNull();
      if (host != null) return host;
      final android = await plugin.androidInfo;
      final model = android.model.trim();
      if (model.isNotEmpty) return model;
    }
  } catch (_) {}

  final host = _localHostnameOrNull();
  if (host != null) return host;
  return Platform.operatingSystem;
}

String? _localHostnameOrNull() {
  try {
    final host = Platform.localHostname.trim();
    if (host.isEmpty || host == 'localhost') return null;
    return host;
  } catch (_) {
    return null;
  }
}

import 'acquisition_health.dart';

/// Explicit BLE acquisition lifecycle. Single transition owner owns mutations.
sealed class AcquisitionState {
  const AcquisitionState();

  String get label;
  AcquisitionHealth get health;
}

class AcquisitionIdle extends AcquisitionState {
  const AcquisitionIdle({this.health = const AcquisitionHealth()});

  @override
  final AcquisitionHealth health;

  @override
  String get label => 'Idle';
}

class AcquisitionScanning extends AcquisitionState {
  const AcquisitionScanning({
    required this.devices,
    this.health = const AcquisitionHealth(),
  });

  final List<DiscoveredDevice> devices;

  @override
  final AcquisitionHealth health;

  @override
  String get label => 'Scanning';

  AcquisitionScanning copyWith({
    List<DiscoveredDevice>? devices,
    AcquisitionHealth? health,
  }) {
    return AcquisitionScanning(
      devices: devices ?? this.devices,
      health: health ?? this.health,
    );
  }
}

class AcquisitionConnecting extends AcquisitionState {
  const AcquisitionConnecting({
    required this.deviceName,
    this.health = const AcquisitionHealth(),
  });

  final String deviceName;

  @override
  final AcquisitionHealth health;

  @override
  String get label => 'Connecting';
}

class AcquisitionPreparing extends AcquisitionState {
  const AcquisitionPreparing({
    required this.deviceName,
    required this.sessionDir,
    this.health = const AcquisitionHealth(),
  });

  final String deviceName;
  final String sessionDir;

  @override
  final AcquisitionHealth health;

  @override
  String get label => 'Preparing';
}

class AcquisitionStreaming extends AcquisitionState {
  const AcquisitionStreaming({
    required this.deviceName,
    required this.sessionDir,
    required this.health,
  });

  final String deviceName;
  final String sessionDir;

  @override
  final AcquisitionHealth health;

  @override
  String get label => 'Streaming';

  AcquisitionStreaming copyWith({AcquisitionHealth? health}) {
    return AcquisitionStreaming(
      deviceName: deviceName,
      sessionDir: sessionDir,
      health: health ?? this.health,
    );
  }
}

class AcquisitionReconnecting extends AcquisitionState {
  const AcquisitionReconnecting({
    required this.deviceName,
    required this.attempt,
    required this.nextRetryIn,
    required this.health,
  });

  final String deviceName;
  final int attempt;
  final Duration nextRetryIn;

  @override
  final AcquisitionHealth health;

  @override
  String get label => 'Reconnecting';
}

class AcquisitionStopping extends AcquisitionState {
  const AcquisitionStopping({
    required this.deviceName,
    this.health = const AcquisitionHealth(),
  });

  final String deviceName;

  @override
  final AcquisitionHealth health;

  @override
  String get label => 'Stopping';
}

class AcquisitionFailed extends AcquisitionState {
  const AcquisitionFailed({
    required this.message,
    this.health = const AcquisitionHealth(),
  });

  final String message;

  @override
  final AcquisitionHealth health;

  @override
  String get label => 'Failed';
}

class DiscoveredDevice {
  const DiscoveredDevice({
    required this.id,
    required this.name,
    this.rssi,
  });

  final String id;
  final String name;
  final int? rssi;
}

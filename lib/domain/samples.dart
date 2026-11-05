import 'dart:typed_data';

/// BLE characteristic origin for a raw notification.
enum PacketKind { eeg, motion }

/// Raw BLE payload captured on the notify callback (no decrypt).
class RawPacket {
  const RawPacket({
    required this.kind,
    required this.bytes,
    required this.receiveMonoUs,
    required this.wallClock,
  });

  final PacketKind kind;
  final Uint8List bytes;
  final int receiveMonoUs;
  final DateTime wallClock;
}

/// Decrypted 14-channel EEG sample.
class EegSample {
  const EegSample({
    required this.values,
    required this.receiveMonoUs,
    required this.wallClock,
  });

  static const channelNames = [
    'AF3',
    'F7',
    'F3',
    'FC5',
    'T7',
    'P7',
    'O1',
    'O2',
    'P8',
    'T8',
    'FC6',
    'F4',
    'F8',
    'AF4',
  ];

  static const int channelCount = 14;
  static const double nominalRateHz = 128.0;

  final List<double> values;
  final int receiveMonoUs;
  final DateTime wallClock;
}

/// Parsed 6-channel motion sample (Acc XYZ + Gyro XYZ).
class MotionSample {
  const MotionSample({
    required this.values,
    required this.receiveMonoUs,
    required this.wallClock,
  });

  static const channelNames = [
    'AccX',
    'AccY',
    'AccZ',
    'GyroX',
    'GyroY',
    'GyroZ',
  ];

  static const int channelCount = 6;
  static const double nominalRateHz = 16.0;

  final List<double> values;
  final int receiveMonoUs;
  final DateTime wallClock;
}

/// Typed decode failure (does not stop the session).
class DecodeError {
  const DecodeError({
    required this.kind,
    required this.message,
    required this.receiveMonoUs,
  });

  final PacketKind kind;
  final String message;
  final int receiveMonoUs;
}

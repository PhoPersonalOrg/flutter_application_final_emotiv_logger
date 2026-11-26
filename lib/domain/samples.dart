import 'dart:typed_data';

/// BLE characteristic origin for a raw notification.
enum PacketKind { eeg, motion }

/// Raw BLE payload captured on the notify callback (before split/decrypt).
///
/// [kind] is advisory (from the subscribed GATT characteristic). Offline
/// tools inspect `char_uuid` and payload length (`64B` / `84B` / `20B`).
class RawPacket {
  const RawPacket({
    required this.kind,
    required this.bytes,
    required this.receiveMonoUs,
    required this.wallClock,
    this.characteristicUuid,
  });

  final PacketKind kind;
  final Uint8List bytes;
  final int receiveMonoUs;
  final DateTime wallClock;

  /// GATT characteristic UUID that produced this notification, when known.
  final String? characteristicUuid;
}

/// Decrypted 14-channel EPOC X EEG sample + per-electrode Contact Quality,
/// hardware trigger bit, and in-band Battery telemetry.
class EegSample {
  const EegSample({
    required this.values,
    required this.receiveMonoUs,
    required this.wallClock,
    this.counter = 0,
    this.markerHw = 0,
    this.contactQualityGrades = defaultQualityGrades,
    this.overallCq = 0,
    this.batteryPercent,
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

  static const List<int> defaultQualityGrades = [
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  ];

  static const int channelCount = 14;
  static const double nominalRateHz = 128.0;
  static const String qualityStreamName = 'Epoc X eQuality';
  static const String qualityStreamType = 'Raw';

  static List<String> get qualityChannelNames =>
      channelNames.map((n) => 'q$n').toList(growable: false);

  /// 14 EEG microvolt values in [channelNames] order (`AF3..AF4`).
  final List<double> values;
  final int receiveMonoUs;
  final DateTime wallClock;

  /// Rolling packet counter (`0..127` at 128 Hz, `0..255` at 256 Hz).
  final int counter;

  /// Hardware TTL trigger bit (`(P[1] >> 7) & 1`, `0` or `1`).
  final int markerHw;

  /// Per-electrode discrete Cortex Contact Quality grades (`0, 1, 2, 4`) held
  /// across each 64/128-sample demux cycle, in [channelNames] order (`AF3..AF4`).
  final List<int> contactQualityGrades;

  /// Overall Contact Quality percentage (`0..100`) derived from [contactQualityGrades].
  final int overallCq;

  /// In-band battery percentage (`0..100`) latched strictly when
  /// `counter == eegRateHz - 1` and `words[7] != 0`; null on ungated samples.
  final int? batteryPercent;

  /// 14-channel per-electrode CQ vector (`qAF3..qAF4`) pushed to LSL `Epoc X eQuality`.
  List<double> qualityValues() =>
      contactQualityGrades.map((g) => g.toDouble()).toList(growable: false);
}

/// Decoded 10-channel EPOC X Motion/IMU sample: unit quaternion (`Q0..Q3`),
/// accelerometer in `g` (`AccX..Z`), and magnetometer in `uT` (`MagX..Z`).
class MotionSample {
  const MotionSample({
    required this.values,
    required this.receiveMonoUs,
    required this.wallClock,
    this.counterMems = 0,
  });

  static const channelNames = [
    'Q0',
    'Q1',
    'Q2',
    'Q3',
    'AccX',
    'AccY',
    'AccZ',
    'MagX',
    'MagY',
    'MagZ',
  ];

  static const int channelCount = 10;

  /// Default EPOC X hardware MEMS sample rate (`32 Hz` per `81072f44 = 01 80 00 10 20 10`).
  static const double nominalRateHz = 32.0;

  final List<double> values;
  final int receiveMonoUs;
  final DateTime wallClock;

  /// Rolling MEMS counter (`0..127` mod `128`).
  final int counterMems;
}

/// Typed decode failure or plausibility warning (does not stop acquisition).
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

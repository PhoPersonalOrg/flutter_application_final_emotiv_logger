import 'dart:math' as math;
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart';

/// One decoded 32-byte package from the EEG characteristic (Epoc X mode).
class EegFrame {
  const EegFrame({
    required this.counter,
    required this.packetType,
    required this.values,
  });

  /// Plaintext byte 0. Runs 0..sampleRate-1 and wraps once per second.
  final int counter;

  /// Plaintext byte 1 & 0x7f: [CryptoCodec.packetTypeEeg] or
  /// [CryptoCodec.packetTypeMotion].
  final int packetType;

  /// 14 values in microvolts, ordered as `EegSample.channelNames`.
  final List<double> values;

  /// Android routes these to the motion path and skips the EEG ADC scale.
  bool get isMotionType => packetType == CryptoCodec.packetTypeMotion;
}

/// Epoc X EEG decrypt and motion parse.
///
/// Every layout, index table and constant here is taken from the EmotivPRO V4
/// Android library (`libEmbeddedLibQt.so`, `Cortex::DataProcessing`); the
/// function named beside each one is where it was read.
///
/// Supported: headset in Epoc X mode (HeadsetMode 7) on firmware <= 0x73e.
///
/// TODO(protocol): not implemented, and not guessed at:
///  * Firmware > 0x73e (`DataDecryption::isEpocXEncryptV4`): the XOR byte is
///    per-device instead of 0x55, and the cipher is AES-256-ECB with a
///    SHA-256 key built by `generateAesKeyVersion4` / `findKey`. The hash
///    input has not been recovered.
///  * Headset configured in legacy EPOC mode (HeadsetMode 3): different key
///    schedule (`aesKeyVersion2_STDMode`) and 14-bit bit-packed samples
///    (`convert_pkgs_STDMode`).
/// Both show up as non-sequential [EegFrame.counter] values, which
/// `EegCounterMonitor` reports instead of letting garbage pass silently.
class CryptoCodec {
  static const int hidDataLen = 16;

  /// `convert_bytes<StandardPackage>` stride.
  static const int eegPacketBytes = 32;

  /// `convert_bytes<MotionPackage>` stride.
  static const int motionPacketBytes = 20;

  static const int packetTypeEeg = 0x10;
  static const int packetTypeMotion = 0x20;

  /// `EpocXDataValueCorrection::convertADCToMicrovolt`: raw / 1.95 when the
  /// headset is configured for 14-bit EEG, raw / 7.8 for 16-bit.
  static const double eegDivisor14Bit = 1.95;
  static const double eegDivisor16Bit = 7.8;

  /// Assumed, not read from the headset. Android takes the resolution from a
  /// headset configuration record whose source characteristic has not been
  /// recovered; 16 is what it uses for its built-in Epoc X configuration.
  ///
  /// A 14-bit headset cannot send a sample above 16383, which is 2100.4 uV
  /// at this setting. If every EEG value in a recording stays below that,
  /// the headset is in 14-bit mode and this must be 14.
  static const int defaultEegResolutionBits = 16;

  /// `getRawEegId` (HeadsetType 7, mode 7): for each output channel
  /// (AF3, F7, F3, FC5, T7, P7, O1, O2, P8, T8, FC6, F4, F8, AF4) the index of
  /// its sample among the 15 little-endian uint16 words in plaintext bytes
  /// 2..31. Word 7 (bytes 16-17) is not an EEG channel.
  static const List<int> eegSampleOrder = [
    2, 3, 0, 1, 4, 5, 6, 8, 9, 10, 13, 14, 11, 12, //
  ];

  /// `DataValueCorrection::convertMotionADCToPhysicalValues` divisors.
  static const double quaternionDivisor = 16384.0;
  static const double accDivisor = 8191.0;
  static const double magDivisor = 6.0;

  /// Build 16-byte serial blob from BLE-advertised hex key (e.g. `E50202E9`).
  static Uint8List createSerialNumber(String btKey) {
    final zeros = Uint8List(12);
    final reversedKey =
        btKey.substring(6, 8) +
        btKey.substring(4, 6) +
        btKey.substring(2, 4) +
        btKey.substring(0, 2);
    final keyBytes = <int>[];
    for (var i = 0; i < reversedKey.length; i += 2) {
      keyBytes.add(int.parse(reversedKey.substring(i, i + 2), radix: 16));
    }
    return Uint8List.fromList([...zeros, ...keyBytes]);
  }

  /// AES-128 key from the 16-byte serial blob.
  ///
  /// Same result as `EpocXDataDecryption::aesKeyVersion2_EpocXMode`, which
  /// permutes the first four serial bytes `s` with
  /// `[0,1,3,3,1,0,1,3,0,3,2,1,0,1,1,2]`; here `s[i] == sn[15 - i]`.
  static Uint8List deriveEpocXKeyFromSerial(Uint8List sn) {
    if (sn.length != 16) {
      throw ArgumentError('Serial number must be 16 bytes');
    }
    return Uint8List.fromList([
      sn[15],
      sn[14],
      sn[12],
      sn[12],
      sn[14],
      sn[15],
      sn[14],
      sn[12],
      sn[15],
      sn[12],
      sn[13],
      sn[14],
      sn[15],
      sn[14],
      sn[14],
      sn[13],
    ]);
  }

  static double eegDivisorForResolution(int resolutionBits) {
    return switch (resolutionBits) {
      14 => eegDivisor14Bit,
      16 => eegDivisor16Bit,
      _ => throw ArgumentError(
          'EEG resolution must be 14 or 16 bits, got $resolutionBits',
        ),
    };
  }

  /// XOR 0x55 + AES-128-ECB, then one [EegFrame] per complete 32-byte package
  /// in the notification (`EpocXDataDecryption::process` →
  /// `convert_pkgs_EpocPlusMode`).
  static List<EegFrame> decryptEegFrames(
    Uint8List keyBytes,
    Uint8List data, {
    int resolutionBits = defaultEegResolutionBits,
  }) {
    if (keyBytes.length != 16) {
      throw ArgumentError('AES key must be 16 bytes');
    }
    if (data.length < eegPacketBytes) {
      throw ArgumentError('EEG packet must be at least 32 bytes');
    }
    final divisor = eegDivisorForResolution(resolutionBits);

    final key = Key(keyBytes);
    final encrypter = Encrypter(AES(key, mode: AESMode.ecb, padding: null));
    final packetCount = data.length ~/ eegPacketBytes;
    final frames = <EegFrame>[];

    for (var p = 0; p < packetCount; p++) {
      final start = p * eegPacketBytes;
      final dec = BytesBuilder(copy: false);
      for (var c = start; c < start + eegPacketBytes; c += 16) {
        final block = Uint8List(16);
        for (var i = 0; i < 16; i++) {
          block[i] = data[c + i] ^ 0x55;
        }
        dec.add(encrypter.decryptBytes(Encrypted(block)));
      }
      frames.add(_frameFromPlaintext(dec.toBytes(), divisor));
    }
    return frames;
  }

  /// First package of the notification as 14 channel values in microvolts.
  static List<double> decryptEeg(
    Uint8List keyBytes,
    Uint8List data, {
    int resolutionBits = defaultEegResolutionBits,
  }) {
    return decryptEegFrames(
      keyBytes,
      data,
      resolutionBits: resolutionBits,
    ).first.values;
  }

  /// Plaintext package layout: byte 0 counter, byte 1 type, bytes 2..31
  /// fifteen little-endian uint16 words (`unpack_bits_plusMode`).
  static EegFrame _frameFromPlaintext(Uint8List dec, double divisor) {
    if (dec.length < eegPacketBytes) {
      throw StateError('Decrypted EEG payload shorter than 32 bytes');
    }
    int word(int k) => dec[2 + 2 * k] | (dec[3 + 2 * k] << 8);
    return EegFrame(
      counter: dec[0],
      packetType: dec[1] & 0x7f,
      values: [for (final k in eegSampleOrder) word(k) / divisor],
    );
  }

  /// Unencrypted 20-byte motion package →
  /// `[Q0, Q1, Q2, Q3, AccX, AccY, AccZ, MagX, MagY, MagZ]`.
  ///
  /// Byte 0 is a counter; bytes 2..19 hold nine big-endian int16 values
  /// (`EpocXDataDecryption::convert_pkgs_motion`): Q1 Q2 Q3, Acc X Y Z,
  /// Mag X Y Z (`getRawMotionId`, motion V2). Axis swaps follow
  /// `EpocXDataValueCorrection::correctMotionDirection`; scaling and the
  /// derived Q0 follow `convertMotionADCToPhysicalValues`. Acc is in g.
  ///
  /// Android additionally low-pass filters the magnetometer
  /// (`DataValueCorrection::iirFilter`); that is not applied here, so Mag is
  /// the unsmoothed reading.
  static List<double> decodeMotion(Uint8List data) {
    if (data.length < motionPacketBytes) {
      throw ArgumentError('Motion packet must be at least 20 bytes');
    }

    int raw(int index) {
      final offset = 2 + 2 * index;
      final v = (data[offset] << 8) | data[offset + 1];
      return (v & 0x8000) != 0 ? v - 0x10000 : v;
    }

    final q1 = raw(1) / quaternionDivisor;
    final q2 = -raw(0) / quaternionDivisor;
    final q3 = raw(2) / quaternionDivisor;
    final q0 = math.sqrt(1.0 - math.min(q1 * q1 + q2 * q2 + q3 * q3, 1.0));

    return [
      q0,
      q1,
      q2,
      q3,
      raw(4) / accDivisor,
      -raw(3) / accDivisor,
      raw(5) / accDivisor,
      -raw(7) / magDivisor,
      raw(6) / magDivisor,
      raw(8) / magDivisor,
    ];
  }
}

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:encrypt/encrypt.dart';

import '../domain/samples.dart';
import 'headset_config.dart';

/// Physical headband orientation for EPOC X IMU axis mapping (`0x140e2c010`).
enum HeadbandPosition {
  /// Default over-the-crown orientation (`headbandPosition = 0`): swaps/negates X & Y.
  top,

  /// Rear-skull orientation (`headbandPosition = 1`): identity (no swap or sign flip).
  back,
}

extension HeadbandPositionX on HeadbandPosition {
  String get storageValue => name;

  String get displayLabel => switch (this) {
        HeadbandPosition.top => 'Top of head (default)',
        HeadbandPosition.back => 'Back of head',
      };

  static HeadbandPosition fromStorage(String? raw) {
    return switch (raw?.trim().toLowerCase()) {
      'back' || '1' => HeadbandPosition.back,
      _ => HeadbandPosition.top,
    };
  }
}

/// Hardware transport selector for V2 serial preparation (`0x140e3eb20`).
enum EpocXTransport { ble, usb, auto }

/// Derived session key material for EPOC X packet decryption (`V2` or `V4`).
class EpocXSessionKey {
  const EpocXSessionKey({
    required this.keyBytes,
    required this.preXorByte,
    required this.isV4,
    this.firmwareVersion = HeadsetConfig.defaultFirmwareVersion,
    this.keyMode = HeadsetConfig.modeEpocX,
  });

  /// Build directly from raw key bytes (16B -> V2 `0x55`; 32B -> V4 `0x14`).
  factory EpocXSessionKey.fromRawKeyBytes(
    Uint8List keyBytes, {
    int? firmwareVersion,
    int keyMode = HeadsetConfig.modeEpocX,
  }) {
    if (keyBytes.length == 32) {
      return EpocXSessionKey(
        keyBytes: Uint8List.fromList(keyBytes),
        preXorByte: CryptoCodec.v4XorByte,
        isV4: true,
        firmwareVersion: firmwareVersion ?? 0x0752,
        keyMode: keyMode,
      );
    }
    if (keyBytes.length == 16) {
      return EpocXSessionKey(
        keyBytes: Uint8List.fromList(keyBytes),
        preXorByte: CryptoCodec.v2XorByte,
        isV4: false,
        firmwareVersion: firmwareVersion ?? HeadsetConfig.defaultFirmwareVersion,
        keyMode: keyMode,
      );
    }
    throw ArgumentError(
      'AES key must be 16 (V2 AES-128) or 32 (V4 AES-256) bytes, got ${keyBytes.length}',
    );
  }

  final Uint8List keyBytes;
  final int preXorByte;
  final bool isV4;
  final int firmwareVersion;
  final int keyMode;
}

/// Result of splitting a BLE `81072f41` notification (`onEegDataReceived` `0x1408f6420`).
class BleSplitNotification {
  const BleSplitNotification({
    required this.eegCipherBlocks,
    this.motionWirePacket,
  });

  final List<Uint8List> eegCipherBlocks;
  final Uint8List? motionWirePacket;

  bool get isEmpty => eegCipherBlocks.isEmpty && motionWirePacket == null;
}

/// Unsealed `.rdata` V4 bootstrap constants (`0x140e405c0`).
class UnsealedV4Constants {
  const UnsealedV4Constants({
    required this.salt1,
    required this.salt2,
    required this.xorByte,
  });

  final String salt1;
  final String salt2;
  final int xorByte;
}

/// Decoded 32-byte EPOC X plaintext frame (`Mode 7`).
class EegFrame {
  const EegFrame({
    required this.counter,
    required this.packetType,
    required this.values,
    this.markerHw = 0,
    this.rawCqWord7 = 0,
    this.cqUpdatedChannel,
    this.cqUpdatedGrade,
    this.cqUpdatedMetric,
    this.cqGrades = const [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    this.overallCq = 0,
    this.batteryPercent,
    this.plaintextBytes,
  });

  /// Plaintext byte `0` (`0..eegRateHz-1`).
  final int counter;

  /// Plaintext `byte 1 & 0x7F` (`0x10` = EEG, `0x20` = 32B-padded Motion).
  final int packetType;

  /// Hardware TTL trigger sync bit (`(byte 1 >> 7) & 1` when `packetType == 0x10`).
  final int markerHw;

  /// 14 EEG channel values in microvolts (`AF3..AF4` order).
  final List<double> values;

  /// Raw unsigned 16-bit `words[7]` (`P[16..17]`).
  final int rawCqWord7;

  /// Electrode name updated by this frame (`CQ_ORDER[slot]` when `0 <= slot < 14`).
  final String? cqUpdatedChannel;

  /// Discrete Cortex CQ grade (`0, 1, 2, 4`) updated on [cqUpdatedChannel], if any.
  final int? cqUpdatedGrade;

  /// Normalized CQ ratio `(0.25 * words[7]) / CQ_SCALE[slot]`, if `0 <= slot < 14`.
  final double? cqUpdatedMetric;

  /// Current 14-channel held CQ grades (`0, 1, 2, 4`) in `AF3..AF4` output order.
  final List<int> cqGrades;

  /// Overall Contact Quality percentage (`0..100`) derived from [cqGrades].
  final int overallCq;

  /// In-band battery percentage (`0..100`) latched strictly when
  /// `counter == eegRateHz - 1` and `rawCqWord7 != 0`; null on other counters.
  final int? batteryPercent;

  /// Underlying 32-byte decrypted plaintext (needed if `isMotionType` routes `[0..20]` to Motion).
  final Uint8List? plaintextBytes;

  bool get isMotionType => packetType == CryptoCodec.packetTypeMotion;
}

/// Decoded 20-byte EPOC X Motion/MEMS frame.
class DecodedMotionFrame {
  const DecodedMotionFrame({
    required this.counterMems,
    required this.values,
  });

  /// Plaintext byte `0` (`mod 128`).
  final int counterMems;

  /// 10 channels `[Q0, Q1, Q2, Q3, AccX, AccY, AccZ, MagX, MagY, MagZ]`.
  final List<double> values;

  double get q0 => values[0];
  double get q1 => values[1];
  double get q2 => values[2];
  double get q3 => values[3];
  double get accX => values[4];
  double get accY => values[5];
  double get accZ => values[6];
  double get magX => values[7];
  double get magY => values[8];
  double get magZ => values[9];
}

/// Clean-room EPOC X cryptography and signal codec matching `CortexService.exe` `4.8.16.1`.
///
/// Covers:
/// - Version 2 (`fw <= 0x073E`): `AES-128-ECB`, `preXor = 0x55`, unencrypted BLE Motion
/// - Version 4 (`fw >= 0x073F`): `AES-256-ECB`, `preXor = 0x14`, `16B AES + 4B XOR` BLE Motion
/// - BLE `81072f41` `64B` & `84B` (`0x54`) super-frame splitting
/// - Mode 7 14-channel EEG `uV` scaling (`÷7.8` 16-bit, `÷1.95` 14-bit)
/// - Counter-multiplexed per-electrode Contact Quality (`slot = counter % (Fs ~/ 2)`)
/// - In-band Battery % gate (`counter == Fs - 1` and `words[7] != 0`)
/// - Hardware trigger bit `marker_hw = (P[1] >> 7) & 1`
/// - `"top"` vs. `"back"` headband IMU orientation transforms
class CryptoCodec {
  static const int hidDataLen = 16;
  static const int eegPacketBytes = 32;
  static const int motionPacketBytes = 20;

  static const int packetTypeEeg = 0x10;
  static const int packetTypeMotion = 0x20;

  static const int v2XorByte = 0x55;
  static const int v4XorByte = 0x14;

  static const String v4Salt1 = 'Vohcha7e';
  static const String v4Salt2 = 'Ut3phaej';

  /// Sealed `.rdata` hex blobs from `CortexService.exe` (`0x144308836` & `0x144308863`).
  static const String rdataV4Hex1 = '28bb26f9630d40dde902ab83e448db890d295228e414';
  static const String rdataV4Hex2 = '55db7062edcd83c155214df357dd918b43ef0e12f34c';

  static const double eegDivisor14Bit = 1.95;
  static const double eegDivisor16Bit = 7.8;
  static const int defaultEegResolutionBits = 16;

  /// Maps output `EegSample.channelNames[0..13]` -> LE16 word index in `P[2..31]` (`0x1410076c0`).
  static const List<int> eegSampleOrder = [
    2, 3, 0, 1, 4, 5, 6, 8, 9, 10, 13, 14, 11, 12,
  ];

  /// V2 Mode 7 key permutation (`0x140e2abf0`).
  static const List<int> v2Mode7Perm = [
    0, 1, 3, 3, 1, 0, 1, 3, 0, 3, 2, 1, 0, 1, 1, 2,
  ];

  /// ASIC electrode order for `slot = counter % (eegRateHz ~/ 2)` (`0x140c93360`).
  static const List<String> cqSlotChannelOrder = [
    'F3', 'FC5', 'AF3', 'F7', 'T7', 'P7', 'O1',
    'O2', 'P8', 'T8', 'F8', 'AF4', 'FC6', 'F4',
  ];

  /// Per-slot normalization divisors from `.rdata` (`0x14434ee88`).
  static const List<double> cqSlotScaleDivisors = [
    212.0, 216.0, 226.0, 235.0, 231.0, 239.0, 245.0,
    179.0, 167.0, 162.0, 206.0, 204.0, 194.0, 179.0,
  ];

  /// Discrete CQ grade thresholds (`<0.2 -> 0`, `<0.7 -> 1`, `<1.7 -> 2`, `>=1.7 -> 4`).
  static const List<double> cqGradeThresholds = [0.2, 0.7, 1.7];

  /// Maps `cqSlotChannelOrder[slot]` -> index in `EegSample.channelNames` (`AF3..AF4`).
  static const List<int> cqSlotToOutputChannelIndex = [
    2, 3, 0, 1, 4, 5, 6, 7, 8, 9, 12, 13, 10, 11,
  ];

  static const double quaternionDivisor = 16384.0;
  static const double accDivisor = 8191.0;
  static const double magDivisor = 6.0;

  /// True strictly when `counter == eegRateHz - 1` (`127` @ 128 Hz, `255` @ 256 Hz).
  static bool isBatteryCounter(int counter, {int eegRateHz = 128}) =>
      counter == (eegRateHz - 1);

  /// Cryptographically reproduce `fn_0x140e405c0` on `CortexService.exe` `.rdata` blobs.
  static UnsealedV4Constants unsealV4RdataConstants() {
    final blob = Uint8List.fromList([
      ...hexToBytes(rdataV4Hex2),
      ...hexToBytes(rdataV4Hex1),
    ]);
    if (blob.length != 44) {
      throw StateError('Expected 44-byte V4 .rdata blob');
    }
    final left32 = blob.sublist(0, 32);
    final right12 = blob.sublist(32, 44);
    final bootstrapKey = Uint8List.fromList(
      crypto.sha256.convert(right12).bytes,
    );
    final encrypter = Encrypter(
      AES(Key(bootstrapKey), mode: AESMode.ecb, padding: null),
    );
    final unsealed = BytesBuilder(copy: false)
      ..add(encrypter.decryptBytes(Encrypted(left32.sublist(0, 16))))
      ..add(encrypter.decryptBytes(Encrypted(left32.sublist(16, 32))));
    final d8 = unsealed.toBytes();
    final salt1 = ascii.decode([...d8.sublist(1, 4), ...d8.sublist(5, 10)]);
    final salt2 = ascii.decode([...d8.sublist(11, 18), ...d8.sublist(19, 20)]);
    final xorByte = right12[11];
    return UnsealedV4Constants(salt1: salt1, salt2: salt2, xorByte: xorByte);
  }

  /// Derive `(keyBytes, preXorByte, isV4)` per `0x140e3eb20` / `0x140e2aaf0` / `0x140e3f1e0`.
  ///
  /// [serialInput] may be raw binary bytes (`4` or `5` bytes on BLE) or a serial
  /// string (`"E50202E9"`, `"E50202E92B"`, `"EPOCX-E50202E9"`, or USB `"UD20240731007676"`).
  static EpocXSessionKey deriveEpocXKey(
    Object serialInput, {
    required int firmwareVersion,
    int keyMode = HeadsetConfig.modeEpocX,
    EpocXTransport transport = EpocXTransport.auto,
  }) {
    if (firmwareVersion > HeadsetConfig.v2MaxFirmwareVersion) {
      String serialHex;
      if (serialInput is List<int>) {
        if (serialInput.length == 4 || serialInput.length == 5) {
          serialHex = HeadsetConfig.bytesToUpperHex(serialInput.sublist(0, 4));
        } else {
          serialHex = ascii.decode(serialInput).trim().toUpperCase();
        }
      } else if (serialInput is String) {
        serialHex = serialInput.trim().toUpperCase();
      } else {
        throw ArgumentError('Unsupported serialInput type: ${serialInput.runtimeType}');
      }
      if (serialHex.startsWith('EPOCX-')) {
        serialHex = serialHex.substring(6);
      }
      if (serialHex.length < 8) {
        throw ArgumentError('V4 requires >= 8-char hex serial, got "$serialHex"');
      }
      // 0x140e3f319: if (len >= 9) serial_hex = serial_hex.left(8)
      final s8 = serialHex.substring(0, 8);
      final fwHex4 = (firmwareVersion & 0xFFFF)
          .toRadixString(16)
          .toUpperCase()
          .padLeft(4, '0');
      final preimage = ascii.encode(
        '$v4Salt1${s8.substring(0, 4)}$v4Salt2${s8.substring(4, 8)}$fwHex4',
      );
      final key32 = Uint8List.fromList(crypto.sha256.convert(preimage).bytes);
      return EpocXSessionKey(
        keyBytes: key32,
        preXorByte: v4XorByte,
        isV4: true,
        firmwareVersion: firmwareVersion,
        keyMode: keyMode,
      );
    }

    // Version 2 (fw <= 0x073E): AES-128-ECB, preXor = 0x55
    final bool isBle = switch (transport) {
      EpocXTransport.ble => true,
      EpocXTransport.usb => false,
      EpocXTransport.auto => _inferBleTransport(serialInput),
    };

    Uint8List raw;
    if (isBle) {
      if (serialInput is List<int>) {
        raw = Uint8List.fromList(serialInput);
      } else if (serialInput is String) {
        var clean = serialInput.trim().toUpperCase();
        if (clean.startsWith('EPOCX-')) {
          clean = clean.substring(6);
        }
        raw = hexToBytes(clean);
      } else {
        throw ArgumentError('Unsupported serialInput: ${serialInput.runtimeType}');
      }
    } else {
      if (serialInput is List<int>) {
        raw = Uint8List.fromList(serialInput);
      } else if (serialInput is String) {
        var clean = serialInput.trim().toUpperCase();
        if (clean.startsWith('EPOCX-')) {
          clean = clean.substring(6);
        }
        final asciiBytes = ascii.encode(clean);
        raw = Uint8List.fromList(asciiBytes.reversed.toList());
      } else {
        throw ArgumentError('Unsupported serialInput: ${serialInput.runtimeType}');
      }
    }

    Uint8List key16;
    if (keyMode == HeadsetConfig.modeLegacyEpoc) {
      if (raw.length < 5) {
        throw ArgumentError(
          'V2 mode 3 requires >= 5 prepared serial bytes, got ${raw.length}',
        );
      }
      key16 = Uint8List.fromList([
        raw[1], 0x00, raw[2], 0x56,
        raw[1], 0x00, raw[1], 0x13,
        raw[0], 0x00, raw[2], 0x1A,
        raw[4], 0x00, raw[2], 0x57,
      ]);
    } else {
      if (raw.length < 4) {
        throw ArgumentError(
          'V2 mode 7 requires >= 4 prepared serial bytes, got ${raw.length}',
        );
      }
      key16 = Uint8List.fromList([
        for (final idx in v2Mode7Perm) raw[idx],
      ]);
    }

    return EpocXSessionKey(
      keyBytes: key16,
      preXorByte: v2XorByte,
      isV4: false,
      firmwareVersion: firmwareVersion,
      keyMode: keyMode,
    );
  }

  static bool _inferBleTransport(Object serialInput) {
    if (serialInput is List<int>) {
      return serialInput.length == 4 || serialInput.length == 5;
    }
    if (serialInput is String) {
      var probe = serialInput.trim().toUpperCase();
      if (probe.startsWith('EPOCX-')) {
        probe = probe.substring(6);
      }
      return (probe.length == 8 || probe.length == 10) &&
          !probe.startsWith('UD') &&
          RegExp(r'^[0-9A-F]+$').hasMatch(probe);
    }
    return true;
  }

  /// Legacy 16-byte serial helper retained for compatibility with older tests.
  static Uint8List createSerialNumber(String btKey) {
    final clean = btKey.trim().toUpperCase();
    final zeros = Uint8List(12);
    final reversedKey =
        clean.substring(6, 8) +
        clean.substring(4, 6) +
        clean.substring(2, 4) +
        clean.substring(0, 2);
    return Uint8List.fromList([...zeros, ...hexToBytes(reversedKey)]);
  }

  /// Legacy V2 Mode-7 key helper from 16-byte serial blob.
  static Uint8List deriveEpocXKeyFromSerial(Uint8List sn) {
    if (sn.length != 16) {
      throw ArgumentError('Serial number must be 16 bytes');
    }
    final unreversed4 = Uint8List.fromList([sn[15], sn[14], sn[13], sn[12]]);
    return deriveEpocXKey(
      unreversed4,
      firmwareVersion: HeadsetConfig.defaultFirmwareVersion,
      keyMode: HeadsetConfig.modeEpocX,
      transport: EpocXTransport.ble,
    ).keyBytes;
  }

  /// Split BLE `81072f41` notification per `InputDevice::onEegDataReceived` (`0x1408f6420`).
  ///
  /// On `firmwareVersion > 0x0710`:
  /// - `64` bytes -> `2 x 32B` encrypted EEG blocks, `motionWirePacket = null`
  /// - `84` bytes (`0x54`) -> `2 x 32B` encrypted EEG blocks + `20B` Motion tail `[64..84]`
  /// - Any other length -> discarded (`empty`)
  static BleSplitNotification splitBle81072f41Notification(
    Uint8List notif, {
    int firmwareVersion = HeadsetConfig.defaultFirmwareVersion,
  }) {
    if (firmwareVersion > HeadsetConfig.legacyBleSplitMaxFirmware) {
      if (notif.length == 64) {
        return BleSplitNotification(
          eegCipherBlocks: [
            Uint8List.sublistView(notif, 0, 32),
            Uint8List.sublistView(notif, 32, 64),
          ],
        );
      }
      if (notif.length == 84) {
        return BleSplitNotification(
          eegCipherBlocks: [
            Uint8List.sublistView(notif, 0, 32),
            Uint8List.sublistView(notif, 32, 64),
          ],
          motionWirePacket: Uint8List.sublistView(notif, 64, 84),
        );
      }
      return const BleSplitNotification(eegCipherBlocks: []);
    }

    // Legacy fw <= 0x0710 fallback: accept N x 32B EEG blocks.
    final count = notif.length ~/ eegPacketBytes;
    return BleSplitNotification(
      eegCipherBlocks: [
        for (var i = 0; i < count; i++)
          Uint8List.sublistView(
            notif,
            i * eegPacketBytes,
            (i + 1) * eegPacketBytes,
          ),
      ],
    );
  }

  /// Decrypt a `32B` EEG/USB-Motion packet (`isMems = false`) or `20B` BLE Motion
  /// packet (`isMems = true`) per `EpocXDataDecryption::decrypt` (`0x140e2a370`).
  static Uint8List decryptPacket(
    Uint8List cipherPkt,
    EpocXSessionKey sessionKey, {
    bool isMems = false,
    Encrypter? cachedEncrypter,
  }) {
    if (!sessionKey.isV4) {
      if (isMems) {
        // V2 BLE Motion is unencrypted pass-through on wire.
        return Uint8List.fromList(cipherPkt);
      }
      if (cipherPkt.length % 16 != 0) {
        throw ArgumentError(
          'V2 encrypted packet length must be a multiple of 16, got ${cipherPkt.length}',
        );
      }
      final enc = cachedEncrypter ??
          Encrypter(
            AES(Key(sessionKey.keyBytes), mode: AESMode.ecb, padding: null),
          );
      final out = BytesBuilder(copy: false);
      final block = Uint8List(16);
      for (var off = 0; off < cipherPkt.length; off += 16) {
        for (var i = 0; i < 16; i++) {
          block[i] = cipherPkt[off + i] ^ sessionKey.preXorByte;
        }
        out.add(enc.decryptBytes(Encrypted(block)));
      }
      return out.toBytes();
    }

    // Version 4 (fw >= 0x073F): AES-256-ECB + preXor 0x14 on aligned 16B blocks,
    // plus XOR 0x14 tail on unaligned trailing bytes (20B Motion -> 16B AES + 4B XOR).
    final enc = cachedEncrypter ??
        Encrypter(
          AES(Key(sessionKey.keyBytes), mode: AESMode.ecb, padding: null),
        );
    final nAligned = (cipherPkt.length ~/ 16) * 16;
    final out = BytesBuilder(copy: false);
    final block = Uint8List(16);
    for (var off = 0; off < nAligned; off += 16) {
      for (var i = 0; i < 16; i++) {
        block[i] = cipherPkt[off + i] ^ sessionKey.preXorByte;
      }
      out.add(enc.decryptBytes(Encrypted(block)));
    }
    for (var i = nAligned; i < cipherPkt.length; i++) {
      out.addByte(cipherPkt[i] ^ sessionKey.preXorByte);
    }
    return out.toBytes();
  }

  /// Inverse of [decryptPacket] for deterministic V2/V4 unit test round-trips.
  static Uint8List encryptPacketForTest(
    Uint8List plainPkt,
    EpocXSessionKey sessionKey, {
    bool isMems = false,
  }) {
    if (!sessionKey.isV4) {
      if (isMems) {
        return Uint8List.fromList(plainPkt);
      }
      final enc = Encrypter(
        AES(Key(sessionKey.keyBytes), mode: AESMode.ecb, padding: null),
      );
      final out = BytesBuilder(copy: false);
      for (var off = 0; off < plainPkt.length; off += 16) {
        final block = enc.encryptBytes(plainPkt.sublist(off, off + 16)).bytes;
        for (final b in block) {
          out.addByte(b ^ sessionKey.preXorByte);
        }
      }
      return out.toBytes();
    }

    final enc = Encrypter(
      AES(Key(sessionKey.keyBytes), mode: AESMode.ecb, padding: null),
    );
    final nAligned = (plainPkt.length ~/ 16) * 16;
    final out = BytesBuilder(copy: false);
    for (var off = 0; off < nAligned; off += 16) {
      final block = enc.encryptBytes(plainPkt.sublist(off, off + 16)).bytes;
      for (final b in block) {
        out.addByte(b ^ sessionKey.preXorByte);
      }
    }
    for (var i = nAligned; i < plainPkt.length; i++) {
      out.addByte(plainPkt[i] ^ sessionKey.preXorByte);
    }
    return out.toBytes();
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

  /// Stateless convenience wrapper decrypting `1..N` 32-byte blocks (`16B` V2 or `32B` V4 key).
  static List<EegFrame> decryptEegFrames(
    Uint8List keyBytes,
    Uint8List data, {
    int resolutionBits = defaultEegResolutionBits,
    int eegRateHz = HeadsetConfig.defaultEegRateHz,
  }) {
    if (data.length < eegPacketBytes) {
      throw ArgumentError('EEG packet must be at least 32 bytes');
    }
    final sessionKey = EpocXSessionKey.fromRawKeyBytes(keyBytes);
    final decoder = EpocXStatefulDecoder(
      eegRateHz: eegRateHz,
      eegResolutionBits: resolutionBits,
    );
    final enc = Encrypter(
      AES(Key(sessionKey.keyBytes), mode: AESMode.ecb, padding: null),
    );
    final packetCount = data.length ~/ eegPacketBytes;
    final frames = <EegFrame>[];
    for (var p = 0; p < packetCount; p++) {
      final slice = Uint8List.sublistView(
        data,
        p * eegPacketBytes,
        (p + 1) * eegPacketBytes,
      );
      final plain = decryptPacket(
        slice,
        sessionKey,
        isMems: false,
        cachedEncrypter: enc,
      );
      frames.add(decoder.decodeEegPlaintext(plain));
    }
    return frames;
  }

  /// First decrypted EEG package as 14 channel values in microvolts.
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

  /// Decode 20-byte Motion plaintext into `[Q0..Q3, AccX..Z, MagX..Z]`.
  static List<double> decodeMotion(
    Uint8List plain20, {
    HeadbandPosition headbandPosition = HeadbandPosition.top,
  }) {
    return decodeMotionPlaintext(
      plain20,
      headbandPosition: headbandPosition,
    ).values;
  }

  /// Decode 20-byte Motion plaintext with counter and configurable `"top"` / `"back"` orientation.
  static DecodedMotionFrame decodeMotionPlaintext(
    Uint8List plain20, {
    HeadbandPosition headbandPosition = HeadbandPosition.top,
  }) {
    if (plain20.length < motionPacketBytes) {
      throw ArgumentError('Motion packet must be at least 20 bytes');
    }
    final counterMems = plain20[0] & 0xFF;

    int rawBe16(int index) {
      final offset = 2 + 2 * index;
      final v = ((plain20[offset] & 0xFF) << 8) | (plain20[offset + 1] & 0xFF);
      return (v & 0x8000) != 0 ? v - 0x10000 : v;
    }

    final q1R = rawBe16(0);
    final q2R = rawBe16(1);
    final q3R = rawBe16(2);
    final axR = rawBe16(3);
    final ayR = rawBe16(4);
    final azR = rawBe16(5);
    final mxR = rawBe16(6);
    final myR = rawBe16(7);
    final mzR = rawBe16(8);

    double q1S, q2S, q3S;
    double axS, ayS, azS;
    double mxS, myS, mzS;

    if (headbandPosition == HeadbandPosition.back) {
      // 0x140e2c010: identity transform when headband is worn at rear of skull.
      q1S = q1R.toDouble();
      q2S = q2R.toDouble();
      q3S = q3R.toDouble();
      axS = axR.toDouble();
      ayS = ayR.toDouble();
      azS = azR.toDouble();
      mxS = mxR.toDouble();
      myS = myR.toDouble();
      mzS = mzR.toDouble();
    } else {
      // Default "top" orientation swap & sign negation.
      q1S = q2R.toDouble();
      q2S = (-q1R).toDouble();
      q3S = q3R.toDouble();
      axS = ayR.toDouble();
      ayS = (-axR).toDouble();
      azS = azR.toDouble();
      mxS = (-myR).toDouble();
      myS = mxR.toDouble();
      mzS = mzR.toDouble();
    }

    final q1 = q1S / quaternionDivisor;
    final q2 = q2S / quaternionDivisor;
    final q3 = q3S / quaternionDivisor;
    final normSq = q1 * q1 + q2 * q2 + q3 * q3;
    final q0 = normSq >= 1.0 ? 0.0 : math.sqrt(1.0 - normSq);

    return DecodedMotionFrame(
      counterMems: counterMems,
      values: [
        q0,
        q1,
        q2,
        q3,
        axS / accDivisor,
        ayS / accDivisor,
        azS / accDivisor,
        mxS / magDivisor,
        myS / magDivisor,
        mzS / magDivisor,
      ],
    );
  }

  /// Compute overall CQ percentage (`0..100`) from 14 Cortex grades (`0..4`).
  static int computeOverallCqPercent(List<int> grades) {
    if (grades.isEmpty) return 0;
    var sum = 0;
    for (final g in grades) {
      sum += g.clamp(0, 4);
    }
    return ((sum * 100.0) / (grades.length * 4.0)).round().clamp(0, 100);
  }

  static Uint8List hexToBytes(String hex) {
    final clean = hex.trim().replaceAll(RegExp(r'\s+'), '');
    if (clean.length.isOdd) {
      throw ArgumentError('Hex string must have even length: "$hex"');
    }
    final out = Uint8List(clean.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(clean.substring(2 * i, 2 * i + 2), radix: 16);
    }
    return out;
  }
}

/// Stateful per-session EPOC X decoder holding per-electrode CQ grades (`AF3..AF4`),
/// in-band battery latch (`counter == eegRateHz - 1`), and cached AES block cipher.
class EpocXStatefulDecoder {
  EpocXStatefulDecoder({
    this.eegRateHz = HeadsetConfig.defaultEegRateHz,
    this.eegResolutionBits = CryptoCodec.defaultEegResolutionBits,
    this.headbandPosition = HeadbandPosition.top,
    EpocXSessionKey? sessionKey,
  }) : _cqGrades = List<int>.filled(EegSample.channelCount, 0) {
    if (sessionKey != null) {
      configureKey(sessionKey);
    }
  }

  int eegRateHz;
  int eegResolutionBits;
  HeadbandPosition headbandPosition;

  EpocXSessionKey? _sessionKey;
  Encrypter? _cachedEncrypter;

  final List<int> _cqGrades;
  int? _batteryPercent;

  EpocXSessionKey? get sessionKey => _sessionKey;

  /// Latest held 14-channel Cortex CQ grades (`0, 1, 2, 4`) in `AF3..AF4` order.
  List<int> get cqGrades => List<int>.unmodifiable(_cqGrades);

  /// Latest held in-band battery percentage (`0..100`), or null if not yet latched.
  int? get batteryPercent => _batteryPercent;

  void configureKey(EpocXSessionKey key) {
    _sessionKey = key;
    _cachedEncrypter = Encrypter(
      AES(Key(key.keyBytes), mode: AESMode.ecb, padding: null),
    );
  }

  void reset() {
    _cqGrades.fillRange(0, _cqGrades.length, 0);
    _batteryPercent = null;
  }

  Uint8List decryptPacket(Uint8List cipherPkt, {required bool isMems}) {
    final key = _sessionKey;
    if (key == null) {
      throw StateError('EpocXStatefulDecoder has no configured sessionKey');
    }
    return CryptoCodec.decryptPacket(
      cipherPkt,
      key,
      isMems: isMems,
      cachedEncrypter: _cachedEncrypter,
    );
  }

  /// Decode a 32-byte decrypted Mode-7 plaintext block (`P[0..31]`).
  ///
  /// When `(P[1] & 0x7F) == 0x20` (32-byte USB/replay Motion block), returns an
  /// [EegFrame] with `isMotionType == true` and [EegFrame.plaintextBytes] set so
  /// callers can pass `plain32.sublist(0, 20)` to [decodeMotionPlaintext].
  EegFrame decodeEegPlaintext(Uint8List plain32) {
    if (plain32.length < CryptoCodec.eegPacketBytes) {
      throw ArgumentError(
        'Expected 32B EEG plaintext, got ${plain32.length}',
      );
    }

    final counter = plain32[0] & 0xFF;
    final pktType = plain32[1] & 0x7F;
    if (pktType == CryptoCodec.packetTypeMotion) {
      return EegFrame(
        counter: counter,
        packetType: pktType,
        markerHw: 0,
        values: const [],
        cqGrades: List<int>.unmodifiable(_cqGrades),
        overallCq: CryptoCodec.computeOverallCqPercent(_cqGrades),
        plaintextBytes: Uint8List.sublistView(plain32, 0, 32),
      );
    }

    final markerHw = pktType == CryptoCodec.packetTypeEeg
        ? ((plain32[1] >> 7) & 0x01)
        : 0;
    final divisor = CryptoCodec.eegDivisorForResolution(eegResolutionBits);

    int wordLe16(int k) =>
        (plain32[2 + 2 * k] & 0xFF) | ((plain32[3 + 2 * k] & 0xFF) << 8);

    final values = List<double>.generate(
      EegSample.channelCount,
      (ch) => wordLe16(CryptoCodec.eegSampleOrder[ch]) / divisor,
      growable: false,
    );

    final rawWord7 = wordLe16(7);

    // In-band Battery gate: strictly counter == eegRateHz - 1 AND words[7] != 0.
    int? latchedBatt;
    if (pktType == CryptoCodec.packetTypeEeg &&
        counter == (eegRateHz - 1) &&
        rawWord7 != 0) {
      latchedBatt = (rawWord7 & 0x7F).clamp(0, 100);
      _batteryPercent = latchedBatt;
    }

    // Per-electrode Contact Quality demux: slot = counter % (eegRateHz ~/ 2).
    String? cqCh;
    int? cqGrade;
    double? cqMetric;
    if (pktType == CryptoCodec.packetTypeEeg) {
      final halfRate = math.max(1, eegRateHz ~/ 2);
      final slot = counter % halfRate;
      if (slot >= 0 && slot < 14) {
        cqCh = CryptoCodec.cqSlotChannelOrder[slot];
        cqMetric =
            (0.25 * rawWord7.toDouble()) / CryptoCodec.cqSlotScaleDivisors[slot];
        if (cqMetric < CryptoCodec.cqGradeThresholds[0]) {
          cqGrade = 0;
        } else if (cqMetric < CryptoCodec.cqGradeThresholds[1]) {
          cqGrade = 1;
        } else if (cqMetric < CryptoCodec.cqGradeThresholds[2]) {
          cqGrade = 2;
        } else {
          cqGrade = 4;
        }
        final outIdx = CryptoCodec.cqSlotToOutputChannelIndex[slot];
        _cqGrades[outIdx] = cqGrade;
      }
    }

    final snapshotGrades = List<int>.from(_cqGrades, growable: false);
    return EegFrame(
      counter: counter,
      packetType: pktType,
      markerHw: markerHw,
      values: values,
      rawCqWord7: rawWord7,
      cqUpdatedChannel: cqCh,
      cqUpdatedGrade: cqGrade,
      cqUpdatedMetric: cqMetric,
      cqGrades: snapshotGrades,
      overallCq: CryptoCodec.computeOverallCqPercent(snapshotGrades),
      batteryPercent: latchedBatt,
    );
  }

  DecodedMotionFrame decodeMotionPlaintext(Uint8List plain20) {
    return CryptoCodec.decodeMotionPlaintext(
      plain20,
      headbandPosition: headbandPosition,
    );
  }
}

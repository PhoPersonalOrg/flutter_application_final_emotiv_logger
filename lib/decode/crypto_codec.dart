import 'dart:typed_data';

import 'package:encrypt/encrypt.dart';

/// Epoc X / Epoc+ AES EEG decrypt and motion parse (ported from prior CryptoUtils).
class CryptoCodec {
  static const int hidDataLen = 16;
  static const double multiplier = 0.5128205128205129;
  static const double accScale = 1.0 / 16384.0;
  static const double gyroScale = 1.0 / 131.0;

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

  /// Epoc X model-8 key mapping from 16-byte serial.
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

  /// XOR 0x55 + AES-ECB → 14 EEG channel doubles.
  static List<double> decryptEeg(Uint8List keyBytes, Uint8List data) {
    if (keyBytes.length != 16) {
      throw ArgumentError('AES key must be 16 bytes');
    }
    if (data.length < 32) {
      throw ArgumentError('EEG packet must be at least 32 bytes');
    }

    final key = Key(keyBytes);
    final encrypter = Encrypter(AES(key, mode: AESMode.ecb, padding: null));
    final xored = Uint8List.fromList(
      List<int>.generate(data.length, (i) => data[i] ^ 0x55),
    );
    final decryptedAll = BytesBuilder();
    for (var c = 0; c + 16 <= xored.length; c += 16) {
      final block = Uint8List.fromList(xored.sublist(c, c + 16));
      decryptedAll.add(encrypter.decryptBytes(Encrypted(block)));
    }
    final dec = decryptedAll.toBytes();
    if (dec.length < 32) {
      throw StateError('Decrypted EEG payload shorter than 32 bytes');
    }

    final words = <int>[];
    for (var i = 0; i + 1 < dec.length && words.length < 16; i += 2) {
      words.add((dec[i + 1] << 8) | dec[i]);
    }
    if (words.length < 15) {
      throw StateError('Not enough EEG words after decrypt');
    }

    return [
      for (var i = 1; i <= 14; i++) (words[i] * multiplier) * 0.25,
    ];
  }

  /// Unencrypted ICM-20948-style LE int16 motion → [AccXYZ, GyroXYZ].
  static List<double> decodeMotion(Uint8List data) {
    if (data.length < 14) {
      throw ArgumentError('Motion packet must be at least 14 bytes');
    }

    int readLeI16(int offset) {
      final v = data[offset] | (data[offset + 1] << 8);
      return (v & 0x8000) != 0 ? v - 0x10000 : v;
    }

    return [
      readLeI16(2) * accScale,
      readLeI16(4) * accScale,
      readLeI16(6) * accScale,
      readLeI16(8) * gyroScale,
      readLeI16(10) * gyroScale,
      readLeI16(12) * gyroScale,
    ];
  }
}

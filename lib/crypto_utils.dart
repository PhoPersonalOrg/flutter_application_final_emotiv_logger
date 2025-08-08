import 'dart:typed_data';
import 'package:encrypt/encrypt.dart';

class CryptoUtils {
  static const int hidDataLen = 16;
  static const double multiplier = 0.5128205128205129;

  // Motion data decoding constants based on emotiv_lsl implementation
  static const double _accScale = 1.0 / 16384.0; // ±2g range for accelerometer
  static const double _gyroScale = 1.0 / 131.0;   // ±250 deg/s range for gyroscope

  static String decryptRawPacket(Uint8List data) {
    try {
      // Device-specific 16-byte AES key (same as your Objective-C code)
      final keyString = '6566565666756557';
      final key = Key.fromUtf8(keyString.padRight(16, '0').substring(0, 16));

      final encrypter = Encrypter(AES(key, mode: AESMode.ecb, padding: null));

      final List<double> results = [];

      // Process data in 16-byte chunks
      for (int c = 0; c < data.length && c < hidDataLen; c += 16) {
        final endIndex = (c + 16 > data.length) ? data.length : c + 16;
        final chunk = data.sublist(c, endIndex);

        // Pad chunk to 16 bytes if necessary
        final paddedChunk = Uint8List(16);
        paddedChunk.setRange(0, chunk.length, chunk);

        final encrypted = Encrypted(paddedChunk);
        final decrypted = encrypter.decryptBytes(encrypted);

        // Process decrypted chunk in pairs
        for (int i = 0; i < decrypted.length - 1; i += 2) {
          int tmpVal = (decrypted[i + 1] << 8) | decrypted[i];
          double rawVal = (tmpVal * multiplier) * 0.25;
          results.add(rawVal);
        }
      }

      return results.map((v) => v.toStringAsFixed(6)).join(',');
    } catch (e) {
      print('Decryption error: $e');
      return '';
    }
  }

  static List<double> decryptToDoubleList(Uint8List data) {
    try {
      final keyString ='6566565666756557'; // This is the Emotiv Epoc X's serial number, and it's hard coded. wtf is this 2025-07-31
      final key = Key.fromUtf8(keyString.padRight(16, '0').substring(0, 16));
      final encrypter = Encrypter(AES(key, mode: AESMode.ecb, padding: null));

      // 2) Decrypt all 32 bytes in 16-byte blocks
      final decryptedAll = BytesBuilder();
      for (int c = 0; c + 16 <= data.length; c += 16) {
        final block = Uint8List.fromList(data.sublist(c, c + 16));
        decryptedAll.add(encrypter.decryptBytes(Encrypted(block)));
      }
      final dec = decryptedAll.toBytes();
      if (dec.length < 32) return [];

      // 3) Convert to 16 little-endian 16-bit words
      final words = <int>[];
      for (int i = 0; i + 1 < dec.length && words.length < 16; i += 2) {
        words.add((dec[i + 1] << 8) | dec[i]);
      }

      // 4) Map indices 1..14 to channels AF3..AF4 (discard 0 and 15)
      final eegWords = [
        words[1], // AF3
        words[2], // F7
        words[3], // F3
        words[4], // FC5
        words[5], // T7
        words[6], // P7
        words[7], // O1
        words[8], // O2
        words[9], // P8
        words[10], // T8
        words[11], // FC6
        words[12], // F4
        words[13], // F8
        words[14], // AF4
      ];

      // 5) Scale (placeholder scale you’re using now)
      return eegWords.map((w) => (w * multiplier) * 0.25).toList();
    } catch (e) {
      print('Decryption error: $e');
      return [];
    }
  }

  /// Decode motion sensor data from gyro/accelerometer packet
  /// Based on emotiv_lsl implementation for EPOC X IMU (ICM-20948)
  /// Returns [AccX, AccY, AccZ, GyroX, GyroY, GyroZ]
  static List<double> decodeMotionData(Uint8List data) {
    // According to o3 (Reasoning) AI -- EEG packets (0x41) are AES-encrypted; motion packets (0x42) are not
    // encrypted on an EPOC X, so your decodeMotionData only needs to parse the raw
    // 32 bytes—no AES involved.
    // Expect >= 14 bytes: 2-byte header (counter/flags) + 6 * int16
    if (data.length < 14) {
      return const [0.0, 0.0, 0.0, 0.0, 0.0, 0.0];
    }

    int readLeI16(int offset) {
      final v = (data[offset] | (data[offset + 1] << 8));
      return (v & 0x8000) != 0 ? v - 0x10000 : v; // signed
    }

    // bytes 0..1: header (counter/flags); IMU starts at byte 2
    final ax = readLeI16(2);
    final ay = readLeI16(4);
    final az = readLeI16(6);
    final gx = readLeI16(8);
    final gy = readLeI16(10);
    final gz = readLeI16(12);

    return [
      ax * _accScale, // g (±2g => 16384 LSB/g)
      ay * _accScale,
      az * _accScale,
      gx * _gyroScale, // deg/s (±250 dps => 131 LSB/(deg/s))
      gy * _gyroScale,
      gz * _gyroScale,
    ];
  }
  
}

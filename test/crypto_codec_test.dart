import 'dart:typed_data';

import 'package:flutter_emotiv_logger/decode/crypto_codec.dart';
import 'package:flutter_emotiv_logger/decode/device_identity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CryptoCodec', () {
    test('createSerialNumber reverses BLE hex nibbles', () {
      final sn = CryptoCodec.createSerialNumber('E50202E9');
      expect(sn.length, 16);
      expect(sn.sublist(0, 12), everyElement(0));
      // reversed pairs: E9 02 02 E5
      expect(sn[12], 0xE9);
      expect(sn[13], 0x02);
      expect(sn[14], 0x02);
      expect(sn[15], 0xE5);
    });

    test('deriveEpocXKeyFromSerial is deterministic 16 bytes', () {
      final sn = CryptoCodec.createSerialNumber('E50202E9');
      final key = CryptoCodec.deriveEpocXKeyFromSerial(sn);
      expect(key.length, 16);
      expect(CryptoCodec.deriveEpocXKeyFromSerial(sn), key);
    });

    test('decodeMotion parses LE int16 IMU frame', () {
      final bytes = Uint8List(14);
      // AccX = 16384 → 1.0 g
      bytes[2] = 0x00;
      bytes[3] = 0x40;
      final motion = CryptoCodec.decodeMotion(bytes);
      expect(motion.length, 6);
      expect(motion[0], closeTo(1.0, 1e-6));
    });

    test('decryptEeg rejects short packets', () {
      final key = Uint8List(16);
      expect(
        () => CryptoCodec.decryptEeg(key, Uint8List(16)),
        throwsArgumentError,
      );
    });
  });

  group('DeviceIdentityResolver', () {
    test('parses name hex key', () {
      final id = DeviceIdentityResolver().resolveFromName('EPOCX (E50202E9)');
      expect(id.btKeyHex, 'E50202E9');
      expect(id.keyBytes.length, 16);
      expect(id.keyFingerprint, contains('E50202E9'));
    });

    test('throws on missing key', () {
      expect(
        () => DeviceIdentityResolver().resolveFromName('EPOCX'),
        throwsStateError,
      );
    });
  });
}

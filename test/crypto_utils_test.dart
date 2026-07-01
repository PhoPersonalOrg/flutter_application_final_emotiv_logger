import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_emotiv_logger/crypto_utils.dart';

void main() {
  group('CryptoUtils', () {
    test('createSerialNumber should correctly reverse and pad the Bluetooth key', () {
      const btKey = 'E50202E9';
      final serialNumber = CryptoUtils.createSerialNumber(btKey);

      expect(serialNumber.length, 16);

      // First 12 bytes should be zero
      for (int i = 0; i < 12; i++) {
        expect(serialNumber[i], 0);
      }

      // Last 4 bytes should be reversed: E9, 02, 02, E5
      expect(serialNumber[12], 0xE9);
      expect(serialNumber[13], 0x02);
      expect(serialNumber[14], 0x02);
      expect(serialNumber[15], 0xE5);
    });

    test('deriveEpocXKeyFromSerial should correctly derive key from serial number', () {
      final sn = Uint8List.fromList([
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0xE9, 0x02, 0x02, 0xE5
      ]);

      final key = CryptoUtils.deriveEpocXKeyFromSerial(sn);

      expect(key.length, 16);

      final expectedKey = [
        0xE5, 0x02, 0xE9, 0xE9,
        0x02, 0xE5, 0x02, 0xE9,
        0xE5, 0xE9, 0x02, 0x02,
        0xE5, 0x02, 0x02, 0x02
      ];

      expect(key, Uint8List.fromList(expectedKey));
    });
  });
}

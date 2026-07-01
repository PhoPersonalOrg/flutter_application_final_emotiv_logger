import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_emotiv_logger/crypto_utils.dart';

void main() {
  group('CryptoUtils', () {
    group('deriveEpocXKeyFromSerial', () {
      test('correctly transposes 16-byte serial number to key', () {
        final sn = Uint8List.fromList([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]);
        final expected = Uint8List.fromList([
          15, 14, 12, 12,
          14, 15, 14, 12,
          15, 12, 13, 14,
          15, 14, 14, 13,
        ]);

        final result = CryptoUtils.deriveEpocXKeyFromSerial(sn);

        expect(result, equals(expected));
      });

      test('works correctly with all zeros', () {
        final sn = Uint8List(16);
        final expected = Uint8List(16);

        final result = CryptoUtils.deriveEpocXKeyFromSerial(sn);

        expect(result, equals(expected));
      });

      test('throws AssertionError if input is not 16 bytes', () {
        final shortSn = Uint8List(15);
        final longSn = Uint8List(17);

        expect(() => CryptoUtils.deriveEpocXKeyFromSerial(shortSn), throwsAssertionError);
        expect(() => CryptoUtils.deriveEpocXKeyFromSerial(longSn), throwsAssertionError);
      });
    });
  });
}

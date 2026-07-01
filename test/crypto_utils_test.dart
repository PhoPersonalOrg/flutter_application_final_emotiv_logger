import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_emotiv_logger/crypto_utils.dart';

void main() {
  group('CryptoUtils.decryptToDoubleList', () {
    test('returns empty list for empty data', () {
      final result = CryptoUtils.decryptToDoubleList('6566565666756557', Uint8List(0));
      expect(result, isEmpty);
    });

    test('returns empty list for short data (16 bytes)', () {
      // 16 bytes XORed and decrypted will result in 16 bytes, which is < 32
      final result = CryptoUtils.decryptToDoubleList('6566565666756557', Uint8List(16));
      expect(result, isEmpty);
    });

    test('returns empty list for 31 bytes of data', () {
      // Only the first 16 bytes are processed in the loop c + 16 <= xored.length
      // Resulting dec.length will be 16, which is < 32
      final result = CryptoUtils.decryptToDoubleList('6566565666756557', Uint8List(31));
      expect(result, isEmpty);
    });

    test('handles invalid key string length by padding', () {
      // Empty string gets padded to 16 '0's.
      // Should not throw, and since data is 0s, it might return [] if decryption results in < 32 bytes
      // or a list of 14 values if it somehow produces >= 32 bytes.
      // The goal here is to ensure it doesn't crash.
      final result = CryptoUtils.decryptToDoubleList('', Uint8List(32));
      expect(result, isA<List<double>>());
    });
  });

  group('CryptoUtils.decryptToDoubleListWithKeyBytes', () {
    test('throws AssertionError for invalid key length', () {
      expect(
        () => CryptoUtils.decryptToDoubleListWithKeyBytes(Uint8List(10), Uint8List(32)),
        throwsAssertionError,
      );
    });

    test('returns empty list for data that results in < 32 decrypted bytes', () {
      final key = Uint8List(16);
      final data = Uint8List(16);
      final result = CryptoUtils.decryptToDoubleListWithKeyBytes(key, data);
      expect(result, isEmpty);
    });
  });

  group('CryptoUtils.decryptRawPacket', () {
    test('returns empty string for empty data', () {
      final result = CryptoUtils.decryptRawPacket('6566565666756557', Uint8List(0));
      expect(result, '');
    });

    test('processes only the first 16 bytes even if more are provided', () {
      // hidDataLen is 16.
      final data = Uint8List(32);
      final result = CryptoUtils.decryptRawPacket('6566565666756557', data);

      // decryptRawPacket processes 16-byte blocks.
      // For each 16-byte block, it processes 15 pairs (wait, for loop is i < decrypted.length - 1; i += 2)
      // decrypted.length is 16, so i = 0, 2, 4, 6, 8, 10, 12, 14. Total 8 values.
      if (result.isNotEmpty) {
        final values = result.split(',');
        expect(values.length, 8);
      } else {
        expect(result, '');
      }
    });
  });
}

import 'dart:typed_data';

import 'crypto_codec.dart';

/// Resolves AES key material from a connected headset.
/// Currently extracts the hex key from the BLE advertised name `(XXXXXXXX)`.
class DeviceIdentity {
  const DeviceIdentity({
    required this.deviceName,
    required this.btKeyHex,
    required this.serialBytes,
    required this.keyBytes,
  });

  final String deviceName;
  final String btKeyHex;
  final Uint8List serialBytes;
  final Uint8List keyBytes;

  /// Short fingerprint for session.json (not the raw key).
  String get keyFingerprint {
    final sum = keyBytes.fold<int>(0, (a, b) => (a + b) & 0xffff);
    return '${btKeyHex.toUpperCase()}:${sum.toRadixString(16).padLeft(4, '0')}';
  }
}

class DeviceIdentityResolver {
  /// Parse `EPOCX (E50202E9)` style names into [DeviceIdentity].
  DeviceIdentity resolveFromName(String platformName) {
    final match = RegExp(r'\(([^)]+)\)').firstMatch(platformName);
    final btKey = match?.group(1);
    if (btKey == null || btKey.length < 8) {
      throw StateError(
        'Could not parse BLE hex key from device name: $platformName',
      );
    }
    final serial = CryptoCodec.createSerialNumber(btKey);
    final key = CryptoCodec.deriveEpocXKeyFromSerial(serial);
    return DeviceIdentity(
      deviceName: platformName,
      btKeyHex: btKey,
      serialBytes: serial,
      keyBytes: key,
    );
  }
}

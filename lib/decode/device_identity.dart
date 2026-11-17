import 'dart:typed_data';

import 'crypto_codec.dart';

/// Resolves AES key material from a connected headset.
/// Prefers the BLE advertised name; falls back to DIS serial when needed.
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

/// Parsed advertising name pieces (Android `getSerialFromDeviceName` patterns).
class AdvertisedHeadset {
  const AdvertisedHeadset({
    required this.productToken,
    required this.serialHex,
  });

  final String productToken;
  final String serialHex;
}

class DeviceIdentityResolver {
  /// Android EmbeddedLibQt advertising name patterns:
  /// `Name SERIAL`, `Name-SERIAL`, `Name+ (SERIAL)`.
  static final List<RegExp> _namePatterns = [
    RegExp(r'^([A-Za-z0-9+ ]+) \(([A-Z0-9]+)\)$'),
    RegExp(r'^([A-Za-z0-9]+)-([A-Z0-9]+)$'),
    RegExp(r'^([A-Za-z0-9]+) ([A-Z0-9]+)$'),
  ];

  /// Returns null when [platformName] does not match an Emotiv advertising form.
  AdvertisedHeadset? tryParseAdvertisement(String platformName) {
    final name = platformName.trim();
    if (name.isEmpty) return null;
    for (final re in _namePatterns) {
      final match = re.firstMatch(name);
      if (match == null) continue;
      final serial = match.group(2)!;
      if (serial.length < 8) continue;
      return AdvertisedHeadset(
        productToken: match.group(1)!.trim(),
        serialHex: serial,
      );
    }
    return null;
  }

  bool looksLikeEmotivHeadset(String platformName) =>
      tryParseAdvertisement(platformName) != null;

  /// Parse advertised name into [DeviceIdentity].
  DeviceIdentity resolveFromName(String platformName) {
    final parsed = tryParseAdvertisement(platformName);
    if (parsed == null) {
      throw StateError(
        'Could not parse BLE hex key from device name: $platformName',
      );
    }
    return _fromSerial(platformName, parsed.serialHex);
  }

  /// Resolve from a DIS / cached serial string when the advertised name fails.
  DeviceIdentity resolveFromSerialHex(String deviceName, String serialHex) {
    final hex = serialHex.trim().toUpperCase();
    if (hex.length < 8) {
      throw StateError('Serial hex too short: $serialHex');
    }
    return _fromSerial(deviceName, hex);
  }

  DeviceIdentity? tryResolveFromName(String platformName) {
    try {
      return resolveFromName(platformName);
    } catch (_) {
      return null;
    }
  }

  DeviceIdentity _fromSerial(String deviceName, String btKey) {
    final serial = CryptoCodec.createSerialNumber(btKey);
    final key = CryptoCodec.deriveEpocXKeyFromSerial(serial);
    return DeviceIdentity(
      deviceName: deviceName,
      btKeyHex: btKey.toUpperCase(),
      serialBytes: serial,
      keyBytes: key,
    );
  }
}

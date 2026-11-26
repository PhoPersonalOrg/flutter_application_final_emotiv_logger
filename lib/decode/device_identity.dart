import 'dart:typed_data';

import '../domain/ble_uuids.dart';
import 'crypto_codec.dart';
import 'headset_config.dart';

/// Resolved hardware identity and session key material (`V2` or `V4`) for a
/// connected Emotiv EPOC X headset.
class DeviceIdentity {
  const DeviceIdentity({
    required this.deviceName,
    required this.btKeyHex,
    required this.disSerialHex,
    required this.serialOrigin,
    required this.rawSerialBytes,
    required this.sessionKey,
  });

  final String deviceName;

  /// Public 8-character uppercase hex serial (`b[0..4]`, e.g. `"E50202E9"`).
  /// Kept in `session.json` as `btKeyHex` for replay compatibility.
  final String btKeyHex;

  /// Full 8- or 10-character uppercase hex serial (`b[0..5]` from DIS `0x2A25`,
  /// e.g. `"E50202E92B"`, or 8-char fallback from advertised local name).
  final String disSerialHex;

  /// `'dis_0x2a25'` when read from GATT DIS `0x2A25`, or `'adv_name'` fallback.
  final String serialOrigin;

  /// Raw binary serial bytes (`4` or `5` bytes on BLE).
  final Uint8List rawSerialBytes;

  /// Active V2 (`AES-128-ECB`) or V4 (`AES-256-ECB`) session key.
  final EpocXSessionKey sessionKey;

  /// Raw AES key bytes (`16` bytes on V2, `32` bytes on V4).
  Uint8List get keyBytes => sessionKey.keyBytes;

  /// Short non-secret fingerprint written to `session.json`.
  String get keyFingerprint {
    final sum = keyBytes.fold<int>(0, (a, b) => (a + b) & 0xffff);
    return '${btKeyHex.toUpperCase()}:${sum.toRadixString(16).padLeft(4, '0')}';
  }
}

/// Parsed BLE advertising name tokens (`BTLEDeviceFactory` `0x14085bd40`).
class AdvertisedHeadset {
  const AdvertisedHeadset({
    required this.productToken,
    required this.serialHex,
  });

  final String productToken;
  final String serialHex;
}

class DeviceIdentityResolver {
  /// Verified Emotiv BLE local-name patterns (`03_BLE_GATT_Protocol.md` §2.3):
  /// - `"EPOCX (E50202E9)"`, `"EPOC+ (3B9A1204)"`
  /// - `"EPOCX-E50202E9"`
  /// - `"EPOCX E50202E9"`
  static final List<RegExp> _namePatterns = [
    RegExp(r'^([A-Za-z0-9+ ]+) \(([0-9A-Fa-f]{8,10})\)$'),
    RegExp(r'^([A-Za-z0-9+]+)-([0-9A-Fa-f]{8,10})$'),
    RegExp(r'^([A-Za-z0-9+]+) ([0-9A-Fa-f]{8,10})$'),
  ];

  /// Returns null when [platformName] does not match an Emotiv advertising form.
  AdvertisedHeadset? tryParseAdvertisement(String platformName) {
    final name = platformName.trim();
    if (name.isEmpty) return null;
    for (final re in _namePatterns) {
      final match = re.firstMatch(name);
      if (match == null) continue;
      final token = match.group(1)!.trim();
      final tokenUpper = token.toUpperCase();
      if (!tokenUpper.contains('EPOC') && !tokenUpper.contains('INSIGHT')) {
        continue;
      }
      final serial = match.group(2)!.toUpperCase();
      if (serial.length < 8) continue;
      return AdvertisedHeadset(
        productToken: token,
        serialHex: serial.substring(0, 8),
      );
    }
    return null;
  }

  bool looksLikeEmotivHeadset(String platformName) =>
      tryParseAdvertisement(platformName) != null;

  /// Whether a BLE scan hit should appear in the candidate headset list.
  ///
  /// Matches preferred devices, `81072f40-9f3d-11e3-a9dc-0002a5d5c51b` in
  /// `SCAN_RSP`, or Emotiv `ADV_IND` local names (`"EPOCX (E50202E9)"`).
  bool isEmotivScanCandidate(
    String name, {
    Iterable<String> serviceUuids = const [],
    bool isPreferred = false,
  }) {
    if (isPreferred) return true;
    if (tryParseAdvertisement(name) != null) return true;
    return EmotivBleUuids.advertisesScanService(serviceUuids);
  }

  /// Parse raw GATT DIS `0x2A25` bytes (`5` binary bytes on physical EPOC X,
  /// e.g. `[0xE5, 0x02, 0x02, 0xE9, 0x2B]`, with ASCII-hex fallback for mocks).
  Uint8List? parseDis0x2A25Bytes(List<int> raw) {
    if (raw.isEmpty) return null;
    if (raw.length == 4 || raw.length == 5) {
      // Physical EPOC X returns 5 raw binary bytes; guard against all-zero uninitialized buffers.
      if (raw.every((b) => b == 0)) return null;
      return Uint8List.fromList(raw);
    }
    final nonNull = raw.takeWhile((b) => b != 0).toList();
    if (nonNull.length == 4 || nonNull.length == 5) {
      if (nonNull.every((b) => b == 0)) return null;
      return Uint8List.fromList(nonNull);
    }
    final asciiCandidate = String.fromCharCodes(nonNull).trim().toUpperCase();
    if ((asciiCandidate.length == 8 || asciiCandidate.length == 10) &&
        RegExp(r'^[0-9A-F]+$').hasMatch(asciiCandidate)) {
      return CryptoCodec.hexToBytes(asciiCandidate);
    }
    return null;
  }

  /// Primary BLE identity & key resolver using DIS `0x2A25` (`5B` binary) +
  /// `0x2A26` (`headsetFirmware`), falling back to the advertised local name
  /// `"EPOCX (<8HEX>)"` when `0x2A25` is restricted or absent.
  DeviceIdentity resolveBleIdentity({
    required String deviceName,
    List<int>? dis0x2A25Bytes,
    int firmwareVersion = HeadsetConfig.defaultFirmwareVersion,
    int keyMode = HeadsetConfig.modeEpocX,
  }) {
    final parsedDis =
        dis0x2A25Bytes != null ? parseDis0x2A25Bytes(dis0x2A25Bytes) : null;
    if (parsedDis != null) {
      final btKeyHex = HeadsetConfig.bytesToUpperHex(parsedDis.sublist(0, 4));
      final disHex = HeadsetConfig.bytesToUpperHex(parsedDis);
      final effectiveName =
          deviceName.trim().isEmpty ? 'EPOCX ($btKeyHex)' : deviceName.trim();
      final sessionKey = CryptoCodec.deriveEpocXKey(
        parsedDis,
        firmwareVersion: firmwareVersion,
        keyMode: keyMode,
        transport: EpocXTransport.ble,
      );
      return DeviceIdentity(
        deviceName: effectiveName,
        btKeyHex: btKeyHex,
        disSerialHex: disHex,
        serialOrigin: 'dis_0x2a25',
        rawSerialBytes: parsedDis,
        sessionKey: sessionKey,
      );
    }

    final parsedAdv = tryParseAdvertisement(deviceName);
    if (parsedAdv != null) {
      final raw4 = CryptoCodec.hexToBytes(parsedAdv.serialHex);
      if (keyMode == HeadsetConfig.modeLegacyEpoc) {
        throw StateError(
          'Mode 3 requires 5-byte DIS 0x2A25 serial; only 4-byte adv serial available',
        );
      }
      final sessionKey = CryptoCodec.deriveEpocXKey(
        raw4,
        firmwareVersion: firmwareVersion,
        keyMode: keyMode,
        transport: EpocXTransport.ble,
      );
      return DeviceIdentity(
        deviceName: deviceName.trim(),
        btKeyHex: parsedAdv.serialHex,
        disSerialHex: parsedAdv.serialHex,
        serialOrigin: 'adv_name',
        rawSerialBytes: raw4,
        sessionKey: sessionKey,
      );
    }

    throw StateError(
      'Could not resolve EPOC X serial from DIS 0x2A25 or BLE name "$deviceName"',
    );
  }

  /// Resolve from advertised name (`"EPOCX (E50202E9)"`).
  DeviceIdentity resolveFromName(
    String platformName, {
    int firmwareVersion = HeadsetConfig.defaultFirmwareVersion,
    int keyMode = HeadsetConfig.modeEpocX,
  }) {
    return resolveBleIdentity(
      deviceName: platformName,
      firmwareVersion: firmwareVersion,
      keyMode: keyMode,
    );
  }

  /// Resolve from an explicit 8- or 10-char hex serial string.
  DeviceIdentity resolveFromSerialHex(
    String deviceName,
    String serialHex, {
    int firmwareVersion = HeadsetConfig.defaultFirmwareVersion,
    int keyMode = HeadsetConfig.modeEpocX,
  }) {
    final clean = serialHex.trim().toUpperCase().replaceFirst('EPOCX-', '');
    if ((clean.length != 8 && clean.length != 10) ||
        !RegExp(r'^[0-9A-F]+$').hasMatch(clean)) {
      throw StateError('Invalid BLE serial hex: "$serialHex"');
    }
    final raw = CryptoCodec.hexToBytes(clean);
    final btKeyHex = clean.substring(0, 8);
    final sessionKey = CryptoCodec.deriveEpocXKey(
      raw,
      firmwareVersion: firmwareVersion,
      keyMode: keyMode,
      transport: EpocXTransport.ble,
    );
    return DeviceIdentity(
      deviceName:
          deviceName.trim().isEmpty ? 'EPOCX ($btKeyHex)' : deviceName.trim(),
      btKeyHex: btKeyHex,
      disSerialHex: clean,
      serialOrigin: clean.length == 10 ? 'dis_0x2a25' : 'ble_hex',
      rawSerialBytes: raw,
      sessionKey: sessionKey,
    );
  }

  DeviceIdentity? tryResolveFromName(
    String platformName, {
    int firmwareVersion = HeadsetConfig.defaultFirmwareVersion,
    int keyMode = HeadsetConfig.modeEpocX,
  }) {
    try {
      return resolveFromName(
        platformName,
        firmwareVersion: firmwareVersion,
        keyMode: keyMode,
      );
    } catch (_) {
      return null;
    }
  }
}

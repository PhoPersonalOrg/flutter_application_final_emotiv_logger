/// Verified clean-room BLE GATT UUIDs and link constants for Emotiv EPOC X.
///
/// Ground truth: `CortexService.exe` (`4.8.16.1`) static & live USBPcap/Frida
/// verification (`03_BLE_GATT_Protocol.md` §3.1–3.2, §4, §7, §8).
///
/// Physical EPOC X uses vendor primary service `81072f40-...` exclusively and
/// requires zero challenge/unlock writes (`5d1c1b00` / `5d1c1b02 = 02 1E` is
/// MN8-only).
abstract final class EmotivBleUuids {
  /// Primary EPOC X data & configuration GATT service (advertised in `SCAN_RSP`).
  static const epocXService = '81072F40-9F3D-11E3-A9DC-0002A5D5C51B';

  /// Backward-compatible alias for [epocXService].
  static const control = epocXService;

  /// Primary stream characteristic (`Notify` + CCCD `0x2902` <- `01 00`).
  ///
  /// On `fw > 0x0710`, emits `64`-byte (`2 x 32B` EEG) and `84`-byte (`0x54`,
  /// `2 x 32B` EEG + `20B` MEMS tail) notifications.
  static const dataStream = '81072F41-9F3D-11E3-A9DC-0002A5D5C51B';

  /// Backward-compatible alias for [dataStream].
  static const eeg = dataStream;

  /// Dedicated legacy MEMS stream (`Notify` + CCCD `0x2902`, used on `fw <= 0x0710`).
  static const legacyMotion = '81072F42-9F3D-11E3-A9DC-0002A5D5C51B';

  /// Backward-compatible alias for [legacyMotion].
  static const motion = legacyMotion;

  /// Unused auxiliary characteristic on `81072f40` (recognized and ignored).
  static const ignoredAux = '81072F43-9F3D-11E3-A9DC-0002A5D5C51B';

  /// 6-byte read-only headset mode configuration (`[flag, rateLo, rateHi, eegBits, memsRate, memsBits]`).
  static const headsetConfig = '81072F44-9F3D-11E3-A9DC-0002A5D5C51B';

  /// Standard Device Information Service (`0x180A`).
  static const deviceInfoService = '0000180A-0000-1000-8000-00805F9B34FB';

  /// DIS Model Number String (`0x2A24`, 32-byte build timestamp string on EPOC X).
  static const disModelNumber = '00002A24-0000-1000-8000-00805F9B34FB';

  /// DIS Serial Number (`0x2A25`, 5 raw binary bytes on physical EPOC X, e.g. `e5 02 02 e9 2b`).
  static const disSerialNumber = '00002A25-0000-1000-8000-00805F9B34FB';

  /// DIS Firmware Revision (`0x2A26`, 2 raw big-endian bytes `headset_fw`, e.g. `07 20` -> `0x0720`).
  static const disFirmwareRevision = '00002A26-0000-1000-8000-00805F9B34FB';

  /// DIS Hardware Revision (`0x2A27`, 1 byte).
  static const disHardwareRevision = '00002A27-0000-1000-8000-00805F9B34FB';

  /// DIS Software Revision (`0x2A28`, 2 raw big-endian bytes).
  static const disSoftwareRevision = '00002A28-0000-1000-8000-00805F9B34FB';

  /// DIS Manufacturer Name String (`0x2A29`, `"Emotiv"`).
  static const disManufacturerName = '00002A29-0000-1000-8000-00805F9B34FB';

  /// Standard Battery Service (`0x180F`) and Battery Level (`0x2A19`, 1 byte `0..100%`).
  static const batteryService = '0000180F-0000-1000-8000-00805F9B34FB';
  static const batteryLevel = '00002A19-0000-1000-8000-00805F9B34FB';

  /// Minimum ATT_MTU required for unfragmented `84B` notifications (`84 + 3` ATT header).
  static const int minAttMtu = 87;

  /// Preferred MTU requested by Central on Android (`>= 87`; headset replies `87`).
  static const int preferredRequestMtu = 247;

  /// Payload byte lengths on `81072f41` (`fw > 0x0710`) and `81072f42`.
  static const int eegMinBytes = 32;
  static const int motionMinBytes = 20;
  static const int bleCombinedEegBytes = 64;
  static const int bleSuperFrameBytes = 84;

  static bool isEeg(String uuid) => _matches128(uuid, dataStream);
  static bool isDataStream(String uuid) => _matches128(uuid, dataStream);
  static bool isMotion(String uuid) => _matches128(uuid, legacyMotion);
  static bool isLegacyMotion(String uuid) => _matches128(uuid, legacyMotion);
  static bool isIgnoredAux(String uuid) => _matches128(uuid, ignoredAux);
  static bool isHeadsetConfig(String uuid) => _matches128(uuid, headsetConfig);

  /// True when [uuid] is the EPOC X vendor service (`81072f40-...`).
  static bool isAdvertisedScanService(String uuid) =>
      _matches128(uuid, epocXService);

  /// True when any advertised UUID matches [epocXService].
  static bool advertisesScanService(Iterable<String> serviceUuids) {
    for (final uuid in serviceUuids) {
      if (isAdvertisedScanService(uuid)) return true;
    }
    return false;
  }

  static bool isDisModelNumber(String uuid) =>
      _matchesStandard16(uuid, '2A24', disModelNumber);

  static bool isDisSerialNumber(String uuid) =>
      _matchesStandard16(uuid, '2A25', disSerialNumber);

  static bool isDisFirmwareRevision(String uuid) =>
      _matchesStandard16(uuid, '2A26', disFirmwareRevision);

  static bool isDisHardwareRevision(String uuid) =>
      _matchesStandard16(uuid, '2A27', disHardwareRevision);

  static bool isDisSoftwareRevision(String uuid) =>
      _matchesStandard16(uuid, '2A28', disSoftwareRevision);

  /// Matches full or 16-bit Battery Level UUID (`0x2A19`).
  static bool isBatteryLevel(String uuid) =>
      _matchesStandard16(uuid, '2A19', batteryLevel);

  /// Maps a Battery Level (`0x2A19`) payload to percent `0..100`.
  /// Returns null when the payload is empty.
  static int? parseBatteryPercent(List<int> data) {
    if (data.isEmpty) return null;
    return data[0].clamp(0, 100);
  }

  static String _compact(String uuid) =>
      uuid.trim().toUpperCase().replaceAll('-', '');

  static bool _matches128(String uuid, String canonical128) =>
      _compact(uuid) == _compact(canonical128);

  static bool _matchesStandard16(
    String uuid,
    String short4Hex,
    String canonical128,
  ) {
    final id = _compact(uuid);
    return id == short4Hex || id == _compact(canonical128);
  }
}

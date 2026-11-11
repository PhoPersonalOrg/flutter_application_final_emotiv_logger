/// Emotiv Epoc X / Epoc+ BLE GATT UUIDs, as bound by EmotivPRO V4 Android
/// (`BTLEInputDevice::enableDataNotify` / `onCharacteristicChanged`).
abstract final class EmotivBleUuids {
  /// Data service A (advertised; used as the scan filter).
  static const control = '81072F40-9F3D-11E3-A9DC-0002A5D5C51B';
  static const eeg = '81072F41-9F3D-11E3-A9DC-0002A5D5C51B';
  static const motion = '81072F42-9F3D-11E3-A9DC-0002A5D5C51B';

  /// Headset configuration (mode, EEG rate, EEG resolution). Android reads
  /// it during discovery; see `HeadsetConfig.parse`.
  static const headsetConfig = '81072F44-9F3D-11E3-A9DC-0002A5D5C51B';

  /// Data service B. Its EEG characteristic is routed exactly like [eeg].
  static const serviceB = '5D1C1B00-863C-11E6-AE22-56B6B6499611';
  static const eegServiceB = '5D1C1B04-863C-11E6-AE22-56B6B6499611';

  /// Service B control characteristic; Android writes [serviceBControlInit]
  /// to it during discovery when it exists.
  static const serviceBControl = '5D1C1B02-863C-11E6-AE22-56B6B6499611';
  static const List<int> serviceBControlInit = [0x02, 0x1E];

  /// Standard Battery Level characteristic (one byte, percent).
  static const batteryLevel = '00002A19-0000-1000-8000-00805F9B34FB';

  static const int eegMinBytes = 32;
  static const int motionMinBytes = 20;

  static bool isEeg(String uuid) => _matches(uuid, eeg, eegServiceB);
  static bool isMotion(String uuid) => _matches(uuid, motion);
  static bool isServiceBControl(String uuid) =>
      _matches(uuid, serviceBControl);
  static bool isHeadsetConfig(String uuid) => _matches(uuid, headsetConfig);

  static bool _matches(String uuid, String a, [String? b]) {
    final id = uuid.toUpperCase();
    return id == a || (b != null && id == b);
  }
}

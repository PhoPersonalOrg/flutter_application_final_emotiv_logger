/// Emotiv Epoc X / Epoc+ BLE GATT UUIDs.
abstract final class EmotivBleUuids {
  static const control = '81072F40-9F3D-11E3-A9DC-0002A5D5C51B';
  static const eeg = '81072F41-9F3D-11E3-A9DC-0002A5D5C51B';
  static const motion = '81072F42-9F3D-11E3-A9DC-0002A5D5C51B';

  static const int eegMinBytes = 32;
  static const int motionMinBytes = 14;
}

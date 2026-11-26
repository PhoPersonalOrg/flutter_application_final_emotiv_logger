import 'dart:typed_data';

/// Active hardware configuration and firmware metadata for an Emotiv EPOC X.
///
/// Ground truth: `CortexService.exe` (`4.8.16.1`)
/// - `AbstractInputDevice::setHeadsetConfig` (`0x140be5300`)
/// - `InputDevice::fixupBleSampleRates` (`0x1408f5110`)
/// - `USBHidInputDevice` Feature/Output Report `0x00` (`0x1408bfa10`, `0x1408bdbc0`, `0x1408be360`)
/// - `BTLEInputDevice::extractHeadsetInfos` (`0x14088c630`, `0x14088d690`)
class HeadsetConfig {
  const HeadsetConfig({
    this.headsetType = headsetTypeEpocX,
    this.mode = modeEpocX,
    this.dongleFirmware = 0,
    this.headsetFirmware = defaultFirmwareVersion,
    this.serialHex,
    this.disSerialHex,
    this.eegRateHz = defaultEegRateHz,
    this.eegResolutionBits = defaultEegResolutionBits,
    this.memsRateHz = defaultMemsRateHz,
    this.memsResolutionBits = defaultMemsResolutionBits,
    this.cfgEcho = 0,
    this.rawConfigBytes,
  });

  static const int headsetTypeEpocX = 7;

  /// Legacy EPOC-compatible 14-bit bit-packed mode (`cfg[0] == 0x00`).
  static const int modeLegacyEpoc = 3;

  /// Standard EPOC X 16-bit / 14-bit word mode (`cfg[0] != 0x00`).
  static const int modeEpocX = 7;

  /// Fallback firmware when DIS `0x2A26` is unavailable on restricted BLE stacks.
  static const int defaultFirmwareVersion = 0x0720;

  /// Highest firmware version using Version 2 (`AES-128-ECB`, `preXor = 0x55`).
  /// Firmware `>= 0x073F` (`> 0x073E`) uses Version 4 (`AES-256-ECB`, `preXor = 0x14`).
  static const int v2MaxFirmwareVersion = 0x073E;

  /// Firmware cutoff for legacy BLE split packets & rate clamping (`<= 0x0710`).
  static const int legacyBleSplitMaxFirmware = 0x0710;

  static const int defaultEegRateHz = 128;
  static const int defaultEegResolutionBits = 16;
  static const int defaultMemsRateHz = 32;
  static const int defaultMemsResolutionBits = 16;

  final int headsetType;
  final int mode;
  final int dongleFirmware;
  final int headsetFirmware;

  /// Public 8-char uppercase hex serial (`b[0..4]`, e.g. `"E50202E9"`).
  final String? serialHex;

  /// Full 8- or 10-char uppercase hex serial from DIS `0x2A25` (`b[0..5]`, e.g. `"E50202E92B"`).
  final String? disSerialHex;

  final int eegRateHz;
  final int eegResolutionBits;
  final int memsRateHz;
  final int memsResolutionBits;
  final int cfgEcho;
  final Uint8List? rawConfigBytes;

  bool get isLegacyEpocMode => mode == modeLegacyEpoc;

  /// True when `headsetFirmware >= 0x073F` (`DataDecryption::isV4` `0x140e3e500`).
  bool get isV4 => headsetFirmware > v2MaxFirmwareVersion;

  int get cryptoVersion => isV4 ? 4 : 2;

  String get headsetFirmwareHex =>
      '0x${(headsetFirmware & 0xFFFF).toRadixString(16).toUpperCase().padLeft(4, '0')}';

  String? get rawConfigHex =>
      rawConfigBytes == null ? null : bytesToUpperHex(rawConfigBytes!);

  /// Standard EPOC X BLE defaults when `81072f44` is unreadable or absent.
  factory HeadsetConfig.bleDefaults({
    int headsetFirmware = defaultFirmwareVersion,
    String? serialHex,
    String? disSerialHex,
  }) {
    return HeadsetConfig(
      headsetType: headsetTypeEpocX,
      mode: modeEpocX,
      headsetFirmware: headsetFirmware,
      serialHex: serialHex,
      disSerialHex: disSerialHex,
      eegRateHz: defaultEegRateHz,
      eegResolutionBits: defaultEegResolutionBits,
      memsRateHz: defaultMemsRateHz,
      memsResolutionBits: defaultMemsResolutionBits,
    );
  }

  /// Parse DIS `0x2A26` Firmware Revision (`2` raw BE bytes on physical EPOC X,
  /// e.g. `[0x07, 0x20]` -> `0x0720`), applying `BTLEInputDevice`'s `"0200"`
  /// model-string override (`0x14088d690` -> `0x0710`) when present.
  static int? parseDisFirmware0x2A26(
    List<int> bytes, {
    String? modelNumber0x2A24,
  }) {
    if (modelNumber0x2A24 != null && modelNumber0x2A24.contains('0200')) {
      return legacyBleSplitMaxFirmware;
    }
    if (bytes.length == 2) {
      return ((bytes[0] & 0xFF) << 8) | (bytes[1] & 0xFF);
    }
    if (bytes.length >= 4) {
      final text = String.fromCharCodes(
        bytes.where((b) => b != 0),
      ).trim();
      final hexMatch = RegExp(r'^(?:0x)?([0-9A-Fa-f]{4})$').firstMatch(text);
      if (hexMatch != null) {
        return int.tryParse(hexMatch.group(1)!, radix: 16);
      }
    }
    return null;
  }

  /// Decode DIS `0x2A24` Model Number String (strip trailing NUL padding).
  static String? parseDisModel0x2A24(List<int> bytes) {
    if (bytes.isEmpty) return null;
    final nonNull = bytes.takeWhile((b) => b != 0).toList();
    if (nonNull.isEmpty) return null;
    final text = String.fromCharCodes(nonNull).trim();
    return text.isEmpty ? null : text;
  }

  /// Tolerant runtime parser for GATT characteristic `81072f44` (`6` bytes:
  /// `[flag, eegRateLo, eegRateHi, eegBits, memsRate, memsBits]`).
  ///
  /// Applies `fixupBleSampleRates` (`0x1408f5110`) when `headsetFirmware <= 0x0710`.
  /// Returns null when [bytes] is empty so callers can keep [HeadsetConfig.bleDefaults].
  static HeadsetConfig? parse(
    List<int> bytes, {
    int headsetFirmware = defaultFirmwareVersion,
    String? serialHex,
    String? disSerialHex,
  }) {
    if (bytes.isEmpty) return null;
    final raw = Uint8List.fromList(bytes);
    if (raw[0] == 0) {
      return HeadsetConfig(
        headsetType: headsetTypeEpocX,
        mode: modeLegacyEpoc,
        headsetFirmware: headsetFirmware,
        serialHex: serialHex,
        disSerialHex: disSerialHex,
        eegRateHz: 128,
        eegResolutionBits: 14,
        memsRateHz: 0,
        memsResolutionBits: 0,
        rawConfigBytes: raw,
      );
    }

    var eegRate = raw.length >= 3
        ? (raw[1] & 0xFF) | ((raw[2] & 0xFF) << 8)
        : defaultEegRateHz;
    var eegBits = raw.length >= 4 ? (raw[3] & 0xFF) : defaultEegResolutionBits;
    var memsRate = raw.length >= 5 ? (raw[4] & 0xFF) : defaultMemsRateHz;
    var memsBits =
        raw.length >= 6 ? (raw[5] & 0xFF) : defaultMemsResolutionBits;

    if (eegRate != 128 && eegRate != 256) {
      eegRate = defaultEegRateHz;
    }
    if (eegBits != 14 && eegBits != 16) {
      eegBits = defaultEegResolutionBits;
    }

    // InputDevice::fixupBleSampleRates (0x1408f5110): clamp legacy fw <= 0x0710 only.
    if (headsetFirmware <= legacyBleSplitMaxFirmware) {
      if (eegRate > 128) eegRate = 128;
      if (memsRate > 64) memsRate = 64;
    }

    return HeadsetConfig(
      headsetType: headsetTypeEpocX,
      mode: modeEpocX,
      headsetFirmware: headsetFirmware,
      serialHex: serialHex,
      disSerialHex: disSerialHex,
      eegRateHz: eegRate,
      eegResolutionBits: eegBits,
      memsRateHz: memsRate,
      memsResolutionBits: memsBits,
      rawConfigBytes: raw,
    );
  }

  /// Strict spec decoder matching `parse_ble_mode_81072f44` in `validate_epocx_spec.py`.
  static HeadsetConfig parseBleMode81072f44({
    required List<int> buf6,
    required List<int> serialBytes,
    required List<int> fw2b,
  }) {
    if (serialBytes.length < 4 ||
        serialBytes.length > 8 ||
        fw2b.length != 2 ||
        buf6.length < 6) {
      throw ArgumentError(
        'Invalid BLE DIS / 81072f44 byte lengths '
        '(serial=${serialBytes.length}, fw=${fw2b.length}, cfg=${buf6.length})',
      );
    }
    final fw = ((fw2b[0] & 0xFF) << 8) | (fw2b[1] & 0xFF);
    final serialHex = bytesToUpperHex(serialBytes.sublist(0, 4));
    final disSerialHex = bytesToUpperHex(
      serialBytes.length >= 5 ? serialBytes.sublist(0, 5) : serialBytes.sublist(0, 4),
    );
    final raw = Uint8List.fromList(buf6);

    if (raw[0] != 0) {
      var eegRate = (raw[1] & 0xFF) | ((raw[2] & 0xFF) << 8);
      final eegBits = raw[3] & 0xFF;
      var memsRate = raw[4] & 0xFF;
      final memsBits = raw[5] & 0xFF;
      if (fw <= legacyBleSplitMaxFirmware) {
        if (eegRate > 128) eegRate = 128;
        if (memsRate > 64) memsRate = 64;
      }
      return HeadsetConfig(
        headsetType: headsetTypeEpocX,
        mode: modeEpocX,
        headsetFirmware: fw,
        serialHex: serialHex,
        disSerialHex: disSerialHex,
        eegRateHz: eegRate,
        eegResolutionBits: eegBits,
        memsRateHz: memsRate,
        memsResolutionBits: memsBits,
        rawConfigBytes: raw,
      );
    }

    return HeadsetConfig(
      headsetType: headsetTypeEpocX,
      mode: modeEpocX,
      headsetFirmware: fw,
      serialHex: serialHex,
      disSerialHex: disSerialHex,
      eegRateHz: defaultEegRateHz,
      eegResolutionBits: defaultEegResolutionBits,
      memsRateHz: defaultMemsRateHz,
      memsResolutionBits: defaultMemsResolutionBits,
      rawConfigBytes: raw,
    );
  }

  /// Decode 18–32B USB HID Feature Report `0x00` (`0x1408bfa10` + `0x140be5300`).
  static HeadsetConfig parseUsbFeatureReport00(List<int> buf) {
    if (buf.length < 18 || (buf[0] & 0xFF) != 0x00) {
      throw ArgumentError(
        'Expected >=18B Feature Report 0x00, got len=${buf.length}',
      );
    }
    final cfgEcho = buf[2] & 0xFF;
    final dongleFw = ((buf[3] & 0xFF) << 8) | (buf[4] & 0xFF);
    final headsetFw = ((buf[5] & 0xFF) << 8) | (buf[6] & 0xFF);
    final serialHex = bytesToUpperHex(buf.sublist(7, 11));
    final disSerialHex = bytesToUpperHex(buf.sublist(7, 12));
    final extFlag = buf[12] & 0xFF;

    int eegRate;
    int eegBits;
    int memsRate;
    int memsBits;
    if (extFlag != 0) {
      eegRate = (buf[13] & 0xFF) | ((buf[14] & 0xFF) << 8);
      eegBits = buf[15] & 0xFF;
      memsRate = buf[16] & 0xFF;
      memsBits = buf[17] & 0xFF;
    } else {
      eegRate = defaultEegRateHz;
      eegBits = defaultEegResolutionBits;
      memsRate = defaultMemsRateHz;
      memsBits = defaultMemsResolutionBits;
    }

    return HeadsetConfig(
      headsetType: (headsetFw >> 8) == 0x07 ? headsetTypeEpocX : 0,
      mode: modeEpocX,
      dongleFirmware: dongleFw,
      headsetFirmware: headsetFw,
      serialHex: serialHex,
      disSerialHex: disSerialHex,
      eegRateHz: eegRate,
      eegResolutionBits: eegBits,
      memsRateHz: memsRate,
      memsResolutionBits: memsBits,
      cfgEcho: cfgEcho,
      rawConfigBytes: Uint8List.fromList(buf),
    );
  }

  /// Encode 33-byte USB HID Output Report `0x00` (`00 66 BB 20 12 <CFG> ...`, `0x1408bdbc0`).
  static Uint8List buildUsbModeReport({
    int eegRateHz = 256,
    int eegResolutionBits = 16,
    int memsRateHz = 64,
    int memsResolutionBits = 16,
  }) {
    if (eegRateHz != 128 && eegRateHz != 256) {
      throw ArgumentError('Invalid eegRateHz=$eegRateHz');
    }
    if (eegResolutionBits != 14 && eegResolutionBits != 16) {
      throw ArgumentError('Invalid eegResolutionBits=$eegResolutionBits');
    }
    final memsBitsField = switch (memsRateHz) {
      0 => 0x00,
      32 => 0x04,
      64 => 0x08,
      128 => 0x0C,
      _ => throw ArgumentError('Invalid memsRateHz=$memsRateHz'),
    };
    var cfg = 0x80;
    if (eegRateHz == 256) cfg |= 0x40;
    if (eegResolutionBits == 16) cfg |= 0x20;
    cfg |= memsBitsField;
    if (memsRateHz > 0 && memsResolutionBits == 16) {
      cfg |= 0x02;
    }
    final out = Uint8List(33);
    out[0] = 0x00;
    out[1] = 0x66;
    out[2] = 0xBB;
    out[3] = 0x20;
    out[4] = 0x12;
    out[5] = cfg;
    return out;
  }

  /// Check 32/33-byte USB HID input report for mode-switch ACK (`0x88, 0x12`, `0x1408be360`).
  static bool isUsbModeAck(List<int> hidIn) {
    return hidIn.length >= 4 &&
        (((hidIn[2] & 0xFF) == 0x88 && (hidIn[3] & 0xFF) == 0x12) ||
            (hidIn.length >= 5 &&
                (hidIn[3] & 0xFF) == 0x88 &&
                (hidIn[4] & 0xFF) == 0x12));
  }

  static String bytesToUpperHex(List<int> bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write((b & 0xFF).toRadixString(16).toUpperCase().padLeft(2, '0'));
    }
    return sb.toString();
  }
}

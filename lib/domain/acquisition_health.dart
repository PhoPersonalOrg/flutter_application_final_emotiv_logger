/// Live acquisition / sink health counters and hardware telemetry for UI and diagnostics.
class AcquisitionHealth {
  const AcquisitionHealth({
    this.eegPackets = 0,
    this.motionPackets = 0,
    this.eegHz = 0,
    this.motionHz = 0,
    this.decodeFailures = 0,
    this.decodeMessage,
    this.csvDropped = 0,
    this.lslDropped = 0,
    this.networkDropped = 0,
    this.uiDropped = 0,
    this.gapCount = 0,
    this.lslStatus = LslSubsystemStatus.idle,
    this.lslMessage,
    this.csvSessionPath,
    this.csvMessage,
    this.csvUsingFallback = false,
    this.reconnectAttempt = 0,
    this.networkEnabled = false,
    this.networkConnected = false,
    this.networkMessage,
    this.dropboxMessage,
    this.syncMessage,
    this.batteryPercent,
    this.headsetFirmwareHex,
    this.cryptoVersion,
    this.negotiatedMtu,
    this.configuredEegRateHz,
    this.configuredMotionRateHz,
  });

  final int eegPackets;
  final int motionPackets;
  final double eegHz;
  final double motionHz;
  final int decodeFailures;

  /// Text of the most recent decode failure or decrypt-plausibility warning.
  final String? decodeMessage;
  final int csvDropped;
  final int lslDropped;
  final int networkDropped;
  final int uiDropped;
  final int gapCount;
  final LslSubsystemStatus lslStatus;
  final String? lslMessage;
  final String? csvSessionPath;
  final String? csvMessage;
  final bool csvUsingFallback;
  final int reconnectAttempt;
  final bool networkEnabled;
  final bool networkConnected;
  final String? networkMessage;

  /// Last Dropbox one-shot upload status (legacy / manual paths).
  final String? dropboxMessage;

  /// Live Dropbox/SMB sync status while recording or after finalize.
  final String? syncMessage;

  /// Headset battery percentage (`0..100`) from in-band EEG (`counter == Fs-1`)
  /// or BLE Battery Level (`0x2A19`). Null if unknown.
  final int? batteryPercent;

  /// Active headset firmware read from DIS `0x2A26` (e.g. `"0x0720"`).
  final String? headsetFirmwareHex;

  /// Active hardware encryption version (`2` for `<= 0x073E`, `4` for `>= 0x073F`).
  final int? cryptoVersion;

  /// Negotiated BLE ATT MTU when reported by the OS stack (`>= 87` required).
  final int? negotiatedMtu;

  /// Active EEG sample rate from `81072f44` (`128` or `256` Hz).
  final int? configuredEegRateHz;

  /// Active Motion/MEMS sample rate from `81072f44` (`0`, `32`, `64`, or `128` Hz).
  final int? configuredMotionRateHz;

  bool get isLslHealthy => lslStatus == LslSubsystemStatus.active;

  AcquisitionHealth copyWith({
    int? eegPackets,
    int? motionPackets,
    double? eegHz,
    double? motionHz,
    int? decodeFailures,
    String? decodeMessage,
    bool clearDecodeMessage = false,
    int? csvDropped,
    int? lslDropped,
    int? networkDropped,
    int? uiDropped,
    int? gapCount,
    LslSubsystemStatus? lslStatus,
    String? lslMessage,
    String? csvSessionPath,
    String? csvMessage,
    bool? csvUsingFallback,
    int? reconnectAttempt,
    bool? networkEnabled,
    bool? networkConnected,
    String? networkMessage,
    String? dropboxMessage,
    bool clearDropboxMessage = false,
    String? syncMessage,
    bool clearSyncMessage = false,
    int? batteryPercent,
    bool clearBatteryPercent = false,
    String? headsetFirmwareHex,
    int? cryptoVersion,
    int? negotiatedMtu,
    int? configuredEegRateHz,
    int? configuredMotionRateHz,
    bool clearHardwareTelemetry = false,
  }) {
    return AcquisitionHealth(
      eegPackets: eegPackets ?? this.eegPackets,
      motionPackets: motionPackets ?? this.motionPackets,
      eegHz: eegHz ?? this.eegHz,
      motionHz: motionHz ?? this.motionHz,
      decodeFailures: decodeFailures ?? this.decodeFailures,
      decodeMessage: clearDecodeMessage
          ? null
          : (decodeMessage ?? this.decodeMessage),
      csvDropped: csvDropped ?? this.csvDropped,
      lslDropped: lslDropped ?? this.lslDropped,
      networkDropped: networkDropped ?? this.networkDropped,
      uiDropped: uiDropped ?? this.uiDropped,
      gapCount: gapCount ?? this.gapCount,
      lslStatus: lslStatus ?? this.lslStatus,
      lslMessage: lslMessage ?? this.lslMessage,
      csvSessionPath: csvSessionPath ?? this.csvSessionPath,
      csvMessage: csvMessage ?? this.csvMessage,
      csvUsingFallback: csvUsingFallback ?? this.csvUsingFallback,
      reconnectAttempt: reconnectAttempt ?? this.reconnectAttempt,
      networkEnabled: networkEnabled ?? this.networkEnabled,
      networkConnected: networkConnected ?? this.networkConnected,
      networkMessage: networkMessage ?? this.networkMessage,
      dropboxMessage: clearDropboxMessage
          ? null
          : (dropboxMessage ?? this.dropboxMessage),
      syncMessage: clearSyncMessage
          ? null
          : (syncMessage ?? this.syncMessage),
      batteryPercent: (clearBatteryPercent || clearHardwareTelemetry)
          ? null
          : (batteryPercent ?? this.batteryPercent),
      headsetFirmwareHex: clearHardwareTelemetry
          ? null
          : (headsetFirmwareHex ?? this.headsetFirmwareHex),
      cryptoVersion: clearHardwareTelemetry
          ? null
          : (cryptoVersion ?? this.cryptoVersion),
      negotiatedMtu: clearHardwareTelemetry
          ? null
          : (negotiatedMtu ?? this.negotiatedMtu),
      configuredEegRateHz: clearHardwareTelemetry
          ? null
          : (configuredEegRateHz ?? this.configuredEegRateHz),
      configuredMotionRateHz: clearHardwareTelemetry
          ? null
          : (configuredMotionRateHz ?? this.configuredMotionRateHz),
    );
  }
}

enum LslSubsystemStatus { idle, active, degraded, disabled }

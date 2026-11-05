/// Live acquisition / sink health counters for UI and diagnostics.
class AcquisitionHealth {
  const AcquisitionHealth({
    this.eegPackets = 0,
    this.motionPackets = 0,
    this.eegHz = 0,
    this.motionHz = 0,
    this.decodeFailures = 0,
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
  });

  final int eegPackets;
  final int motionPackets;
  final double eegHz;
  final double motionHz;
  final int decodeFailures;
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

  bool get isLslHealthy => lslStatus == LslSubsystemStatus.active;

  AcquisitionHealth copyWith({
    int? eegPackets,
    int? motionPackets,
    double? eegHz,
    double? motionHz,
    int? decodeFailures,
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
  }) {
    return AcquisitionHealth(
      eegPackets: eegPackets ?? this.eegPackets,
      motionPackets: motionPackets ?? this.motionPackets,
      eegHz: eegHz ?? this.eegHz,
      motionHz: motionHz ?? this.motionHz,
      decodeFailures: decodeFailures ?? this.decodeFailures,
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
    );
  }
}

enum LslSubsystemStatus { idle, active, degraded, disabled }

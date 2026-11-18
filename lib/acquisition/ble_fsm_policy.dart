import '../domain/acquisition_state.dart';

/// Pure guards for the BLE acquisition state machine.
///
/// Kept free of `flutter_blue_plus` so unit tests can cover transition policy
/// without mocking the radio.
abstract final class BleFsmPolicy {
  /// Scan may start from idle, failed, or an existing device-list scan state.
  static bool canStartScan(AcquisitionState state) =>
      state is AcquisitionIdle ||
      state is AcquisitionFailed ||
      state is AcquisitionScanning;

  /// User/auto connect must not interrupt an in-flight link lifecycle.
  static bool canConnect(AcquisitionState state) =>
      state is! AcquisitionConnecting &&
      state is! AcquisitionPreparing &&
      state is! AcquisitionStreaming &&
      state is! AcquisitionReconnecting &&
      state is! AcquisitionStopping;

  /// Link-lost recovery is only valid once Streaming (or an in-progress
  /// Reconnecting attempt) owns the session — never during prepare.
  static bool canHandleLinkLost(AcquisitionState state) =>
      state is AcquisitionStreaming || state is AcquisitionReconnecting;

  /// First caller wins; subsequent scanResults callbacks are ignored until
  /// [claimed] is cleared for a new auto-connect scan.
  static bool claimAutoConnect({
    required bool enabled,
    required bool alreadyClaimed,
  }) =>
      enabled && !alreadyClaimed;
}

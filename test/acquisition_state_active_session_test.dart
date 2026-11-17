import 'package:flutter_emotiv_logger/domain/acquisition_health.dart';
import 'package:flutter_emotiv_logger/domain/acquisition_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const path = '/tmp/session_active';
  const health = AcquisitionHealth(csvSessionPath: path);

  test('activeCsvSessionPath only set while preparing/streaming/stopping', () {
    expect(
      const AcquisitionPreparing(
        deviceName: 'EPOC',
        sessionDir: path,
        health: health,
      ).activeCsvSessionPath,
      path,
    );
    expect(
      const AcquisitionStreaming(
        deviceName: 'EPOC',
        sessionDir: path,
        health: health,
      ).activeCsvSessionPath,
      path,
    );
    expect(
      const AcquisitionStopping(deviceName: 'EPOC', health: health)
          .activeCsvSessionPath,
      path,
    );
  });

  test('Idle after Stop keeps health path but is not active for Sessions', () {
    const idle = AcquisitionIdle(health: health);
    expect(idle.health.csvSessionPath, path);
    expect(idle.activeCsvSessionPath, isNull);
  });

  test('Failed / Reconnecting / Scanning do not mark session active', () {
    expect(
      const AcquisitionFailed(message: 'x', health: health).activeCsvSessionPath,
      isNull,
    );
    expect(
      const AcquisitionReconnecting(
        deviceName: 'EPOC',
        attempt: 1,
        nextRetryIn: Duration(seconds: 1),
        health: health,
      ).activeCsvSessionPath,
      isNull,
    );
    expect(
      const AcquisitionScanning(devices: [], health: health)
          .activeCsvSessionPath,
      isNull,
    );
  });
}

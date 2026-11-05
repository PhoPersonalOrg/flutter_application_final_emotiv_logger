import 'package:flutter_emotiv_logger/domain/acquisition_health.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('health surfaces CSV fallback message without failing LSL/acquisition', () {
    const streamingHealth = AcquisitionHealth(
      eegHz: 128,
      csvUsingFallback: true,
      csvMessage: 'CSV using app documents (custom path denied: PathAccessException)',
      csvSessionPath: '/tmp/docs/session_x',
      lslStatus: LslSubsystemStatus.active,
    );

    expect(streamingHealth.csvUsingFallback, isTrue);
    expect(streamingHealth.csvMessage, contains('custom path denied'));
    expect(streamingHealth.isLslHealthy, isTrue);
    expect(streamingHealth.eegHz, 128);
  });
}

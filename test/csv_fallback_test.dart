import 'package:flutter_emotiv_logger/app/save_directory_policy.dart';
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

  test('null preferred path is not a fallback (documents-only success)', () {
    // When effectiveSaveDirectory returns null, CsvSink opens app documents
    // directly and sets usedFallback=false (not "custom path denied").
    expect(effectiveSaveDirectory(null, isIOS: false), isNull);
    expect(effectiveSaveDirectory('/tmp/eeg', isIOS: true), isNull);

    const okHealth = AcquisitionHealth(
      csvUsingFallback: false,
      csvMessage: 'CSV writing to app documents: /tmp/docs/session_x',
      csvSessionPath: '/tmp/docs/session_x',
    );
    expect(okHealth.csvUsingFallback, isFalse);
    expect(okHealth.csvMessage, isNot(contains('custom path denied')));
  });
}

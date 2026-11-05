import 'package:flutter/material.dart';
import 'package:flutter_emotiv_logger/domain/acquisition_health.dart';
import 'package:flutter_emotiv_logger/domain/acquisition_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Streaming with degraded LSL remains Streaming', () {
    const health = AcquisitionHealth(
      lslStatus: LslSubsystemStatus.degraded,
      lslMessage: 'LSL unavailable',
      eegHz: 128,
    );
    const state = AcquisitionStreaming(
      deviceName: 'EPOCX (E50202E9)',
      sessionDir: '/tmp/session',
      health: health,
    );
    expect(state.label, 'Streaming');
    expect(state.health.lslStatus, LslSubsystemStatus.degraded);
    expect(state.health.isLslHealthy, isFalse);
  });

  testWidgets('MaterialApp builds', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('ok'))),
    );
    expect(find.text('ok'), findsOneWidget);
  });
}

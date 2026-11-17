import 'package:flutter/material.dart';
import 'package:flutter_emotiv_logger/app/root_shell.dart';
import 'package:flutter_emotiv_logger/domain/acquisition_health.dart';
import 'package:flutter_emotiv_logger/domain/acquisition_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  testWidgets('RootShell shows Record and Sessions tabs', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: RootShell()),
      ),
    );
    await tester.pump();
    // Allow async providers / permission requests to settle without hanging.
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Record'), findsOneWidget);
    expect(find.text('Sessions'), findsOneWidget);

    await tester.tap(find.text('Sessions'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // Sessions AppBar title (may appear twice with nav label).
    expect(find.text('Sessions'), findsWidgets);
    // Empty state, loading spinner, or list — any settled Sessions body.
    final empty = find.textContaining('No recording sessions yet');
    final loading = find.byType(CircularProgressIndicator);
    final error = find.textContaining('Error:');
    expect(
      empty.evaluate().isNotEmpty ||
          loading.evaluate().isNotEmpty ||
          error.evaluate().isNotEmpty ||
          find.byType(RefreshIndicator).evaluate().isNotEmpty,
      isTrue,
    );
  });
}

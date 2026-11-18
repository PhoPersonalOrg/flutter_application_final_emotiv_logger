import 'package:flutter/material.dart';
import 'package:flutter_emotiv_logger/app/home_page.dart';
import 'package:flutter_emotiv_logger/app/providers.dart';
import 'package:flutter_emotiv_logger/domain/acquisition_health.dart';
import 'package:flutter_emotiv_logger/domain/acquisition_state.dart';
import 'package:flutter_emotiv_logger/domain/ble_uuids.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('EmotivBleUuids battery', () {
    test('isBatteryLevel matches full and short UUID forms', () {
      expect(
        EmotivBleUuids.isBatteryLevel(EmotivBleUuids.batteryLevel),
        isTrue,
      );
      expect(
        EmotivBleUuids.isBatteryLevel('00002a19-0000-1000-8000-00805f9b34fb'),
        isTrue,
      );
      expect(EmotivBleUuids.isBatteryLevel('2A19'), isTrue);
      expect(EmotivBleUuids.isBatteryLevel('2a19'), isTrue);
      expect(EmotivBleUuids.isBatteryLevel('2A25'), isFalse);
    });

    test('parseBatteryPercent maps and clamps BAS payload', () {
      expect(EmotivBleUuids.parseBatteryPercent([]), isNull);
      expect(EmotivBleUuids.parseBatteryPercent([0]), 0);
      expect(EmotivBleUuids.parseBatteryPercent([73]), 73);
      expect(EmotivBleUuids.parseBatteryPercent([100]), 100);
      expect(EmotivBleUuids.parseBatteryPercent([255]), 100);
      expect(EmotivBleUuids.parseBatteryPercent([42, 99]), 42);
    });
  });

  group('AcquisitionHealth batteryPercent', () {
    test('copyWith sets and clears batteryPercent', () {
      const base = AcquisitionHealth();
      expect(base.batteryPercent, isNull);

      final set = base.copyWith(batteryPercent: 64);
      expect(set.batteryPercent, 64);

      final cleared = set.copyWith(clearBatteryPercent: true);
      expect(cleared.batteryPercent, isNull);
    });
  });

  group('battery UI', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    testWidgets('HomePage shows Battery — when percent is unknown',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            acquisitionStateProvider.overrideWith(
              (ref) => Stream.value(const AcquisitionIdle()),
            ),
          ],
          child: const MaterialApp(home: HomePage()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('Battery'), findsOneWidget);
      // Battery metric shows em dash; CQ panel may also show placeholder dashes.
      expect(find.text('—'), findsWidgets);
      expect(find.textContaining('%'), findsNothing);
    });

    testWidgets('HomePage shows battery chip and metric when percent is set',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      const health = AcquisitionHealth(batteryPercent: 73, eegHz: 128);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            acquisitionStateProvider.overrideWith(
              (ref) => Stream.value(
                const AcquisitionStreaming(
                  deviceName: 'EPOCX (E50202E9)',
                  sessionDir: '/tmp/session',
                  health: health,
                ),
              ),
            ),
          ],
          child: const MaterialApp(home: HomePage()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('73%'), findsWidgets);
      expect(find.text('Battery'), findsOneWidget);
      expect(find.byIcon(Icons.battery_5_bar), findsOneWidget);
    });
  });
}

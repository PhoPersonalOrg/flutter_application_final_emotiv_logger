import 'dart:async';

import 'package:flutter_emotiv_logger/acquisition/ble_fsm_policy.dart';
import 'package:flutter_emotiv_logger/acquisition/session_subscriptions.dart';
import 'package:flutter_emotiv_logger/domain/acquisition_health.dart';
import 'package:flutter_emotiv_logger/domain/acquisition_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BleFsmPolicy', () {
    test('canHandleLinkLost only for Streaming and Reconnecting', () {
      expect(
        BleFsmPolicy.canHandleLinkLost(
          const AcquisitionPreparing(
            deviceName: 'x',
            sessionDir: '',
          ),
        ),
        isFalse,
      );
      expect(
        BleFsmPolicy.canHandleLinkLost(
          const AcquisitionConnecting(deviceName: 'x'),
        ),
        isFalse,
      );
      expect(
        BleFsmPolicy.canHandleLinkLost(const AcquisitionIdle()),
        isFalse,
      );
      expect(
        BleFsmPolicy.canHandleLinkLost(
          const AcquisitionScanning(devices: []),
        ),
        isFalse,
      );
      expect(
        BleFsmPolicy.canHandleLinkLost(
          const AcquisitionStreaming(
            deviceName: 'x',
            sessionDir: '',
            health: AcquisitionHealth(),
          ),
        ),
        isTrue,
      );
      expect(
        BleFsmPolicy.canHandleLinkLost(
          const AcquisitionReconnecting(
            deviceName: 'x',
            attempt: 1,
            nextRetryIn: Duration(seconds: 1),
            health: AcquisitionHealth(),
          ),
        ),
        isTrue,
      );
    });

    test('canConnect blocks busy link states', () {
      expect(BleFsmPolicy.canConnect(const AcquisitionIdle()), isTrue);
      expect(
        BleFsmPolicy.canConnect(const AcquisitionScanning(devices: [])),
        isTrue,
      );
      expect(
        BleFsmPolicy.canConnect(
          const AcquisitionFailed(message: 'x'),
        ),
        isTrue,
      );
      expect(
        BleFsmPolicy.canConnect(
          const AcquisitionConnecting(deviceName: 'x'),
        ),
        isFalse,
      );
      expect(
        BleFsmPolicy.canConnect(
          const AcquisitionPreparing(deviceName: 'x', sessionDir: ''),
        ),
        isFalse,
      );
      expect(
        BleFsmPolicy.canConnect(
          const AcquisitionStreaming(
            deviceName: 'x',
            sessionDir: '',
            health: AcquisitionHealth(),
          ),
        ),
        isFalse,
      );
      expect(
        BleFsmPolicy.canConnect(
          const AcquisitionReconnecting(
            deviceName: 'x',
            attempt: 1,
            nextRetryIn: Duration(seconds: 1),
            health: AcquisitionHealth(),
          ),
        ),
        isFalse,
      );
    });

    test('claimAutoConnect allows only the first claim', () {
      expect(
        BleFsmPolicy.claimAutoConnect(enabled: true, alreadyClaimed: false),
        isTrue,
      );
      expect(
        BleFsmPolicy.claimAutoConnect(enabled: true, alreadyClaimed: true),
        isFalse,
      );
      expect(
        BleFsmPolicy.claimAutoConnect(enabled: false, alreadyClaimed: false),
        isFalse,
      );
    });

    test('canStartScan from Idle Failed Scanning only', () {
      expect(BleFsmPolicy.canStartScan(const AcquisitionIdle()), isTrue);
      expect(
        BleFsmPolicy.canStartScan(const AcquisitionFailed(message: 'x')),
        isTrue,
      );
      expect(
        BleFsmPolicy.canStartScan(const AcquisitionScanning(devices: [])),
        isTrue,
      );
      expect(
        BleFsmPolicy.canStartScan(
          const AcquisitionConnecting(deviceName: 'x'),
        ),
        isFalse,
      );
    });
  });

  group('AcquisitionScanning soft error', () {
    test('connect failure shape keeps devices and errorMessage', () {
      const devices = [
        DiscoveredDevice(id: 'aa:bb', name: 'EPOCX (E50202E9)', isPreferred: true),
      ];
      final scanning = AcquisitionScanning(
        devices: devices,
        active: false,
        preferredId: 'aa:bb',
        errorMessage: 'Connect failed: timeout',
      );
      expect(scanning.devices, hasLength(1));
      expect(scanning.errorMessage, contains('Connect failed'));
      expect(scanning.active, isFalse);

      final cleared = scanning.copyWith(clearErrorMessage: true, active: true);
      expect(cleared.errorMessage, isNull);
      expect(cleared.devices, hasLength(1));
      expect(cleared.active, isTrue);
    });
  });

  group('SessionSubscriptions bags', () {
    test('cancelAll on one bag leaves the other intact', () async {
      final scan = SessionSubscriptions();
      final link = SessionSubscriptions();
      final scanCtrl = StreamController<int>.broadcast();
      final linkCtrl = StreamController<int>.broadcast();

      scan.add(scanCtrl.stream.listen((_) {}));
      link.add(linkCtrl.stream.listen((_) {}));
      expect(scan.length, 1);
      expect(link.length, 1);

      await scan.cancelAll();
      expect(scan.isEmpty, isTrue);
      expect(link.length, 1);

      await link.cancelAll();
      expect(link.isEmpty, isTrue);

      await scanCtrl.close();
      await linkCtrl.close();
    });
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_emotiv_logger/services/network_streamer.dart';
import 'package:flutter_emotiv_logger/settings/app_settings.dart';

void main() {
  group('NetworkStreamer', () {
    test('matchesDestination works correctly', () {
      final streamer = NetworkStreamer(
        host: '127.0.0.1',
        port: 8080,
        protocol: NetworkProtocol.udp,
      );

      expect(
        streamer.matchesDestination(
          otherHost: '127.0.0.1',
          otherPort: 8080,
          otherProtocol: NetworkProtocol.udp,
        ),
        isTrue,
      );

      expect(
        streamer.matchesDestination(
          otherHost: '192.168.1.1',
          otherPort: 8080,
          otherProtocol: NetworkProtocol.udp,
        ),
        isFalse,
      );

      expect(
        streamer.matchesDestination(
          otherHost: '127.0.0.1',
          otherPort: 9090,
          otherProtocol: NetworkProtocol.udp,
        ),
        isFalse,
      );

      expect(
        streamer.matchesDestination(
          otherHost: '127.0.0.1',
          otherPort: 8080,
          otherProtocol: NetworkProtocol.tcp,
        ),
        isFalse,
      );
    });

    test('updateDeviceId updates the device ID', () {
      final streamer = NetworkStreamer(
        host: '127.0.0.1',
        port: 8080,
        protocol: NetworkProtocol.udp,
        deviceId: 'device-1',
      );

      expect(streamer.deviceId, 'device-1');

      streamer.updateDeviceId('device-2');
      expect(streamer.deviceId, 'device-2');
    });

    group('UDP Streaming', () {
      late RawDatagramSocket serverSocket;
      late NetworkStreamer streamer;

      setUp(() async {
        serverSocket = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
        streamer = NetworkStreamer(
          host: '127.0.0.1',
          port: serverSocket.port,
          protocol: NetworkProtocol.udp,
          deviceId: 'test-device',
        );
      });

      tearDown(() async {
        await streamer.dispose();
        serverSocket.close();
      });

      test('sends payload over UDP successfully', () async {
        await streamer.start();
        expect(streamer.isConnected, isTrue);

        await streamer.sendSample(
          streamName: 'EEG',
          values: [1.0, 2.0, 3.0],
          timestampSeconds: 100.0,
          metadata: {'channel': 'O1'},
        );

        final event = await serverSocket.first;
        expect(event, equals(RawSocketEvent.read));

        final datagram = serverSocket.receive();
        expect(datagram, isNotNull);

        final payload = utf8.decode(datagram!.data);
        final json = jsonDecode(payload) as Map<String, dynamic>;

        expect(json['type'], 'EEG');
        expect(json['timestamp'], 100.0);
        expect(json['deviceId'], 'test-device');
        expect(json['values'], [1.0, 2.0, 3.0]);
        expect(json['meta'], {'channel': 'O1'});
      });
    });

    group('TCP Streaming', () {
      late ServerSocket serverSocket;
      late NetworkStreamer streamer;
      Socket? clientConnection;

      setUp(() async {
        serverSocket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        serverSocket.listen((socket) {
          clientConnection = socket;
        });

        streamer = NetworkStreamer(
          host: '127.0.0.1',
          port: serverSocket.port,
          protocol: NetworkProtocol.tcp,
          deviceId: 'test-device-tcp',
        );
      });

      tearDown(() async {
        await streamer.dispose();
        await clientConnection?.close();
        await serverSocket.close();
      });

      test('sends payload over TCP successfully', () async {
        await streamer.start();
        expect(streamer.isConnected, isTrue);

        // Wait a tick for the connection to be accepted by the ServerSocket
        await Future.delayed(const Duration(milliseconds: 100));
        expect(clientConnection, isNotNull);

        await streamer.sendSample(
          streamName: 'Motion',
          values: [4.0, 5.0, 6.0],
          timestampSeconds: 200.0,
        );

        final data = await clientConnection!.first;
        final payload = utf8.decode(data);
        final json = jsonDecode(payload) as Map<String, dynamic>;

        expect(json['type'], 'Motion');
        expect(json['timestamp'], 200.0);
        expect(json['deviceId'], 'test-device-tcp');
        expect(json['values'], [4.0, 5.0, 6.0]);
        expect(json['meta'], isNull);
      });
    });

    group('Error Handling and Status Stream', () {
      test('emits error status when TCP connection fails', () async {
        final streamer = NetworkStreamer(
          host: '127.0.0.1',
          // Pick a random unassigned port where connection should be refused
          port: 54321,
          protocol: NetworkProtocol.tcp,
        );

        final statuses = <NetworkStreamStatus>[];
        final sub = streamer.statusStream.listen(statuses.add);

        // Expect start() to throw due to connection refused
        await expectLater(streamer.start(), throwsA(isA<SocketException>()));
        expect(streamer.isConnected, isFalse);

        await Future.delayed(const Duration(milliseconds: 10)); // Allow async stream events to propagate

        expect(statuses.length, greaterThanOrEqualTo(2));
        // First status is usually "Resolving..."
        expect(statuses[0].message, contains('Resolving'));

        // Final status should contain the error
        final lastStatus = statuses.last;
        expect(lastStatus.enabled, isTrue);
        expect(lastStatus.connected, isFalse);
        expect(lastStatus.message, contains('Network stream error'));

        await sub.cancel();
        await streamer.dispose();
      });

      test('stop() resets state and emits disabled status', () async {
        final streamer = NetworkStreamer(
          host: '127.0.0.1',
          port: 8080,
          protocol: NetworkProtocol.udp,
        );

        final statuses = <NetworkStreamStatus>[];
        final sub = streamer.statusStream.listen(statuses.add);

        await streamer.stop();
        expect(streamer.isConnected, isFalse);

        await Future.delayed(const Duration(milliseconds: 10)); // Allow async stream events to propagate
        expect(statuses.isNotEmpty, isTrue);

        final lastStatus = statuses.last;
        expect(lastStatus.enabled, isFalse);
        expect(lastStatus.connected, isFalse);
        expect(lastStatus.message, contains('disabled'));

        await sub.cancel();
        await streamer.dispose();
      });
    });
  });
}

import 'dart:async';
import 'dart:io';

import 'package:flutter_emotiv_logger/app/settings.dart';
import 'package:flutter_emotiv_logger/domain/acquisition_health.dart';
import 'package:flutter_emotiv_logger/sinks/network_sink.dart';
import 'package:flutter_emotiv_logger/sinks/sample_hub.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('hung DNS lookup times out and reports health error without throwing', () async {
    var health = const AcquisitionHealth();
    final hub = SampleHub(onHealth: (fn) => health = fn(health));
    final never = Completer<List<InternetAddress>>();
    final sink = NetworkSink(
      hub: hub,
      onHealth: (fn) => health = fn(health),
      lookupTimeout: const Duration(milliseconds: 30),
      hostLookup: (_) => never.future,
    );

    await sink.configure(
      settings: const AppSettings(
        useNetworkStream: true,
        networkHost: 'unreachable.tailc8d2c6.ts.net',
        networkPort: 9878,
        networkProtocol: NetworkProtocol.udp,
      ),
      deviceId: 'deadbeef',
    );

    expect(health.networkEnabled, isTrue);
    expect(health.networkConnected, isFalse);
    expect(health.networkMessage, startsWith('Network error:'));

    await sink.stop();
    hub.dispose();
  });

  test('stop() invalidates in-flight DNS lookup so late resolution does not connect', () async {
    var health = const AcquisitionHealth();
    final hub = SampleHub(onHealth: (fn) => health = fn(health));
    final lookupStarted = Completer<void>();
    final pending = Completer<List<InternetAddress>>();
    final sink = NetworkSink(
      hub: hub,
      onHealth: (fn) => health = fn(health),
      lookupTimeout: const Duration(seconds: 5),
      hostLookup: (_) {
        lookupStarted.complete();
        return pending.future;
      },
    );

    final cfgFuture = sink.configure(
      settings: const AppSettings(
        useNetworkStream: true,
        networkHost: 'apogee.tailc8d2c6.ts.net',
        networkPort: 9878,
        networkProtocol: NetworkProtocol.udp,
      ),
    );
    await lookupStarted.future;
    expect(health.networkMessage, contains('Connecting'));

    await sink.stop();
    // Simulate late DNS resolution arriving after session teardown.
    pending.complete([InternetAddress.loopbackIPv4]);
    await cfgFuture;

    expect(health.networkConnected, isFalse);

    await sink.stop();
    hub.dispose();
  });

  test('newer configure() supersedes stale in-flight DNS lookup', () async {
    var health = const AcquisitionHealth();
    final hub = SampleHub(onHealth: (fn) => health = fn(health));
    final lookupStarted = Completer<void>();
    final staleLookup = Completer<List<InternetAddress>>();
    final sink = NetworkSink(
      hub: hub,
      onHealth: (fn) => health = fn(health),
      lookupTimeout: const Duration(seconds: 5),
      hostLookup: (_) {
        lookupStarted.complete();
        return staleLookup.future;
      },
    );

    final firstCfg = sink.configure(
      settings: const AppSettings(
        useNetworkStream: true,
        networkHost: 'stale.tailc8d2c6.ts.net',
        networkPort: 9878,
        networkProtocol: NetworkProtocol.udp,
      ),
    );
    await lookupStarted.future;

    // User disables network streaming while first DNS is still stuck.
    await sink.configure(
      settings: const AppSettings(useNetworkStream: false),
    );
    expect(health.networkEnabled, isFalse);
    expect(health.networkMessage, 'Network streaming disabled');

    // First lookup finally fails later — must not clobber disabled state.
    staleLookup.completeError(const SocketException('Failed host lookup'));
    await firstCfg;

    expect(health.networkEnabled, isFalse);
    expect(health.networkConnected, isFalse);
    expect(health.networkMessage, 'Network streaming disabled');

    await sink.stop();
    hub.dispose();
  });
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../app/settings.dart';
import '../domain/acquisition_health.dart';
import '../domain/samples.dart';
import 'sample_hub.dart';

/// Best-effort NDJSON UDP/TCP sink. Never awaits on the acquisition path.
class NetworkSink {
  NetworkSink({
    required this.hub,
    required this.onHealth,
  });

  final SampleHub hub;
  final void Function(AcquisitionHealth Function(AcquisitionHealth)) onHealth;

  String? deviceId;
  InternetAddress? _remote;
  RawDatagramSocket? _udp;
  Socket? _tcp;
  NetworkProtocol _protocol = NetworkProtocol.udp;
  int _port = AppSettings.defaultPort;
  bool _enabled = false;
  bool _connected = false;
  StreamSubscription? _sub;
  bool _draining = false;

  Future<void> configure({
    required AppSettings settings,
    String? deviceId,
  }) async {
    this.deviceId = deviceId;
    await stop();
    if (!settings.useNetworkStream) {
      onHealth(
        (h) => h.copyWith(
          networkEnabled: false,
          networkConnected: false,
          networkMessage: 'Network streaming disabled',
        ),
      );
      return;
    }

    _enabled = true;
    _protocol = settings.networkProtocol;
    _port = settings.networkPort;
    onHealth(
      (h) => h.copyWith(
        networkEnabled: true,
        networkConnected: false,
        networkMessage: 'Connecting ${settings.networkHost}:$_port...',
      ),
    );

    try {
      _remote = InternetAddress.tryParse(settings.networkHost) ??
          (await InternetAddress.lookup(settings.networkHost)).first;
      if (_protocol == NetworkProtocol.udp) {
        _udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      } else {
        _tcp = await Socket.connect(
          settings.networkHost,
          _port,
          timeout: const Duration(seconds: 5),
        );
        _tcp!.done.then((_) {
          _connected = false;
          onHealth(
            (h) => h.copyWith(
              networkConnected: false,
              networkMessage: 'TCP closed by remote',
            ),
          );
        });
      }
      _connected = true;
      _sub = hub.networkAvailable.listen((_) {
        if (!_draining) {
          unawaited(_drain());
        }
      });
      onHealth(
        (h) => h.copyWith(
          networkEnabled: true,
          networkConnected: true,
          networkMessage:
              'Streaming to ${_remote!.address}:$_port (${_protocol.name})',
        ),
      );
    } catch (e) {
      _connected = false;
      onHealth(
        (h) => h.copyWith(
          networkEnabled: true,
          networkConnected: false,
          networkMessage: 'Network error: $e',
        ),
      );
    }
  }

  Future<void> _drain() async {
    if (!_enabled || !_connected || _draining) return;
    _draining = true;
    try {
      for (final s in hub.takeNetworkEeg()) {
        _sendFireAndForget(
          type: 'eeg',
          values: s.values,
          timestampSeconds: s.wallClock.microsecondsSinceEpoch / 1e6,
          meta: {
            'sampleRate': EegSample.nominalRateHz,
            'channelCount': s.values.length,
          },
        );
      }
      for (final s in hub.takeNetworkMotion()) {
        _sendFireAndForget(
          type: 'motion',
          values: s.values,
          timestampSeconds: s.wallClock.microsecondsSinceEpoch / 1e6,
          meta: {
            'sampleRate': MotionSample.nominalRateHz,
            'channelCount': s.values.length,
          },
        );
      }
    } finally {
      _draining = false;
    }
  }

  void _sendFireAndForget({
    required String type,
    required List<double> values,
    required double timestampSeconds,
    Map<String, Object?>? meta,
  }) {
    final payload = utf8.encode(
      '${jsonEncode({
            'type': type,
            'timestamp': timestampSeconds,
            'deviceId': deviceId,
            'values': values,
            'meta': meta,
          })}\n',
    );
    try {
      if (_protocol == NetworkProtocol.udp) {
        final addr = _remote;
        final sock = _udp;
        if (addr != null && sock != null) {
          sock.send(payload, addr, _port);
        }
      } else {
        _tcp?.add(payload);
        // Intentionally no await flush — best-effort only.
      }
    } catch (e) {
      _connected = false;
      onHealth(
        (h) => h.copyWith(
          networkConnected: false,
          networkMessage: 'Send failed: $e',
        ),
      );
    }
  }

  Future<void> stop() async {
    _enabled = false;
    _connected = false;
    await _sub?.cancel();
    _sub = null;
    _udp?.close();
    _udp = null;
    await _tcp?.close();
    _tcp = null;
  }
}

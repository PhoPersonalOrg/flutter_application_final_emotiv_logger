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
    this.lookupTimeout = const Duration(seconds: 5),
    Future<List<InternetAddress>> Function(String host)? hostLookup,
  }) : _hostLookup = hostLookup ?? InternetAddress.lookup;

  final SampleHub hub;
  final void Function(AcquisitionHealth Function(AcquisitionHealth)) onHealth;
  final Duration lookupTimeout;
  final Future<List<InternetAddress>> Function(String host) _hostLookup;

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

  /// Bumped on every [configure] and [stop] so late async completions from an
  /// abandoned DNS/socket attempt never resurrect sockets or overwrite health.
  int _configGen = 0;

  Future<void> configure({
    required AppSettings settings,
    String? deviceId,
  }) async {
    final gen = ++_configGen;
    this.deviceId = deviceId;
    await _closeCurrent();
    if (_configGen != gen) return;

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
      InternetAddress resolved;
      final parsed = InternetAddress.tryParse(settings.networkHost);
      if (parsed != null) {
        resolved = parsed;
      } else {
        final addrs =
            await _hostLookup(settings.networkHost).timeout(lookupTimeout);
        if (_configGen != gen) return;
        if (addrs.isEmpty) {
          throw SocketException(
            'Failed host lookup: \'${settings.networkHost}\' (no addresses)',
          );
        }
        resolved = addrs.first;
      }

      if (_protocol == NetworkProtocol.udp) {
        final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
        if (_configGen != gen) {
          sock.close();
          return;
        }
        _udp = sock;
      } else {
        final sock = await Socket.connect(
          resolved,
          _port,
          timeout: const Duration(seconds: 5),
        );
        if (_configGen != gen) {
          await sock.close();
          return;
        }
        _tcp = sock;
        sock.done.then((_) {
          if (_configGen != gen) return;
          _connected = false;
          onHealth(
            (h) => h.copyWith(
              networkConnected: false,
              networkMessage: 'TCP closed by remote',
            ),
          );
        });
      }

      _remote = resolved;
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
              'Streaming to ${resolved.address}:$_port (${_protocol.name})',
        ),
      );
    } catch (e) {
      if (_configGen != gen) return;
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
    _configGen++;
    await _closeCurrent();
  }

  Future<void> _closeCurrent() async {
    _enabled = false;
    _connected = false;
    _remote = null;
    await _sub?.cancel();
    _sub = null;
    _udp?.close();
    _udp = null;
    await _tcp?.close();
    _tcp = null;
  }
}

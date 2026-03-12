import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../settings/app_settings.dart';

/// Status updates emitted by [NetworkStreamer].
class NetworkStreamStatus {
  const NetworkStreamStatus({
    required this.enabled,
    required this.connected,
    required this.protocol,
    this.message,
  });

  final bool enabled;
  final bool connected;
  final NetworkProtocol protocol;
  final String? message;

  NetworkStreamStatus copyWith({
    bool? enabled,
    bool? connected,
    NetworkProtocol? protocol,
    String? message,
  }) {
    return NetworkStreamStatus(
      enabled: enabled ?? this.enabled,
      connected: connected ?? this.connected,
      protocol: protocol ?? this.protocol,
      message: message ?? this.message,
    );
  }

  static NetworkStreamStatus disabled() => const NetworkStreamStatus(
    enabled: false,
    connected: false,
    protocol: NetworkProtocol.udp,
    message: 'Network streaming disabled',
  );
}

/// Sends EEG/motion samples to a remote host using UDP or TCP with timestamps.
class NetworkStreamer {
  NetworkStreamer({
    required this.host,
    required this.port,
    required this.protocol,
    String? deviceId,
  }) : deviceId = deviceId;

  final String host;
  final int port;
  final NetworkProtocol protocol;
  String? deviceId;

  InternetAddress? _remoteAddress;
  RawDatagramSocket? _udpSocket;
  Socket? _tcpSocket;
  bool _enabled = false;
  bool _connected = false;
  final StreamController<NetworkStreamStatus> _statusController =
      StreamController<NetworkStreamStatus>.broadcast();

  Stream<NetworkStreamStatus> get statusStream => _statusController.stream;
  bool get isConnected => _connected;

  bool matchesDestination({
    required String otherHost,
    required int otherPort,
    required NetworkProtocol otherProtocol,
  }) {
    return host == otherHost && port == otherPort && protocol == otherProtocol;
  }

  void updateDeviceId(String? newDeviceId) {
    deviceId = newDeviceId;
  }

  Future<void> start() async {
    if (_enabled && _connected) return;
    _enabled = true;
    _emitStatus(
      NetworkStreamStatus(
        enabled: true,
        connected: false,
        protocol: protocol,
        message: 'Resolving $host:$port...',
      ),
    );

    try {
      _remoteAddress = await _resolveHost();
      if (protocol == NetworkProtocol.udp) {
        await _ensureUdpSocket();
      } else {
        await _connectTcp();
      }
      _connected = true;
      _emitStatus(
        NetworkStreamStatus(
          enabled: true,
          connected: true,
          protocol: protocol,
          message:
              'Streaming to ${_remoteAddress?.address}:$port over ${protocol.name.toUpperCase()}',
        ),
      );
    } on Object catch (error) {
      _connected = false;
      _emitStatus(
        NetworkStreamStatus(
          enabled: true,
          connected: false,
          protocol: protocol,
          message: 'Network stream error: $error',
        ),
      );
      rethrow;
    }
  }

  Future<void> stop() async {
    _enabled = false;
    _connected = false;
    await _closeSockets();
    _emitStatus(NetworkStreamStatus.disabled());
  }

  Future<void> dispose() async {
    await stop();
    await _statusController.close();
  }

  Future<void> sendSample({
    required String streamName,
    required List<double> values,
    required double timestampSeconds,
    Map<String, Object?>? metadata,
  }) async {
    if (!_enabled || !_connected || values.isEmpty) return;

    final payload = <String, Object?>{
      'type': streamName,
      'timestamp': timestampSeconds,
      'deviceId': deviceId,
      'values': values,
      'meta': ?metadata,
    };

    final data = utf8.encode('${jsonEncode(payload)}\n');

    try {
      if (protocol == NetworkProtocol.udp) {
        final socket = _udpSocket;
        final address = _remoteAddress;
        if (socket != null && address != null) {
          socket.send(data, address, port);
        }
      } else {
        final socket = _tcpSocket;
        if (socket != null) {
          socket.add(data);
          await socket.flush();
        }
      }
    } on Object catch (error) {
      _connected = false;
      _emitStatus(
        NetworkStreamStatus(
          enabled: _enabled,
          connected: false,
          protocol: protocol,
          message: 'Send failed: $error',
        ),
      );
    }
  }

  Future<void> _ensureUdpSocket() async {
    _udpSocket ??= await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      0,
      reuseAddress: true,
    );
  }

  Future<void> _connectTcp() async {
    await _tcpSocket?.close();
    _tcpSocket = await Socket.connect(
      host,
      port,
      timeout: const Duration(seconds: 5),
    );

    _tcpSocket?.done.then((_) {
      if (_enabled) {
        _connected = false;
        _emitStatus(
          NetworkStreamStatus(
            enabled: true,
            connected: false,
            protocol: protocol,
            message: 'TCP connection closed by remote host',
          ),
        );
      }
    });
  }

  Future<InternetAddress> _resolveHost() async {
    final parsed = InternetAddress.tryParse(host);
    if (parsed != null) return parsed;
    final results = await InternetAddress.lookup(host);
    if (results.isEmpty) {
      throw const SocketException('Host lookup returned no results');
    }
    return results.first;
  }

  Future<void> _closeSockets() async {
    _udpSocket?.close();
    _udpSocket = null;
    await _tcpSocket?.close();
    _tcpSocket = null;
  }

  void _emitStatus(NetworkStreamStatus status) {
    if (!_statusController.isClosed) {
      _statusController.add(status);
    }
  }
}

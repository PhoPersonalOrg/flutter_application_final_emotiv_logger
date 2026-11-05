import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../domain/samples.dart';
import 'crypto_codec.dart';

/// Offloads AES/motion parse so BLE notify never blocks on crypto.
class DecodePipeline {
  DecodePipeline();

  Isolate? _isolate;
  SendPort? _workerPort;
  ReceivePort? _resultPort;
  final _ready = Completer<void>();
  final _results = StreamController<DecodeResult>.broadcast();
  StreamSubscription? _resultSub;

  Stream<DecodeResult> get results => _results.stream;

  Future<void> start() async {
    if (_isolate != null) return;

    final handshake = ReceivePort();
    _resultPort = ReceivePort();
    _isolate = await Isolate.spawn(
      _workerMain,
      _Bootstrap(handshake.sendPort, _resultPort!.sendPort),
    );
    _workerPort = await handshake.first as SendPort;
    handshake.close();

    _resultSub = _resultPort!.listen((message) {
      if (message is DecodeResult && !_results.isClosed) {
        _results.add(message);
      }
    });

    if (!_ready.isCompleted) _ready.complete();
  }

  /// Enqueue raw packet for decode (non-blocking after isolate is ready).
  void submit(RawPacket packet, {required Uint8List keyBytes}) {
    final port = _workerPort;
    if (port == null) return;
    port.send(
      _DecodeJob(
        kindIndex: packet.kind.index,
        bytes: packet.bytes,
        keyBytes: keyBytes,
        receiveMonoUs: packet.receiveMonoUs,
        wallMs: packet.wallClock.millisecondsSinceEpoch,
      ),
    );
  }

  Future<void> stop() async {
    await _resultSub?.cancel();
    _resultSub = null;
    _resultPort?.close();
    _resultPort = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _workerPort = null;
  }

  Future<void> dispose() async {
    await stop();
    await _results.close();
  }

  static void _workerMain(_Bootstrap boot) {
    final inbox = ReceivePort();
    boot.handshake.send(inbox.sendPort);
    final out = boot.results;

    inbox.listen((message) {
      if (message is! _DecodeJob) return;
      final kind = PacketKind.values[message.kindIndex];
      try {
        final wall = DateTime.fromMillisecondsSinceEpoch(message.wallMs);
        switch (kind) {
          case PacketKind.eeg:
            final values = CryptoCodec.decryptEeg(
              message.keyBytes,
              message.bytes,
            );
            out.send(
              DecodeEegOk(
                EegSample(
                  values: values,
                  receiveMonoUs: message.receiveMonoUs,
                  wallClock: wall,
                ),
              ),
            );
          case PacketKind.motion:
            final values = CryptoCodec.decodeMotion(message.bytes);
            out.send(
              DecodeMotionOk(
                MotionSample(
                  values: values,
                  receiveMonoUs: message.receiveMonoUs,
                  wallClock: wall,
                ),
              ),
            );
        }
      } catch (e) {
        out.send(
          DecodeFailed(
            DecodeError(
              kind: kind,
              message: e.toString(),
              receiveMonoUs: message.receiveMonoUs,
            ),
          ),
        );
      }
    });
  }
}

class _Bootstrap {
  _Bootstrap(this.handshake, this.results);
  final SendPort handshake;
  final SendPort results;
}

class _DecodeJob {
  _DecodeJob({
    required this.kindIndex,
    required this.bytes,
    required this.keyBytes,
    required this.receiveMonoUs,
    required this.wallMs,
  });

  final int kindIndex;
  final Uint8List bytes;
  final Uint8List keyBytes;
  final int receiveMonoUs;
  final int wallMs;
}

sealed class DecodeResult {
  const DecodeResult();
}

class DecodeEegOk extends DecodeResult {
  const DecodeEegOk(this.sample);
  final EegSample sample;
}

class DecodeMotionOk extends DecodeResult {
  const DecodeMotionOk(this.sample);
  final MotionSample sample;
}

class DecodeFailed extends DecodeResult {
  const DecodeFailed(this.error);
  final DecodeError error;
}

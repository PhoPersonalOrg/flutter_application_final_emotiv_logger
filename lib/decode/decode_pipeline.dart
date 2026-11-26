import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../domain/ble_uuids.dart';
import '../domain/samples.dart';
import 'crypto_codec.dart';
import 'eeg_counter_monitor.dart';
import 'headset_config.dart';

/// Background isolate worker offloading EPOC X `64B`/`84B` notification
/// splitting, `V2`/`V4` AES decryption, EEG/CQ/Battery unpacking, and IMU
/// orientation/scaling so BLE GATT callbacks never block.
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

  /// Configure per-session key schedule, sample rate, ADC bit depth, and
  /// headband IMU orientation, clearing held CQ/battery/counter state.
  void configureSession({
    required EpocXSessionKey sessionKey,
    int eegRateHz = HeadsetConfig.defaultEegRateHz,
    int eegResolutionBits = CryptoCodec.defaultEegResolutionBits,
    HeadbandPosition headbandPosition = HeadbandPosition.top,
  }) {
    _workerPort?.send(
      _ConfigureSessionJob(
        keyBytes: sessionKey.keyBytes,
        preXorByte: sessionKey.preXorByte,
        isV4: sessionKey.isV4,
        firmwareVersion: sessionKey.firmwareVersion,
        keyMode: sessionKey.keyMode,
        eegRateHz: eegRateHz,
        eegResolutionBits: eegResolutionBits,
        headbandPositionIndex: headbandPosition.index,
      ),
    );
  }

  /// Hot-update headband orientation (`"top"` vs `"back"`) without resetting CQ/counters.
  void updateHeadbandPosition(HeadbandPosition position) {
    _workerPort?.send(_UpdateOrientationJob(position.index));
  }

  /// Reset per-session decode state (EEG/MEMS counter monitors + CQ/battery hold).
  void resetSession({int? eegRateHz}) {
    _workerPort?.send(_ResetJob(eegRateHz: eegRateHz));
  }

  /// Enqueue a raw BLE notification for split/decrypt/decode.
  ///
  /// Accepts either [sessionKey] (full `V2`/`V4` metadata) or [keyBytes]
  /// (`16B` -> `V2`, `32B` -> `V4`).
  void submit(
    RawPacket packet, {
    EpocXSessionKey? sessionKey,
    Uint8List? keyBytes,
    int? eegRateHz,
    int eegResolutionBits = CryptoCodec.defaultEegResolutionBits,
    HeadbandPosition? headbandPosition,
  }) {
    final port = _workerPort;
    if (port == null) return;

    final resolvedKey = sessionKey ??
        (keyBytes != null ? EpocXSessionKey.fromRawKeyBytes(keyBytes) : null);
    if (resolvedKey == null) {
      throw ArgumentError('Either sessionKey or keyBytes must be provided');
    }

    port.send(
      _DecodeJob(
        kindIndex: packet.kind.index,
        bytes: packet.bytes,
        characteristicUuid: packet.characteristicUuid,
        keyBytes: resolvedKey.keyBytes,
        preXorByte: resolvedKey.preXorByte,
        isV4: resolvedKey.isV4,
        firmwareVersion: resolvedKey.firmwareVersion,
        keyMode: resolvedKey.keyMode,
        eegRateHz: eegRateHz,
        eegResolutionBits: eegResolutionBits,
        headbandPositionIndex: headbandPosition?.index,
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

    final eegCounters = EegCounterMonitor(
      modulus: HeadsetConfig.defaultEegRateHz,
    );
    final memsCounters = MemsCounterMonitor();
    final decoder = EpocXStatefulDecoder();

    bool keysEqual(EpocXSessionKey? a, _DecodeJob job) {
      if (a == null) return false;
      if (a.isV4 != job.isV4 ||
          a.preXorByte != job.preXorByte ||
          a.firmwareVersion != job.firmwareVersion ||
          a.keyBytes.length != job.keyBytes.length) {
        return false;
      }
      for (var i = 0; i < a.keyBytes.length; i++) {
        if (a.keyBytes[i] != job.keyBytes[i]) return false;
      }
      return true;
    }

    inbox.listen((message) {
      if (message is _ConfigureSessionJob) {
        decoder.eegRateHz = message.eegRateHz;
        decoder.eegResolutionBits = message.eegResolutionBits;
        decoder.headbandPosition =
            HeadbandPosition.values[message.headbandPositionIndex];
        decoder.configureKey(
          EpocXSessionKey(
            keyBytes: message.keyBytes,
            preXorByte: message.preXorByte,
            isV4: message.isV4,
            firmwareVersion: message.firmwareVersion,
            keyMode: message.keyMode,
          ),
        );
        decoder.reset();
        eegCounters.reset(newModulus: message.eegRateHz);
        memsCounters.reset();
        return;
      }

      if (message is _UpdateOrientationJob) {
        decoder.headbandPosition = HeadbandPosition.values[message.index];
        return;
      }

      if (message is _ResetJob) {
        if (message.eegRateHz != null) {
          decoder.eegRateHz = message.eegRateHz!;
        }
        decoder.reset();
        eegCounters.reset(newModulus: message.eegRateHz ?? decoder.eegRateHz);
        memsCounters.reset();
        return;
      }

      if (message is! _DecodeJob) return;
      final kind = PacketKind.values[message.kindIndex];

      void fail(String text, {PacketKind? overrideKind}) {
        out.send(
          DecodeFailed(
            DecodeError(
              kind: overrideKind ?? kind,
              message: text,
              receiveMonoUs: message.receiveMonoUs,
            ),
          ),
        );
      }

      try {
        if (!keysEqual(decoder.sessionKey, message)) {
          decoder.configureKey(
            EpocXSessionKey(
              keyBytes: message.keyBytes,
              preXorByte: message.preXorByte,
              isV4: message.isV4,
              firmwareVersion: message.firmwareVersion,
              keyMode: message.keyMode,
            ),
          );
        }
        if (message.eegRateHz != null &&
            message.eegRateHz != decoder.eegRateHz) {
          decoder.eegRateHz = message.eegRateHz!;
          eegCounters.modulus = message.eegRateHz!;
        }
        decoder.eegResolutionBits = message.eegResolutionBits;
        if (message.headbandPositionIndex != null) {
          decoder.headbandPosition =
              HeadbandPosition.values[message.headbandPositionIndex!];
        }

        final wall = DateTime.fromMillisecondsSinceEpoch(message.wallMs);
        final bytes = message.bytes;

        void emitDecoded32ByteBlock(Uint8List cipher32) {
          final plain32 = decoder.decryptPacket(cipher32, isMems: false);
          final frame = decoder.decodeEegPlaintext(plain32);

          // Defect #1 fix: 32-byte packets with pktType == 0x20 carry a 20-byte
          // Motion frame in plain32[0..20] (with 12 zero-padding bytes).
          if (frame.isMotionType) {
            final mot = decoder.decodeMotionPlaintext(
              Uint8List.sublistView(plain32, 0, 20),
            );
            memsCounters.add(mot.counterMems);
            out.send(
              DecodeMotionOk(
                MotionSample(
                  values: mot.values,
                  counterMems: mot.counterMems,
                  receiveMonoUs: message.receiveMonoUs,
                  wallClock: wall,
                ),
              ),
            );
            return;
          }

          final warning = eegCounters.add(frame.counter);
          if (warning != null) {
            fail(warning, overrideKind: PacketKind.eeg);
          }
          out.send(
            DecodeEegOk(
              EegSample(
                values: frame.values,
                counter: frame.counter,
                markerHw: frame.markerHw,
                contactQualityGrades: frame.cqGrades,
                overallCq: frame.overallCq,
                batteryPercent: frame.batteryPercent,
                receiveMonoUs: message.receiveMonoUs,
                wallClock: wall,
              ),
            ),
          );
        }

        void emitDecoded20ByteBleMotion(Uint8List wire20) {
          final plain20 = decoder.decryptPacket(wire20, isMems: true);
          final mot = decoder.decodeMotionPlaintext(plain20);
          memsCounters.add(mot.counterMems);
          out.send(
            DecodeMotionOk(
              MotionSample(
                values: mot.values,
                counterMems: mot.counterMems,
                receiveMonoUs: message.receiveMonoUs,
                wallClock: wall,
              ),
            ),
          );
        }

        switch (kind) {
          case PacketKind.eeg:
            final strictBle81072f41 = message.characteristicUuid != null &&
                EmotivBleUuids.isDataStream(message.characteristicUuid!) &&
                message.firmwareVersion >
                    HeadsetConfig.legacyBleSplitMaxFirmware;

            if (strictBle81072f41) {
              // Exact CortexService onEegDataReceived (0x1408f6420):
              // 64B -> 2x32B EEG; 84B (0x54) -> 2x32B EEG + 20B MEMS; else discard.
              final split = CryptoCodec.splitBle81072f41Notification(
                bytes,
                firmwareVersion: message.firmwareVersion,
              );
              if (split.isEmpty) {
                return;
              }
              for (final blk in split.eegCipherBlocks) {
                emitDecoded32ByteBlock(blk);
              }
              if (split.motionWirePacket != null) {
                emitDecoded20ByteBleMotion(split.motionWirePacket!);
              }
              return;
            }

            // Direct / replay / legacy fw <= 0x0710 path:
            // Support 84B combined super-frames, or 1..N x 32B blocks.
            if (bytes.length == EmotivBleUuids.bleSuperFrameBytes) {
              final split = CryptoCodec.splitBle81072f41Notification(
                bytes,
                firmwareVersion: HeadsetConfig.defaultFirmwareVersion,
              );
              for (final blk in split.eegCipherBlocks) {
                emitDecoded32ByteBlock(blk);
              }
              if (split.motionWirePacket != null) {
                emitDecoded20ByteBleMotion(split.motionWirePacket!);
              }
              return;
            }

            if (bytes.length < CryptoCodec.eegPacketBytes) {
              throw ArgumentError(
                'EEG packet must be at least 32 bytes, got ${bytes.length}',
              );
            }
            final count = bytes.length ~/ CryptoCodec.eegPacketBytes;
            for (var i = 0; i < count; i++) {
              emitDecoded32ByteBlock(
                Uint8List.sublistView(
                  bytes,
                  i * CryptoCodec.eegPacketBytes,
                  (i + 1) * CryptoCodec.eegPacketBytes,
                ),
              );
            }

          case PacketKind.motion:
            if (bytes.length < CryptoCodec.motionPacketBytes) {
              throw ArgumentError(
                'Motion packet must be at least 20 bytes, got ${bytes.length}',
              );
            }
            for (var offset = 0;
                offset + CryptoCodec.motionPacketBytes <= bytes.length;
                offset += CryptoCodec.motionPacketBytes) {
              emitDecoded20ByteBleMotion(
                Uint8List.sublistView(
                  bytes,
                  offset,
                  offset + CryptoCodec.motionPacketBytes,
                ),
              );
            }
        }
      } catch (e) {
        fail(e.toString());
      }
    });
  }
}

class _Bootstrap {
  _Bootstrap(this.handshake, this.results);
  final SendPort handshake;
  final SendPort results;
}

class _ConfigureSessionJob {
  const _ConfigureSessionJob({
    required this.keyBytes,
    required this.preXorByte,
    required this.isV4,
    required this.firmwareVersion,
    required this.keyMode,
    required this.eegRateHz,
    required this.eegResolutionBits,
    required this.headbandPositionIndex,
  });

  final Uint8List keyBytes;
  final int preXorByte;
  final bool isV4;
  final int firmwareVersion;
  final int keyMode;
  final int eegRateHz;
  final int eegResolutionBits;
  final int headbandPositionIndex;
}

class _UpdateOrientationJob {
  const _UpdateOrientationJob(this.index);
  final int index;
}

class _ResetJob {
  const _ResetJob({this.eegRateHz});
  final int? eegRateHz;
}

class _DecodeJob {
  _DecodeJob({
    required this.kindIndex,
    required this.bytes,
    required this.characteristicUuid,
    required this.keyBytes,
    required this.preXorByte,
    required this.isV4,
    required this.firmwareVersion,
    required this.keyMode,
    required this.eegRateHz,
    required this.eegResolutionBits,
    required this.headbandPositionIndex,
    required this.receiveMonoUs,
    required this.wallMs,
  });

  final int kindIndex;
  final Uint8List bytes;
  final String? characteristicUuid;
  final Uint8List keyBytes;
  final int preXorByte;
  final bool isV4;
  final int firmwareVersion;
  final int keyMode;
  final int? eegRateHz;
  final int eegResolutionBits;
  final int? headbandPositionIndex;
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

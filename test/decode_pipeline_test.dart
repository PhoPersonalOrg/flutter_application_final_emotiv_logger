import 'dart:typed_data';

import 'package:flutter_emotiv_logger/decode/crypto_codec.dart';
import 'package:flutter_emotiv_logger/decode/decode_pipeline.dart';
import 'package:flutter_emotiv_logger/domain/ble_uuids.dart';
import 'package:flutter_emotiv_logger/domain/samples.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _eegPlain({
  required int counter,
  int word7 = 0,
  int type = CryptoCodec.packetTypeEeg,
  int markerHw = 0,
}) {
  final plain = Uint8List(32);
  plain[0] = counter & 0xFF;
  plain[1] = (type & 0x7F) | ((markerHw & 0x01) << 7);
  plain[16] = word7 & 0xFF;
  plain[17] = (word7 >> 8) & 0xFF;
  return plain;
}

Uint8List _motionPlainOneG({int counter = 7}) {
  final bytes = Uint8List(20);
  bytes[0] = counter & 0xFF;
  bytes[1] = CryptoCodec.packetTypeMotion;
  // raw[4] (ay_r at bytes 10..11 BE) = 8191 -> "top" AccX = +1.0 g, "back" AccY = +1.0 g
  bytes[10] = 0x1F;
  bytes[11] = 0xFF;
  return bytes;
}

void main() {
  final v2Key = CryptoCodec.deriveEpocXKey(
    'E50202E92B',
    firmwareVersion: 0x0720,
    transport: EpocXTransport.ble,
  );
  final v4Key = CryptoCodec.deriveEpocXKey(
    'E50202E92B',
    firmwareVersion: 0x0752,
    transport: EpocXTransport.ble,
  );

  test('splits and decodes live 84-byte 81072f41 BLE super-frame into 2 EEG + 1 Motion', () async {
    final pipeline = DecodePipeline();
    await pipeline.start();
    addTearDown(pipeline.dispose);

    pipeline.configureSession(
      sessionKey: v2Key,
      eegRateHz: 128,
      eegResolutionBits: 16,
      headbandPosition: HeadbandPosition.top,
    );

    final bleNotif84 = CryptoCodec.hexToBytes(
      'af9cd8172ca53cecd8f1627b69f213e9653f8408f7a426d7c54aefb5b8f89dc9'
      '29d229dc9fa9c17c59cf980caf2a98a7073ae429942960763587d913b23453bf'
      '1f20d4792147eaf80110e244f084ffffffffffff',
    );

    final resultsFuture = pipeline.results.take(3).toList();
    pipeline.submit(
      RawPacket(
        kind: PacketKind.eeg,
        bytes: bleNotif84,
        receiveMonoUs: 1000,
        wallClock: DateTime.fromMillisecondsSinceEpoch(1000),
        characteristicUuid: EmotivBleUuids.dataStream,
      ),
      sessionKey: v2Key,
      eegRateHz: 128,
      eegResolutionBits: 16,
    );

    final results = await resultsFuture.timeout(const Duration(seconds: 5));
    expect(results[0], isA<DecodeEegOk>());
    expect(results[1], isA<DecodeEegOk>());
    expect(results[2], isA<DecodeMotionOk>());

    final eeg126 = (results[0] as DecodeEegOk).sample;
    final eeg127 = (results[1] as DecodeEegOk).sample;
    final mot31 = (results[2] as DecodeMotionOk).sample;

    expect(eeg126.counter, 126);
    expect(eeg126.batteryPercent, isNull);
    expect(eeg127.counter, 127);
    expect(eeg127.batteryPercent, 66);
    expect(eeg127.values[0], closeTo(4098.076923076923, 1e-9));

    expect(mot31.counterMems, 31);
    expect(mot31.values[0], closeTo(0.39887392227603463, 1e-12));
    expect(mot31.values[4], closeTo(-0.9293126602368453, 1e-12));
  });

  test('decodes V4 (fw=0x0752) 84-byte BLE super-frame with encrypted 20B Motion tail', () async {
    final pipeline = DecodePipeline();
    await pipeline.start();
    addTearDown(pipeline.dispose);

    pipeline.configureSession(
      sessionKey: v4Key,
      eegRateHz: 256,
      eegResolutionBits: 16,
      headbandPosition: HeadbandPosition.back,
    );

    final c0 = CryptoCodec.encryptPacketForTest(
      _eegPlain(counter: 0, word7: 1600, markerHw: 1),
      v4Key,
      isMems: false,
    );
    final c1 = CryptoCodec.encryptPacketForTest(
      _eegPlain(counter: 255, word7: 91),
      v4Key,
      isMems: false,
    );
    final mWire = CryptoCodec.encryptPacketForTest(
      _motionPlainOneG(counter: 19),
      v4Key,
      isMems: true,
    );

    final notif84 = Uint8List.fromList([...c0, ...c1, ...mWire]);
    final resultsFuture = pipeline.results.take(3).toList();
    pipeline.submit(
      RawPacket(
        kind: PacketKind.eeg,
        bytes: notif84,
        receiveMonoUs: 2000,
        wallClock: DateTime.fromMillisecondsSinceEpoch(2000),
        characteristicUuid: EmotivBleUuids.dataStream,
      ),
      sessionKey: v4Key,
      eegRateHz: 256,
      eegResolutionBits: 16,
      headbandPosition: HeadbandPosition.back,
    );

    final results = await resultsFuture.timeout(const Duration(seconds: 5));
    final s0 = (results[0] as DecodeEegOk).sample;
    final s1 = (results[1] as DecodeEegOk).sample;
    final sm = (results[2] as DecodeMotionOk).sample;

    expect(s0.counter, 0);
    expect(s0.markerHw, 1);
    expect(s0.contactQualityGrades[EegSample.channelNames.indexOf('F3')], 4);
    expect(s1.counter, 255);
    expect(s1.batteryPercent, 91);

    // HeadbandPosition.back keeps raw[4] on AccY (+1.0 g) rather than swapping to AccX!
    expect(sm.counterMems, 19);
    expect(sm.values[MotionSample.channelNames.indexOf('AccX')], 0.0);
    expect(
      sm.values[MotionSample.channelNames.indexOf('AccY')],
      closeTo(1.0, 1e-9),
    );
  });

  test('routes 32-byte 0x20 Motion packets to DecodeMotionOk (Defect #1 fix)', () async {
    final pipeline = DecodePipeline();
    await pipeline.start();
    addTearDown(pipeline.dispose);

    final plain32Mot = Uint8List(32);
    final mot20 = _motionPlainOneG(counter: 44);
    plain32Mot.setRange(0, 20, mot20);
    final wire32Mot = CryptoCodec.encryptPacketForTest(
      plain32Mot,
      v2Key,
      isMems: false,
    );

    final future = pipeline.results.first;
    pipeline.submit(
      RawPacket(
        kind: PacketKind.eeg,
        bytes: wire32Mot,
        receiveMonoUs: 500,
        wallClock: DateTime.fromMillisecondsSinceEpoch(500),
      ),
      sessionKey: v2Key,
    );

    final res = await future.timeout(const Duration(seconds: 5));
    expect(res, isA<DecodeMotionOk>());
    final mot = (res as DecodeMotionOk).sample;
    expect(mot.counterMems, 44);
    expect(
      mot.values[MotionSample.channelNames.indexOf('AccX')],
      closeTo(1.0, 1e-9),
    );
  });

  test('holds per-electrode CQ across ungated packets and clears on resetSession', () async {
    final pipeline = DecodePipeline();
    await pipeline.start();
    addTearDown(pipeline.dispose);

    // Counter 0 updates F3 -> grade 4; Counter 20 (slot >= 14) must hold F3 = 4!
    final wireSlot0 = CryptoCodec.encryptPacketForTest(
      _eegPlain(counter: 0, word7: 1600),
      v2Key,
    );
    final wireUngated = CryptoCodec.encryptPacketForTest(
      _eegPlain(counter: 20, word7: 65535),
      v2Key,
    );

    final firstTwo = pipeline.results.take(2).toList();
    pipeline.submit(
      RawPacket(
        kind: PacketKind.eeg,
        bytes: wireSlot0,
        receiveMonoUs: 1,
        wallClock: DateTime.fromMillisecondsSinceEpoch(10),
      ),
      sessionKey: v2Key,
      eegRateHz: 128,
    );
    pipeline.submit(
      RawPacket(
        kind: PacketKind.eeg,
        bytes: wireUngated,
        receiveMonoUs: 2,
        wallClock: DateTime.fromMillisecondsSinceEpoch(18),
      ),
      sessionKey: v2Key,
      eegRateHz: 128,
    );

    final res = await firstTwo.timeout(const Duration(seconds: 5));
    final f3Idx = EegSample.channelNames.indexOf('F3');
    expect((res[0] as DecodeEegOk).sample.contactQualityGrades[f3Idx], 4);
    expect((res[1] as DecodeEegOk).sample.contactQualityGrades[f3Idx], 4);

    pipeline.resetSession(eegRateHz: 128);
    final afterResetFuture = pipeline.results.first;
    pipeline.submit(
      RawPacket(
        kind: PacketKind.eeg,
        bytes: wireUngated,
        receiveMonoUs: 3,
        wallClock: DateTime.fromMillisecondsSinceEpoch(26),
      ),
      sessionKey: v2Key,
      eegRateHz: 128,
    );
    final afterReset =
        (await afterResetFuture.timeout(const Duration(seconds: 5)))
            as DecodeEegOk;
    expect(afterReset.sample.contactQualityGrades, everyElement(0));
  });

  test('short motion packet reports DecodeFailed without crashing isolate', () async {
    final pipeline = DecodePipeline();
    await pipeline.start();
    addTearDown(pipeline.dispose);

    final future = pipeline.results.first;
    pipeline.submit(
      RawPacket(
        kind: PacketKind.motion,
        bytes: Uint8List(14),
        receiveMonoUs: 1,
        wallClock: DateTime.now(),
      ),
      sessionKey: v2Key,
    );

    final result = await future.timeout(const Duration(seconds: 5));
    expect(result, isA<DecodeFailed>());
  });
}

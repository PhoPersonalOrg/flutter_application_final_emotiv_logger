import 'dart:typed_data';

import 'package:encrypt/encrypt.dart';
import 'package:flutter_emotiv_logger/decode/crypto_codec.dart';
import 'package:flutter_emotiv_logger/decode/decode_pipeline.dart';
import 'package:flutter_emotiv_logger/domain/samples.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final key = CryptoCodec.deriveEpocXKeyFromSerial(
    CryptoCodec.createSerialNumber('E50202E9'),
  );

  /// 20-byte motion package whose raw accelerometer field 4 (bytes 10-11,
  /// big-endian) is 8191, i.e. AccX = 1 g.
  Uint8List oneGPackage() {
    final bytes = Uint8List(20);
    bytes[10] = 0x1F;
    bytes[11] = 0xFF;
    return bytes;
  }

  test('DecodePipeline decodes motion on isolate', () async {
    final pipeline = DecodePipeline();
    await pipeline.start();

    final future = pipeline.results.first;
    pipeline.submit(
      RawPacket(
        kind: PacketKind.motion,
        bytes: oneGPackage(),
        receiveMonoUs: 1,
        wallClock: DateTime.now(),
      ),
      keyBytes: key,
    );

    final result = await future.timeout(const Duration(seconds: 5));
    expect(result, isA<DecodeMotionOk>());
    final sample = (result as DecodeMotionOk).sample;
    expect(sample.values.length, MotionSample.channelCount);
    expect(sample.values[MotionSample.channelNames.indexOf('AccX')],
        closeTo(1.0, 1e-9));
    expect(sample.values[MotionSample.channelNames.indexOf('Q0')],
        closeTo(1.0, 1e-9));

    await pipeline.dispose();
  });

  test('a notification with two motion packages yields two samples', () async {
    final pipeline = DecodePipeline();
    await pipeline.start();

    final future = pipeline.results.take(2).toList();
    pipeline.submit(
      RawPacket(
        kind: PacketKind.motion,
        bytes: Uint8List.fromList([...oneGPackage(), ...Uint8List(20)]),
        receiveMonoUs: 1,
        wallClock: DateTime.now(),
      ),
      keyBytes: key,
    );

    final results = await future.timeout(const Duration(seconds: 5));
    expect(results, everyElement(isA<DecodeMotionOk>()));
    final accX = MotionSample.channelNames.indexOf('AccX');
    expect((results[0] as DecodeMotionOk).sample.values[accX],
        closeTo(1.0, 1e-9));
    expect((results[1] as DecodeMotionOk).sample.values[accX], 0.0);

    await pipeline.dispose();
  });

  test('a short motion packet is reported as a decode failure', () async {
    final pipeline = DecodePipeline();
    await pipeline.start();

    final future = pipeline.results.first;
    pipeline.submit(
      RawPacket(
        kind: PacketKind.motion,
        bytes: Uint8List(14),
        receiveMonoUs: 1,
        wallClock: DateTime.now(),
      ),
      keyBytes: key,
    );

    final result = await future.timeout(const Duration(seconds: 5));
    expect(result, isA<DecodeFailed>());

    await pipeline.dispose();
  });

  test('DecodePipeline plumbs Mode-7 contactQuality onto EegSample', () async {
    final pipeline = DecodePipeline();
    await pipeline.start();

    final plain = Uint8List(32);
    plain[0] = 5;
    plain[1] = CryptoCodec.packetTypeEeg;
    // word 7 at bytes 16..17 = 0x126B -> low 7 bits = 0x6B (107)
    plain[16] = 0x6B;
    plain[17] = 0x12;

    final encrypter = Encrypter(AES(Key(key), mode: AESMode.ecb, padding: null));
    final wire = BytesBuilder();
    for (var c = 0; c < 32; c += 16) {
      final block = encrypter.encryptBytes(plain.sublist(c, c + 16)).bytes;
      wire.add([for (final b in block) b ^ 0x55]);
    }

    final future = pipeline.results.first;
    pipeline.submit(
      RawPacket(
        kind: PacketKind.eeg,
        bytes: wire.toBytes(),
        receiveMonoUs: 123,
        wallClock: DateTime.fromMillisecondsSinceEpoch(1000),
      ),
      keyBytes: key,
    );

    final result = await future.timeout(const Duration(seconds: 5));
    expect(result, isA<DecodeEegOk>());
    final sample = (result as DecodeEegOk).sample;
    expect(sample.contactQuality, 0x6B);
    expect(sample.qualityBroadcastValues(), List<double>.filled(14, 107.0));

    await pipeline.dispose();
  });
}

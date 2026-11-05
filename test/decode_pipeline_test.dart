import 'dart:typed_data';

import 'package:flutter_emotiv_logger/decode/crypto_codec.dart';
import 'package:flutter_emotiv_logger/decode/decode_pipeline.dart';
import 'package:flutter_emotiv_logger/domain/samples.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('DecodePipeline decodes motion on isolate', () async {
    final pipeline = DecodePipeline();
    await pipeline.start();

    final bytes = Uint8List(14);
    bytes[2] = 0x00;
    bytes[3] = 0x40; // AccX = 1g
    final key = CryptoCodec.deriveEpocXKeyFromSerial(
      CryptoCodec.createSerialNumber('E50202E9'),
    );

    final future = pipeline.results.first;
    pipeline.submit(
      RawPacket(
        kind: PacketKind.motion,
        bytes: bytes,
        receiveMonoUs: 1,
        wallClock: DateTime.now(),
      ),
      keyBytes: key,
    );

    final result = await future.timeout(const Duration(seconds: 5));
    expect(result, isA<DecodeMotionOk>());
    final sample = (result as DecodeMotionOk).sample;
    expect(sample.values[0], closeTo(1.0, 1e-6));

    await pipeline.dispose();
  });
}

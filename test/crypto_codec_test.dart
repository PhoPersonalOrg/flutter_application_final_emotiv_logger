import 'dart:typed_data';

import 'package:encrypt/encrypt.dart';
import 'package:flutter_emotiv_logger/decode/crypto_codec.dart';
import 'package:flutter_emotiv_logger/decode/device_identity.dart';
import 'package:flutter_emotiv_logger/decode/eeg_counter_monitor.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds a plaintext EEG package: counter, type, then word k = [words][k]
/// as little-endian uint16 at bytes 2+2k.
Uint8List _plainEegPackage({
  required int counter,
  required List<int> words,
  int type = CryptoCodec.packetTypeEeg,
}) {
  final out = Uint8List(32);
  out[0] = counter;
  out[1] = type;
  for (var k = 0; k < 15; k++) {
    out[2 + 2 * k] = words[k] & 0xff;
    out[3 + 2 * k] = (words[k] >> 8) & 0xff;
  }
  return out;
}

/// What the headset sends: AES-128-ECB encrypt, then XOR 0x55.
Uint8List _encryptLikeHeadset(Uint8List key, Uint8List plain) {
  final encrypter = Encrypter(AES(Key(key), mode: AESMode.ecb, padding: null));
  final out = BytesBuilder();
  for (var c = 0; c < plain.length; c += 16) {
    final block = encrypter.encryptBytes(plain.sublist(c, c + 16)).bytes;
    out.add([for (final b in block) b ^ 0x55]);
  }
  return out.toBytes();
}

/// Motion package with nine big-endian int16 values at bytes 2..19.
Uint8List _motionPackage(List<int> raw, {int counter = 0}) {
  final out = Uint8List(20);
  out[0] = counter;
  for (var i = 0; i < 9; i++) {
    final v = raw[i] & 0xffff;
    out[2 + 2 * i] = v >> 8;
    out[3 + 2 * i] = v & 0xff;
  }
  return out;
}

void main() {
  final key = CryptoCodec.deriveEpocXKeyFromSerial(
    CryptoCodec.createSerialNumber('A1B2C3D4'),
  );

  group('CryptoCodec key', () {
    test('createSerialNumber reverses BLE hex nibbles', () {
      final sn = CryptoCodec.createSerialNumber('E50202E9');
      expect(sn.length, 16);
      expect(sn.sublist(0, 12), everyElement(0));
      // reversed pairs: E9 02 02 E5
      expect(sn[12], 0xE9);
      expect(sn[13], 0x02);
      expect(sn[14], 0x02);
      expect(sn[15], 0xE5);
    });

    test('key equals the Android EpocX-mode permutation of the serial', () {
      // aesKeyVersion2_EpocXMode: key[i] = serial[perm[i]].
      const perm = [0, 1, 3, 3, 1, 0, 1, 3, 0, 3, 2, 1, 0, 1, 1, 2];
      const serial = [0xA1, 0xB2, 0xC3, 0xD4];
      expect(key, [for (final p in perm) serial[p]]);
    });
  });

  group('CryptoCodec EEG', () {
    // Word k carries the value 1000 * (k + 1), so each channel reveals which
    // word it was read from.
    final words = [for (var k = 0; k < 15; k++) 1000 * (k + 1)];
    final packet = _encryptLikeHeadset(
      key,
      _plainEegPackage(counter: 42, words: words),
    );

    test('channels come from the Android getRawEegId word order', () {
      final frame = CryptoCodec.decryptEegFrames(key, packet).single;
      expect(frame.counter, 42);
      expect(frame.packetType, CryptoCodec.packetTypeEeg);
      expect(frame.isMotionType, isFalse);

      // AF3 F7 F3 FC5 T7 P7 O1 O2 P8 T8 FC6 F4 F8 AF4
      const wordForChannel = [2, 3, 0, 1, 4, 5, 6, 8, 9, 10, 13, 14, 11, 12];
      expect(frame.values.length, 14);
      for (var ch = 0; ch < 14; ch++) {
        expect(
          frame.values[ch],
          closeTo(words[wordForChannel[ch]] / 7.8, 1e-9),
          reason: 'channel $ch',
        );
      }
    });

    test('word 7 (bytes 16-17) is not an EEG channel', () {
      final frame = CryptoCodec.decryptEegFrames(key, packet).single;
      expect(frame.values, isNot(contains(closeTo(words[7] / 7.8, 1e-9))));
    });

    test('14-bit resolution scales by 1.95, 16-bit by 7.8', () {
      final v16 = CryptoCodec.decryptEeg(key, packet);
      final v14 = CryptoCodec.decryptEeg(key, packet, resolutionBits: 14);
      expect(v16[2], closeTo(1000 / 7.8, 1e-9)); // F3 = word 0
      expect(v14[2], closeTo(1000 / 1.95, 1e-9));
      expect(
        () => CryptoCodec.decryptEeg(key, packet, resolutionBits: 12),
        throwsArgumentError,
      );
    });

    test('a notification with two packages yields two frames', () {
      final second = _encryptLikeHeadset(
        key,
        _plainEegPackage(counter: 43, words: List.filled(15, 7800)),
      );
      final frames = CryptoCodec.decryptEegFrames(
        key,
        Uint8List.fromList([...packet, ...second]),
      );
      expect(frames.map((f) => f.counter), [42, 43]);
      expect(frames[1].values, everyElement(closeTo(1000.0, 1e-9)));
    });

    test('motion-type packages are flagged', () {
      final motionType = _encryptLikeHeadset(
        key,
        _plainEegPackage(
          counter: 1,
          words: List.filled(15, 0),
          type: CryptoCodec.packetTypeMotion,
        ),
      );
      expect(
        CryptoCodec.decryptEegFrames(key, motionType).single.isMotionType,
        isTrue,
      );
    });

    test('decryptEeg rejects short packets', () {
      expect(
        () => CryptoCodec.decryptEeg(Uint8List(16), Uint8List(16)),
        throwsArgumentError,
      );
    });
  });

  group('CryptoCodec motion', () {
    test('reads big-endian int16 and applies the Android axis mapping', () {
      // raw index: 0..2 quaternion, 3..5 accelerometer, 6..8 magnetometer.
      final motion = CryptoCodec.decodeMotion(
        _motionPackage([4096, 8192, -4096, 8191, -16382, 4095, 60, -120, 6]),
      );
      expect(motion.length, 10);

      // Q1 = raw1, Q2 = -raw0, Q3 = raw2, all / 16384.
      expect(motion[1], closeTo(0.5, 1e-12));
      expect(motion[2], closeTo(-0.25, 1e-12));
      expect(motion[3], closeTo(-0.25, 1e-12));
      // Q0 = sqrt(1 - (Q1^2 + Q2^2 + Q3^2)).
      expect(motion[0], closeTo(0.7905694150420949, 1e-12));

      // AccX = raw4, AccY = -raw3, AccZ = raw5, all / 8191.
      expect(motion[4], closeTo(-2.0, 1e-12));
      expect(motion[5], closeTo(-1.0, 1e-12));
      expect(motion[6], closeTo(4095 / 8191, 1e-12));

      // MagX = -raw7, MagY = raw6, MagZ = raw8, all / 6.
      expect(motion[7], closeTo(20.0, 1e-12));
      expect(motion[8], closeTo(10.0, 1e-12));
      expect(motion[9], closeTo(1.0, 1e-12));
    });

    test('Q0 clamps to zero when the vector part exceeds unit length', () {
      final motion = CryptoCodec.decodeMotion(
        _motionPackage([16384, 16384, 0, 0, 0, 0, 0, 0, 0]),
      );
      expect(motion[0], 0.0);
    });

    test('rejects packages shorter than 20 bytes', () {
      expect(
        () => CryptoCodec.decodeMotion(Uint8List(14)),
        throwsArgumentError,
      );
    });
  });

  group('EegCounterMonitor', () {
    test('sequential counters with 128 and 256 wrap never warn', () {
      for (final rate in [128, 256]) {
        final monitor = EegCounterMonitor();
        for (var i = 0; i < 2000; i++) {
          expect(monitor.add(i % rate), isNull, reason: 'rate $rate, i $i');
        }
      }
    });

    test('occasional packet loss does not warn', () {
      final monitor = EegCounterMonitor();
      for (var i = 0; i < 2000; i++) {
        if (i % 10 == 0) continue; // drop every tenth package
        expect(monitor.add(i % 128), isNull);
      }
    });

    test('non-sequential counters warn once per window', () {
      final monitor = EegCounterMonitor(window: 64);
      var warnings = 0;
      // 97 is coprime with 256, so consecutive values are never successors.
      for (var i = 0; i <= 128; i++) {
        if (monitor.add((i * 97) % 256) != null) warnings++;
      }
      expect(warnings, 2);
    });

    test('reset forgets the previous counter', () {
      final monitor = EegCounterMonitor(window: 4);
      for (final c in [10, 200, 30, 90]) {
        monitor.add(c);
      }
      monitor.reset();
      for (final c in [0, 1, 2, 3, 4]) {
        expect(monitor.add(c), isNull);
      }
    });
  });

  group('DeviceIdentityResolver', () {
    test('parses name hex key', () {
      final id = DeviceIdentityResolver().resolveFromName('EPOCX (E50202E9)');
      expect(id.btKeyHex, 'E50202E9');
      expect(id.keyBytes.length, 16);
      expect(id.keyFingerprint, contains('E50202E9'));
    });

    test('throws on missing key', () {
      expect(
        () => DeviceIdentityResolver().resolveFromName('EPOCX'),
        throwsStateError,
      );
    });
  });
}

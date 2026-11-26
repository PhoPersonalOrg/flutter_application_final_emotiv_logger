import 'dart:typed_data';

import 'package:flutter_emotiv_logger/decode/crypto_codec.dart';
import 'package:flutter_emotiv_logger/decode/device_identity.dart';
import 'package:flutter_emotiv_logger/decode/eeg_counter_monitor.dart';
import 'package:flutter_emotiv_logger/decode/headset_config.dart';
import 'package:flutter_emotiv_logger/domain/ble_uuids.dart';
import 'package:flutter_emotiv_logger/domain/samples.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds a 32-byte plaintext Mode-7 package (`counter`, `flags`, `15 x uint16 LE`).
Uint8List _plainEegPackage({
  required int counter,
  required List<int> words,
  int type = CryptoCodec.packetTypeEeg,
  int markerHw = 0,
}) {
  final out = Uint8List(32);
  out[0] = counter & 0xFF;
  out[1] = (type & 0x7F) | ((markerHw & 0x01) << 7);
  for (var k = 0; k < 15; k++) {
    out[2 + 2 * k] = words[k] & 0xFF;
    out[3 + 2 * k] = (words[k] >> 8) & 0xFF;
  }
  return out;
}

/// Builds a 20-byte plaintext Motion package (`counter`, `0x20`, `9 x int16 BE`).
Uint8List _plainMotionPackage(List<int> raw9, {int counter = 0}) {
  final out = Uint8List(20);
  out[0] = counter & 0xFF;
  out[1] = CryptoCodec.packetTypeMotion;
  for (var i = 0; i < 9; i++) {
    final v = raw9[i] & 0xFFFF;
    out[2 + 2 * i] = (v >> 8) & 0xFF;
    out[3 + 2 * i] = v & 0xFF;
  }
  return out;
}

void main() {
  group('[1/7] CortexService.exe .rdata V4 sealed blob bootstrap', () {
    test('unseals Vohcha7e, Ut3phaej, and preXor 0x14', () {
      final unsealed = CryptoCodec.unsealV4RdataConstants();
      expect(unsealed.salt1, 'Vohcha7e');
      expect(unsealed.salt2, 'Ut3phaej');
      expect(unsealed.xorByte, 0x14);
    });
  });

  group('[2/7 & 6/7] USB HID Feature/Output 0x00 & Live USB Hardware Vectors', () {
    test('encodes 33B Output Report 0x00 and decodes synthetic Feature Report 0x00', () {
      final feat = Uint8List(32);
      feat[0] = 0x00;
      feat[2] = 0xE8;
      feat.setRange(3, 5, CryptoCodec.hexToBytes('0210'));
      feat.setRange(5, 7, CryptoCodec.hexToBytes('0752'));
      feat.setRange(7, 11, CryptoCodec.hexToBytes('56A1B2C3'));
      feat[12] = 0x01;
      feat[13] = 0x00;
      feat[14] = 0x01; // 256 LE
      feat[15] = 16;
      feat[16] = 64;
      feat[17] = 16;

      final cfg = HeadsetConfig.parseUsbFeatureReport00(feat);
      expect(cfg.headsetType, 7);
      expect(cfg.headsetFirmware, 0x0752);
      expect(cfg.isV4, isTrue);
      expect(cfg.serialHex, '56A1B2C3');
      expect(cfg.eegRateHz, 256);
      expect(cfg.eegResolutionBits, 16);
      expect(cfg.memsRateHz, 64);
      expect(cfg.memsResolutionBits, 16);

      final outRep = HeadsetConfig.buildUsbModeReport(
        eegRateHz: 256,
        eegResolutionBits: 16,
        memsRateHz: 64,
        memsResolutionBits: 16,
      );
      expect(outRep.length, 33);
      expect(outRep.sublist(0, 6), [0x00, 0x66, 0xBB, 0x20, 0x12, 0xEA]);
      expect(
        HeadsetConfig.isUsbModeAck(Uint8List.fromList([0x00, 0x00, 0x88, 0x12])),
        isTrue,
      );
      expect(
        HeadsetConfig.isUsbModeAck(
          Uint8List.fromList([0x00, 0x00, 0x00, 0x88, 0x12]),
        ),
        isTrue,
      );
    });

    test('matches live EPOCX-E50202E9 + UD20240731007676 USB vectors bit-for-bit', () {
      final hwFeat = CryptoCodec.hexToBytes('00202006ff0720e50202e92b018000102010');
      final cfg = HeadsetConfig.parseUsbFeatureReport00(hwFeat);
      expect(cfg.dongleFirmware, 0x06FF);
      expect(cfg.headsetFirmware, 0x0720);
      expect(cfg.serialHex, 'E50202E9');
      expect(cfg.disSerialHex, 'E50202E92B');
      expect(cfg.eegRateHz, 128);
      expect(cfg.eegResolutionBits, 16);
      expect(cfg.memsRateHz, 32);
      expect(cfg.memsResolutionBits, 16);

      final usbKey = CryptoCodec.deriveEpocXKey(
        'UD20240731007676',
        firmwareVersion: 0x0720,
        keyMode: 7,
        transport: EpocXTransport.usb,
      );
      expect(
        HeadsetConfig.bytesToUpperHex(usbKey.keyBytes).toLowerCase(),
        '36373737373637373637363736373736',
      );
      expect(usbKey.preXorByte, 0x55);
      expect(usbKey.isV4, isFalse);

      // Live 32B USB EEG ciphertext -> exact plaintext & 14-channel uV floats
      final wireEeg = CryptoCodec.hexToBytes(
        '1723661a91450ed36b99e0f55a243ba5ec2f84bf5bd3dc3b161ca1395ae3679a',
      );
      final plainEeg = CryptoCodec.decryptPacket(wireEeg, usbKey, isMems: false);
      expect(
        HeadsetConfig.bytesToUpperHex(plainEeg).toLowerCase(),
        '6910bf7e56814c804c838881d283fa8300003c89f08a95932f81747df58554a7',
      );

      final dec = EpocXStatefulDecoder(
        eegRateHz: 128,
        eegResolutionBits: 16,
        headbandPosition: HeadbandPosition.top,
        sessionKey: usbKey,
      );
      final eegFrame = dec.decodeEegPlaintext(plainEeg);
      expect(eegFrame.counter, 105);
      expect(eegFrame.markerHw, 0);
      expect(eegFrame.batteryPercent, isNull);

      const expectedUsbEegUv = <String, double>{
        'AF3': 4210.7692307692305,
        'F7': 4309.2307692307695,
        'F3': 4159.871794871795,
        'FC5': 4244.871794871795,
        'T7': 4251.282051282052,
        'P7': 4326.410256410257,
        'O1': 4331.538461538462,
        'O2': 4504.102564102564,
        'P8': 4560.0,
        'T8': 4843.717948717949,
        'FC6': 4396.538461538462,
        'F4': 5491.794871794872,
        'F8': 4239.871794871795,
        'AF4': 4117.4358974358975,
      };
      for (var i = 0; i < EegSample.channelNames.length; i++) {
        final ch = EegSample.channelNames[i];
        expect(
          eegFrame.values[i],
          closeTo(expectedUsbEegUv[ch]!, 1e-12),
          reason: 'USB EEG $ch',
        );
      }

      // Live 32B encrypted USB Motion packet (pktType == 0x20, 12 zero-padding bytes)
      final wireMot32 = CryptoCodec.hexToBytes(
        '204b16fb12692075bd7911810c68531a8ee9f43612f7d5eb211c86fa823519d6',
      );
      final plainMot32 = CryptoCodec.decryptPacket(
        wireMot32,
        usbKey,
        isMems: false,
      );
      expect(
        HeadsetConfig.bytesToUpperHex(plainMot32).toLowerCase(),
        '1a20d2e2e0311887f900e3b0ef5cffffffffffff000000000000000000000000',
      );
      final maybeMotFrame = dec.decodeEegPlaintext(plainMot32);
      expect(maybeMotFrame.isMotionType, isTrue);

      final mot = dec.decodeMotionPlaintext(
        Uint8List.sublistView(plainMot32, 0, 20),
      );
      expect(mot.counterMems, 26);
      expect(mot.q0, closeTo(0.33037257181502816, 1e-15));
      expect(mot.q1, closeTo(-0.49700927734375, 1e-15));
      expect(mot.q2, closeTo(0.7049560546875, 1e-15));
      expect(mot.q3, closeTo(0.38323974609375, 1e-15));
      expect(mot.accX, closeTo(-0.8848736418019778, 1e-15));
      expect(mot.accY, closeTo(0.21877670614088635, 1e-15));
      expect(mot.accZ, closeTo(-0.5200830179465267, 1e-15));
      expect(mot.magX, closeTo(1.0 / 6.0, 1e-15));
      expect(mot.magY, closeTo(-1.0 / 6.0, 1e-15));
      expect(mot.magZ, closeTo(-1.0 / 6.0, 1e-15));
    });
  });

  group('[7/7] Live BLE GATT Hardware Vectors (EPOCX-E50202E9 over 81072f40)', () {
    test('decodes DIS 0x2A25 (5B binary), 0x2A26, 81072f44, V2 BLE key, and 84B super-frame', () {
      final dis2a25 = CryptoCodec.hexToBytes('e50202e92b');
      final dis2a26 = CryptoCodec.hexToBytes('0720');
      final cfg2f44 = CryptoCodec.hexToBytes('018000102010');

      final bleCfg = HeadsetConfig.parseBleMode81072f44(
        buf6: cfg2f44,
        serialBytes: dis2a25,
        fw2b: dis2a26,
      );
      expect(bleCfg.headsetFirmware, 0x0720);
      expect(bleCfg.serialHex, 'E50202E9');
      expect(bleCfg.disSerialHex, 'E50202E92B');
      expect(bleCfg.eegRateHz, 128);
      expect(bleCfg.eegResolutionBits, 16);
      expect(bleCfg.memsRateHz, 32);
      expect(bleCfg.memsResolutionBits, 16);

      final resolver = DeviceIdentityResolver();
      final identity = resolver.resolveBleIdentity(
        deviceName: 'EPOCX (E50202E9)',
        dis0x2A25Bytes: dis2a25,
        firmwareVersion: 0x0720,
        keyMode: 7,
      );
      expect(identity.btKeyHex, 'E50202E9');
      expect(identity.disSerialHex, 'E50202E92B');
      expect(identity.serialOrigin, 'dis_0x2a25');
      expect(
        HeadsetConfig.bytesToUpperHex(identity.keyBytes).toLowerCase(),
        'e502e9e902e502e9e5e90202e5020202',
      );
      expect(identity.sessionKey.preXorByte, 0x55);
      expect(identity.sessionKey.isV4, isFalse);

      // Fallback when 0x2A25 is restricted: advertised name yields identical Mode-7 key.
      final fallbackIdentity = resolver.resolveBleIdentity(
        deviceName: 'EPOCX (E50202E9)',
        firmwareVersion: 0x0720,
        keyMode: 7,
      );
      expect(fallbackIdentity.serialOrigin, 'adv_name');
      expect(fallbackIdentity.keyBytes, identity.keyBytes);

      // Real 84-byte 81072f41 super-frame (seq=64: cnt=126 & cnt=127 battery=66% + 20B MEMS cnt=31)
      final bleNotif84 = CryptoCodec.hexToBytes(
        'af9cd8172ca53cecd8f1627b69f213e9653f8408f7a426d7c54aefb5b8f89dc9'
        '29d229dc9fa9c17c59cf980caf2a98a7073ae429942960763587d913b23453bf'
        '1f20d4792147eaf80110e244f084ffffffffffff',
      );
      final split = CryptoCodec.splitBle81072f41Notification(
        bleNotif84,
        firmwareVersion: 0x0720,
      );
      expect(split.eegCipherBlocks.length, 2);
      expect(split.motionWirePacket, isNotNull);
      expect(split.motionWirePacket!.length, 20);

      final dec = EpocXStatefulDecoder(
        eegRateHz: 128,
        eegResolutionBits: 16,
        headbandPosition: HeadbandPosition.top,
        sessionKey: identity.sessionKey,
      );
      final pEeg126 = dec.decryptPacket(split.eegCipherBlocks[0], isMems: false);
      final pEeg127 = dec.decryptPacket(split.eegCipherBlocks[1], isMems: false);
      final pMems31 = dec.decryptPacket(split.motionWirePacket!, isMems: true);

      expect(
        HeadsetConfig.bytesToUpperHex(pEeg126).toLowerCase(),
        '7e10007d077fd67cdf80857f95819f8100004d844e82a38031822e826382d380',
      );
      expect(
        HeadsetConfig.bytesToUpperHex(pEeg127).toLowerCase(),
        '7f10057d147fdd7cd880687f9d81ad81420052844a829c8034824f824282a880',
      );
      expect(pMems31, split.motionWirePacket);

      final s126 = dec.decodeEegPlaintext(pEeg126);
      final s127 = dec.decodeEegPlaintext(pEeg127);
      expect(s126.counter, 126);
      expect(s126.batteryPercent, isNull);
      expect(s127.counter, 127);
      expect(s127.batteryPercent, 66);
      expect(dec.batteryPercent, 66);

      const expectedBle127Uv = <String, double>{
        'AF3': 4098.076923076923,
        'F7': 4228.717948717949,
        'F3': 4103.205128205128,
        'FC5': 4170.7692307692305,
        'T7': 4181.538461538462,
        'P7': 4253.974358974359,
        'O1': 4256.025641025642,
        'O2': 4342.820512820513,
        'P8': 4276.153846153847,
        'T8': 4221.025641025642,
        'FC6': 4275.128205128205,
        'F4': 4222.5641025641025,
        'F8': 4273.333333333333,
        'AF4': 4276.794871794872,
      };
      for (var i = 0; i < EegSample.channelNames.length; i++) {
        final ch = EegSample.channelNames[i];
        expect(
          s127.values[i],
          closeTo(expectedBle127Uv[ch]!, 1e-12),
          reason: 'BLE EEG cnt=127 $ch',
        );
      }

      final sm31 = dec.decodeMotionPlaintext(pMems31);
      expect(sm31.counterMems, 31);
      expect(sm31.q0, closeTo(0.39887392227603463, 1e-15));
      expect(sm31.q1, closeTo(0.51995849609375, 1e-15));
      expect(sm31.q2, closeTo(0.68011474609375, 1e-15));
      expect(sm31.q3, closeTo(-0.32861328125, 1e-15));
      expect(sm31.accX, closeTo(-0.9293126602368453, 1e-15));
      expect(sm31.accY, closeTo(-0.03320717861067025, 1e-15));
      expect(sm31.accZ, closeTo(-0.4839457941643267, 1e-15));
      expect(sm31.magX, closeTo(1.0 / 6.0, 1e-15));
      expect(sm31.magY, closeTo(-1.0 / 6.0, 1e-15));
      expect(sm31.magZ, closeTo(-1.0 / 6.0, 1e-15));
    });
  });

  group('[3/7] V2 (fw <= 0x073E) & V4 (fw >= 0x073F) Key Equivalence & Round-Trips', () {
    test('branches strictly at fw > 0x073E and truncates 5B BLE serial to 8 hex chars on V4', () {
      final k073e = CryptoCodec.deriveEpocXKey(
        'E50202E92B',
        firmwareVersion: 0x073E,
        transport: EpocXTransport.ble,
      );
      final k073f = CryptoCodec.deriveEpocXKey(
        'E50202E92B',
        firmwareVersion: 0x073F,
        transport: EpocXTransport.ble,
      );
      expect(k073e.isV4, isFalse);
      expect(k073e.keyBytes.length, 16);
      expect(k073e.preXorByte, 0x55);
      expect(k073f.isV4, isTrue);
      expect(k073f.keyBytes.length, 32);
      expect(k073f.preXorByte, 0x14);

      final v4Ble5B = CryptoCodec.deriveEpocXKey(
        'E50202E92B',
        firmwareVersion: 0x0752,
        transport: EpocXTransport.ble,
      );
      final v4Usb4B = CryptoCodec.deriveEpocXKey(
        'E50202E9',
        firmwareVersion: 0x0752,
        transport: EpocXTransport.usb,
      );
      expect(v4Ble5B.keyBytes, v4Usb4B.keyBytes);
    });

    test('round-trips 32B EEG and 20B Motion (16B AES-256 + 4B XOR 0x14) across V2 and V4', () {
      for (final fw in [0x073E, 0x0752]) {
        final sessionKey = CryptoCodec.deriveEpocXKey(
          CryptoCodec.hexToBytes('56A1B2C3'),
          firmwareVersion: fw,
          keyMode: 7,
          transport: EpocXTransport.ble,
        );
        final words = [
          for (var i = 0; i < 7; i++) 32768 + i * 100,
          87,
          for (var i = 0; i < 7; i++) 33000 + i * 50,
        ];
        final plainEeg = _plainEegPackage(
          counter: 255,
          words: words,
          markerHw: 1,
        );
        final wireEeg = CryptoCodec.encryptPacketForTest(
          plainEeg,
          sessionKey,
          isMems: false,
        );
        final decEeg = CryptoCodec.decryptPacket(
          wireEeg,
          sessionKey,
          isMems: false,
        );
        expect(decEeg, plainEeg, reason: 'EEG round-trip fw=0x${fw.toRadixString(16)}');

        final plainMot = _plainMotionPackage(
          [4096, -4096, 2048, 0, 0, 8191, 120, -60, 300],
          counter: 42,
        );
        final wireMot = CryptoCodec.encryptPacketForTest(
          plainMot,
          sessionKey,
          isMems: true,
        );
        if (fw == 0x0752) {
          // Verify V4 Motion actually encrypts head[0..16] and XORs tail[16..20] with 0x14!
          expect(wireMot.sublist(0, 16), isNot(plainMot.sublist(0, 16)));
          expect(
            wireMot.sublist(16, 20),
            [for (final b in plainMot.sublist(16, 20)) b ^ 0x14],
          );
        } else {
          expect(wireMot, plainMot);
        }
        final decMot = CryptoCodec.decryptPacket(
          wireMot,
          sessionKey,
          isMems: true,
        );
        expect(decMot, plainMot, reason: 'Motion round-trip fw=0x${fw.toRadixString(16)}');
      }
    });
  });

  group('[4/7 & 5/7] Per-Electrode CQ Demux, Battery Gate, Trigger Bit, & Orientation', () {
    test('demuxes per-electrode CQ by slot = counter % (Fs ~/ 2) without polluting Battery or siblings', () {
      final dec = EpocXStatefulDecoder(
        eegRateHz: 256,
        eegResolutionBits: 16,
        headbandPosition: HeadbandPosition.top,
      );

      // Counter 0 -> slot 0 -> "F3" (output index 2), divisor = 212.0.
      // word7 = 1600 -> metric = (1600 * 0.25) / 212.0 = 1.88679 >= 1.7 -> grade 4.
      final cqSlot0 = _plainEegPackage(
        counter: 0,
        words: [...List.filled(7, 32000), 1600, ...List.filled(7, 32000)],
      );
      final f0 = dec.decodeEegPlaintext(cqSlot0);
      expect(f0.batteryPercent, isNull);
      expect(f0.cqUpdatedChannel, 'F3');
      expect(f0.cqUpdatedGrade, 4);
      final f3Idx = EegSample.channelNames.indexOf('F3');
      expect(f0.cqGrades[f3Idx], 4);
      for (var i = 0; i < 14; i++) {
        if (i != f3Idx) {
          expect(f0.cqGrades[i], 0, reason: 'sibling channel $i must stay 0');
        }
      }

      // Counter 2 -> slot 2 -> "AF3" (output index 0), divisor = 226.0.
      // word7 = 904 -> metric = 226 / 226.0 = 1.0 -> grade 2 (Fair).
      final cqSlot2 = _plainEegPackage(
        counter: 2,
        words: [...List.filled(7, 32000), 904, ...List.filled(7, 32000)],
      );
      final f2 = dec.decodeEegPlaintext(cqSlot2);
      expect(f2.cqUpdatedChannel, 'AF3');
      expect(f2.cqUpdatedGrade, 2);
      expect(f2.cqGrades[0], 2);
      expect(f2.cqGrades[f3Idx], 4); // F3 held!

      // Counter 20 -> slot 20 (>= 14) -> ignored for CQ, holds prior grades.
      final ungated = _plainEegPackage(
        counter: 20,
        words: [...List.filled(7, 32000), 65535, ...List.filled(7, 32000)],
      );
      final f20 = dec.decodeEegPlaintext(ungated);
      expect(f20.cqUpdatedChannel, isNull);
      expect(f20.batteryPercent, isNull);
      expect(f20.cqGrades[0], 2);
      expect(f20.cqGrades[f3Idx], 4);

      // Counter 255 (== eegRateHz - 1 at 256 Hz) -> latches battery = 87% & markerHw = 1!
      final battPkt = _plainEegPackage(
        counter: 255,
        words: [...List.filled(7, 32768), 87, ...List.filled(7, 32768)],
        markerHw: 1,
      );
      final f255 = dec.decodeEegPlaintext(battPkt);
      expect(f255.batteryPercent, 87);
      expect(f255.markerHw, 1);
      expect(dec.batteryPercent, 87);
    });

    test('applies "top" swap/negation vs "back" identity IMU orientation', () {
      final rawPkt = _plainMotionPackage(
        [4096, 8192, -4096, 8191, -16382, 4095, 60, -120, 6],
        counter: 12,
      );

      final top = CryptoCodec.decodeMotionPlaintext(
        rawPkt,
        headbandPosition: HeadbandPosition.top,
      );
      expect(top.counterMems, 12);
      expect(top.q1, closeTo(0.5, 1e-12));
      expect(top.q2, closeTo(-0.25, 1e-12));
      expect(top.q3, closeTo(-0.25, 1e-12));
      expect(top.q0, closeTo(0.7905694150420949, 1e-12));
      expect(top.accX, closeTo(-2.0, 1e-12));
      expect(top.accY, closeTo(-1.0, 1e-12));
      expect(top.accZ, closeTo(4095.0 / 8191.0, 1e-12));
      expect(top.magX, closeTo(20.0, 1e-12));
      expect(top.magY, closeTo(10.0, 1e-12));
      expect(top.magZ, closeTo(1.0, 1e-12));

      final back = CryptoCodec.decodeMotionPlaintext(
        rawPkt,
        headbandPosition: HeadbandPosition.back,
      );
      expect(back.q1, closeTo(0.25, 1e-12));
      expect(back.q2, closeTo(0.5, 1e-12));
      expect(back.q3, closeTo(-0.25, 1e-12));
      expect(back.q0, closeTo(0.7905694150420949, 1e-12));
      expect(back.accX, closeTo(1.0, 1e-12));
      expect(back.accY, closeTo(-2.0, 1e-12));
      expect(back.accZ, closeTo(4095.0 / 8191.0, 1e-12));
      expect(back.magX, closeTo(10.0, 1e-12));
      expect(back.magY, closeTo(-20.0, 1e-12));
      expect(back.magZ, closeTo(1.0, 1e-12));
    });

    test('14-bit resolution scales by 1.95 and 16-bit by 7.8', () {
      final key = CryptoCodec.deriveEpocXKey(
        'A1B2C3D4',
        firmwareVersion: 0x0720,
        transport: EpocXTransport.ble,
      );
      final words = [for (var k = 0; k < 15; k++) 1000 * (k + 1)];
      final wire = CryptoCodec.encryptPacketForTest(
        _plainEegPackage(counter: 42, words: words),
        key,
      );
      final v16 = CryptoCodec.decryptEeg(key.keyBytes, wire);
      final v14 = CryptoCodec.decryptEeg(key.keyBytes, wire, resolutionBits: 14);
      expect(v16[2], closeTo(1000 / 7.8, 1e-9));
      expect(v14[2], closeTo(1000 / 1.95, 1e-9));
      expect(
        () => CryptoCodec.decryptEeg(key.keyBytes, wire, resolutionBits: 12),
        throwsArgumentError,
      );
    });
  });

  group('EegCounterMonitor, MemsCounterMonitor & BLE Scan Filter', () {
    test('enforces exact 128 vs 256 modulus on EEG counters', () {
      for (final rate in [128, 256]) {
        final monitor = EegCounterMonitor(modulus: rate);
        for (var i = 0; i < 2000; i++) {
          expect(monitor.add(i % rate), isNull);
        }
      }

      // If configured for 256 Hz, wrapping at 127 -> 0 is flagged over a window!
      final m256 = EegCounterMonitor(window: 64, minSequentialRatio: 0.99, modulus: 256);
      m256.add(127);
      // 127 -> 0 is NOT sequential at 256 Hz (expected 128)!
      var warned = false;
      for (var i = 0; i < 70; i++) {
        if (m256.add((i * 97) % 256) != null) warned = true;
      }
      expect(warned, isTrue);

      final mems = MemsCounterMonitor();
      expect(mems.add(126), 0);
      expect(mems.add(127), 0);
      expect(mems.add(0), 0); // mod 128 wrap!
      expect(mems.add(3), 2); // missed 1 and 2
      expect(mems.missedCount, 2);
    });

    test('DeviceIdentityResolver matches 81072f40 service and EPOCX name patterns', () {
      final resolver = DeviceIdentityResolver();
      expect(
        resolver.isEmotivScanCandidate(
          '',
          serviceUuids: const [EmotivBleUuids.epocXService],
        ),
        isTrue,
      );
      expect(resolver.isEmotivScanCandidate('EPOCX (E50202E9)'), isTrue);
      expect(resolver.isEmotivScanCandidate('EPOCX E50202E9'), isTrue);
      expect(resolver.isEmotivScanCandidate('EPOCX-E50202E9'), isTrue);
      expect(resolver.isEmotivScanCandidate('EPOC+ (E50202E9)'), isTrue);
      expect(resolver.isEmotivScanCandidate('Vertuo_DV6_78421CA8FC9A'), isFalse);
      expect(resolver.isEmotivScanCandidate('Pixel Buds'), isFalse);
      expect(
        resolver.isEmotivScanCandidate('Pixel Buds', isPreferred: true),
        isTrue,
      );
    });
  });
}

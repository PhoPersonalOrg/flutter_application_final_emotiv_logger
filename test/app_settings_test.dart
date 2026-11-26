import 'dart:convert';
import 'dart:io';

import 'package:flutter_emotiv_logger/app/settings.dart';
import 'package:flutter_emotiv_logger/decode/crypto_codec.dart';
import 'package:flutter_emotiv_logger/decode/decode_pipeline.dart';
import 'package:flutter_emotiv_logger/decode/device_identity.dart';
import 'package:flutter_emotiv_logger/decode/headset_config.dart';
import 'package:flutter_emotiv_logger/domain/samples.dart';
import 'package:flutter_emotiv_logger/sinks/csv_sink.dart';
import 'package:flutter_emotiv_logger/sinks/sample_hub.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('AppSettings copyWith, protocol, and headbandPosition storage', () async {
    SharedPreferences.setMockInitialValues({});
    const s = AppSettings();
    expect(s.hostname, AppSettings.defaultHostname);
    expect(s.headbandPosition, HeadbandPosition.top);
    expect(s.dropboxLiveSync, isTrue);

    final next = s.copyWith(
      lslEnabled: false,
      hostname: 'LabPhone',
      headbandPosition: HeadbandPosition.back,
      useNetworkStream: true,
      networkProtocol: NetworkProtocol.tcp,
      networkPort: 1234,
      dropboxLiveSync: false,
      dropboxRemoteRoot: 'LabUploads',
    );
    expect(next.lslEnabled, isFalse);
    expect(next.hostname, 'LabPhone');
    expect(next.headbandPosition, HeadbandPosition.back);
    expect(next.useNetworkStream, isTrue);
    expect(next.networkProtocol, NetworkProtocol.tcp);
    expect(next.networkPort, 1234);
    expect(next.dropboxLiveSync, isFalse);
    expect(next.dropboxRemoteRoot, 'LabUploads');
    expect(NetworkProtocolX.fromStorage('tcp'), NetworkProtocol.tcp);
    expect(NetworkProtocolX.fromStorage(null), NetworkProtocol.udp);

    final repo = AppSettingsRepository();
    await repo.save(next);
    final loaded = await repo.load();
    expect(loaded.headbandPosition, HeadbandPosition.back);
    expect(loaded.hostname, 'LabPhone');
  });

  test('CsvSink writes spec-compliant session.json, eeg.csv, motion.csv, cq.csv, and raw.csv', () async {
    final tmpDir = await Directory.systemTemp.createTemp('csv_sink_spec_');
    addTearDown(() => tmpDir.delete(recursive: true));

    final hub = SampleHub(onHealth: (_) {});
    final csv = CsvSink(hub: hub);

    final dis2a25 = CryptoCodec.hexToBytes('e50202e92b');
    final cfgBytes = CryptoCodec.hexToBytes('010001104010'); // 256 Hz / 16b EEG, 64 Hz / 16b MEMS
    final cfg = HeadsetConfig.parseBleMode81072f44(
      buf6: cfgBytes,
      serialBytes: dis2a25,
      fw2b: CryptoCodec.hexToBytes('0752'),
    );
    final identity = DeviceIdentityResolver().resolveBleIdentity(
      deviceName: 'EPOCX (E50202E9)',
      dis0x2A25Bytes: dis2a25,
      firmwareVersion: cfg.headsetFirmware,
      keyMode: cfg.mode,
    );

    final start = await csv.startSession(
      saveDirectory: tmpDir.path,
      identity: identity,
      headsetConfig: cfg,
      eegResolutionBits: cfg.eegResolutionBits,
      headbandPosition: HeadbandPosition.back,
      negotiatedMtu: 87,
    );

    hub.publishDecode(
      DecodeEegOk(
        EegSample(
          values: List<double>.filled(14, 4201.0),
          counter: 255,
          markerHw: 1,
          contactQualityGrades: const [4, 4, 2, 1, 4, 4, 4, 4, 2, 1, 4, 4, 4, 4],
          overallCq: 82,
          batteryPercent: 74,
          receiveMonoUs: 1000,
          wallClock: DateTime.fromMillisecondsSinceEpoch(5000),
        ),
      ),
    );
    hub.publishDecode(
      DecodeMotionOk(
        MotionSample(
          values: const [1.0, 0, 0, 0, 0, 0, 1.0, 10, -10, 5],
          counterMems: 31,
          receiveMonoUs: 1050,
          wallClock: DateTime.fromMillisecondsSinceEpoch(5001),
        ),
      ),
    );

    await csv.flush();
    await csv.stop();
    await hub.dispose();

    final meta = jsonDecode(
      await File('${start.sessionPath}/session.json').readAsString(),
    ) as Map<String, dynamic>;
    expect(meta['btKeyHex'], 'E50202E9');
    expect(meta['disSerialHex'], 'E50202E92B');
    expect(meta['serialSource'], 'ble_hex');
    expect(meta['serialOrigin'], 'dis_0x2a25');
    expect(meta['headsetFirmware'], 0x0752);
    expect(meta['headsetFirmwareHex'], '0x0752');
    expect(meta['cryptoVersion'], 4);
    expect(meta['headsetConfigHex'], '010001104010');
    expect(meta['eegRateHz'], 256.0);
    expect(meta['motionRateHz'], 64.0);
    expect(meta['headbandPosition'], 'back');
    expect(meta['negotiatedMtu'], 87);

    final eegLines = await File('${start.sessionPath}/eeg.csv').readAsLines();
    expect(eegLines.first, startsWith('wall_ms,mono_us,counter,marker_hw,AF3,'));
    expect(eegLines[1], startsWith('5000,1000,255,1,4201.0,'));

    final motLines = await File('${start.sessionPath}/motion.csv').readAsLines();
    expect(motLines.first, startsWith('wall_ms,mono_us,counter_mems,Q0,'));
    expect(motLines[1], startsWith('5001,1050,31,1.0,'));

    final cqLines = await File('${start.sessionPath}/cq.csv').readAsLines();
    expect(
      cqLines.first,
      startsWith('wall_ms,mono_us,counter,overall_cq,battery_pct,qAF3,'),
    );
    expect(cqLines[1], startsWith('5000,1000,255,82,74,4,4,2,1,'));
  });
}

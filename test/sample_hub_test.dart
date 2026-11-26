import 'package:flutter_emotiv_logger/decode/decode_pipeline.dart';
import 'package:flutter_emotiv_logger/domain/acquisition_health.dart';
import 'package:flutter_emotiv_logger/domain/samples.dart';
import 'package:flutter_emotiv_logger/sinks/lsl_sink.dart';
import 'package:flutter_emotiv_logger/sinks/sample_hub.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liblsl/lsl.dart';

void main() {
  test('network/ui drop-oldest increments counters', () {
    var health = const AcquisitionHealth();
    final hub = SampleHub(
      networkCapacity: 2,
      uiCapacity: 1,
      onHealth: (fn) => health = fn(health),
    );

    for (var i = 0; i < 4; i++) {
      hub.publishDecode(
        DecodeEegOk(
          EegSample(
            values: List.filled(14, i.toDouble()),
            receiveMonoUs: i,
            wallClock: DateTime.fromMillisecondsSinceEpoch(i),
          ),
        ),
      );
    }

    expect(health.networkDropped, greaterThan(0));
    expect(health.uiDropped, greaterThan(0));
    expect(hub.takeUiEeg().length, 1);
    hub.dispose();
  });

  test('decode failures bump decodeFailures', () {
    var health = const AcquisitionHealth();
    final hub = SampleHub(onHealth: (fn) => health = fn(health));
    hub.publishDecode(
      const DecodeFailed(
        DecodeError(
          kind: PacketKind.eeg,
          message: 'boom',
          receiveMonoUs: 1,
        ),
      ),
    );
    expect(health.decodeFailures, 1);
    hub.dispose();
  });

  test('EegSample per-electrode eQuality metadata and vector match LSL schema', () {
    expect(EegSample.qualityStreamName, 'Epoc X eQuality');
    expect(EegSample.qualityStreamType, 'Raw');
    expect(EegSample.qualityChannelNames.length, 14);
    expect(EegSample.qualityChannelNames.first, 'qAF3');
    expect(EegSample.qualityChannelNames.last, 'qAF4');
    expect(MotionSample.nominalRateHz, 32.0);

    final defaultSample = EegSample(
      values: List<double>.filled(14, 1.5),
      receiveMonoUs: 10,
      wallClock: DateTime.fromMillisecondsSinceEpoch(10),
    );
    expect(defaultSample.qualityValues(), List<double>.filled(14, 0.0));

    const grades = [4, 2, 1, 0, 4, 4, 2, 1, 0, 4, 2, 4, 1, 4];
    var health = const AcquisitionHealth();
    final hub = SampleHub(onHealth: (fn) => health = fn(health));
    hub.publishDecode(
      DecodeEegOk(
        EegSample(
          values: List<double>.filled(14, 2.5),
          receiveMonoUs: 42,
          wallClock: DateTime.fromMillisecondsSinceEpoch(42),
          contactQualityGrades: grades,
          overallCq: 57,
        ),
      ),
    );

    final drained = hub.takeLslEeg();
    expect(drained, hasLength(1));
    final cqVec = drained.single.qualityValues();
    expect(cqVec, grades.map((g) => g.toDouble()).toList());
    hub.dispose();
  });

  test('resolveLslHostname trims and defaults to iPhone', () {
    expect(resolveLslHostname(null), 'iPhone');
    expect(resolveLslHostname(''), 'iPhone');
    expect(resolveLslHostname('   '), 'iPhone');
    expect(resolveLslHostname(' iPhone '), 'iPhone');
    expect(resolveLslHostname('LabPhone'), 'LabPhone');
  });

  test(
    'LslSink publishes Epoc X, Epoc X Motion (32 Hz), and per-electrode Epoc X eQuality',
    () async {
      var health = const AcquisitionHealth();
      final hub = SampleHub(onHealth: (fn) => health = fn(health));
      final sink = LslSink(hub: hub, onHealth: (fn) => health = fn(health));
      final sourceId = 'flutter_test_${DateTime.now().microsecondsSinceEpoch}';

      final status = await sink.start(
        enabled: true,
        sourceId: sourceId,
        hostname: 'iPhone',
        eegRateHz: 256.0,
        motionRateHz: 32.0,
      );
      expect(status, LslSubsystemStatus.active);
      expect(health.lslMessage, contains('(iPhone'));

      final resolved = await LSL.resolveStreamsByProperty(
        property: LSLStreamProperty.sourceId,
        value: sourceId,
        minStreamCount: 3,
        waitTime: 4.0,
        maxStreams: 10,
      );

      try {
        final byName = {for (final s in resolved) s.streamName: s};
        expect(
          byName.keys,
          containsAll(['Epoc X', 'Epoc X Motion', 'Epoc X eQuality']),
        );
        expect(byName['Epoc X']!.sampleRate, 256.0);
        expect(byName['Epoc X eQuality']!.sampleRate, 256.0);
        expect(byName['Epoc X Motion']!.sampleRate, 32.0);

        final eqInlet = await LSL.createInlet<double>(
          streamInfo: byName['Epoc X eQuality']!,
          createTimeout: 3.0,
        );
        try {
          const grades = [4, 2, 1, 0, 4, 2, 1, 0, 4, 2, 1, 0, 4, 4];
          hub.publishDecode(
            DecodeEegOk(
              EegSample(
                values: List<double>.filled(14, 12.5),
                receiveMonoUs: 100,
                wallClock: DateTime.fromMillisecondsSinceEpoch(100),
                contactQualityGrades: grades,
                overallCq: 52,
              ),
            ),
          );

          final pulled = await eqInlet.pullSample(timeout: 3.0);
          expect(pulled.errorCode, 0);
          expect(pulled.data, hasLength(14));
          for (var i = 0; i < 14; i++) {
            expect(pulled.data[i], closeTo(grades[i].toDouble(), 1e-5));
          }
        } finally {
          await eqInlet.destroy();
        }
      } finally {
        resolved.destroy();
        await sink.stop();
        await hub.dispose();
      }
    },
  );
}

import 'package:flutter_emotiv_logger/decode/decode_pipeline.dart';
import 'package:flutter_emotiv_logger/domain/acquisition_health.dart';
import 'package:flutter_emotiv_logger/domain/samples.dart';
import 'package:flutter_emotiv_logger/sinks/sample_hub.dart';
import 'package:flutter_test/flutter_test.dart';

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
}

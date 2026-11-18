import 'dart:typed_data';

import 'package:flutter_emotiv_logger/domain/acquisition_health.dart';
import 'package:flutter_emotiv_logger/domain/samples.dart';
import 'package:flutter_emotiv_logger/sinks/sample_hub.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('RawPacket carries advisory kind plus characteristic UUID', () {
    final packet = RawPacket(
      kind: PacketKind.eeg,
      bytes: Uint8List.fromList([1, 2, 3]),
      receiveMonoUs: 42,
      wallClock: DateTime.fromMillisecondsSinceEpoch(1000),
      characteristicUuid: '81072F41-9F3D-11E3-A9DC-0002A5D5C51B',
    );

    expect(packet.kind, PacketKind.eeg);
    expect(packet.bytes, [1, 2, 3]);
    expect(packet.characteristicUuid, contains('81072F41'));
  });

  test('SampleHub publishRaw keeps short payloads for CSV', () {
    final hub = SampleHub(
      onHealth: (_) {},
    );

    hub.publishRaw(
      RawPacket(
        kind: PacketKind.eeg,
        bytes: Uint8List.fromList([9, 8]),
        receiveMonoUs: 1,
        wallClock: DateTime.fromMillisecondsSinceEpoch(1),
        characteristicUuid: '81072F41-9F3D-11E3-A9DC-0002A5D5C51B',
      ),
    );

    final taken = hub.takeCsvRaw();
    expect(taken, hasLength(1));
    expect(taken.single.bytes, [9, 8]);
    expect(taken.single.characteristicUuid, isNotNull);
  });

  test('csvDropped increments when raw queue overflows', () {
    var health = const AcquisitionHealth();
    final hub = SampleHub(
      csvCapacity: 2,
      onHealth: (update) {
        health = update(health);
      },
    );

    for (var i = 0; i < 3; i++) {
      hub.publishRaw(
        RawPacket(
          kind: PacketKind.motion,
          bytes: Uint8List.fromList([i]),
          receiveMonoUs: i,
          wallClock: DateTime.fromMillisecondsSinceEpoch(i),
        ),
      );
    }

    expect(health.csvDropped, 1);
    expect(hub.takeCsvRaw(), hasLength(2));
  });
}

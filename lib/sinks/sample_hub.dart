import 'dart:async';
import 'dart:collection';

import '../domain/acquisition_health.dart';
import '../domain/samples.dart';
import '../decode/decode_pipeline.dart';

typedef HealthUpdater = void Function(AcquisitionHealth Function(AcquisitionHealth));

/// Bounded fan-out from decode results to sinks.
///
/// CSV / LSL: large capacity; drops are counted (never silent).
/// Network / UI: drop-oldest, never backpressure acquisition.
class SampleHub {
  SampleHub({
    this.csvCapacity = 2048,
    this.lslCapacity = 2048,
    this.networkCapacity = 256,
    this.uiCapacity = 32,
    required this.onHealth,
  });

  final int csvCapacity;
  final int lslCapacity;
  final int networkCapacity;
  final int uiCapacity;
  final HealthUpdater onHealth;

  final _csvEeg = Queue<EegSample>();
  final _csvMotion = Queue<MotionSample>();
  final _csvRaw = Queue<RawPacket>();
  final _lslEeg = Queue<EegSample>();
  final _lslMotion = Queue<MotionSample>();
  final _netEeg = Queue<EegSample>();
  final _netMotion = Queue<MotionSample>();
  final _uiEeg = Queue<EegSample>();

  final _csvSignal = StreamController<void>.broadcast();
  final _lslSignal = StreamController<void>.broadcast();
  final _netSignal = StreamController<void>.broadcast();
  final _uiSignal = StreamController<void>.broadcast();

  Stream<void> get csvAvailable => _csvSignal.stream;
  Stream<void> get lslAvailable => _lslSignal.stream;
  Stream<void> get networkAvailable => _netSignal.stream;
  Stream<void> get uiAvailable => _uiSignal.stream;

  void publishDecode(DecodeResult result) {
    switch (result) {
      case DecodeEegOk(:final sample):
        _offerFirstClass(_csvEeg, sample, csvCapacity, _bumpCsvDrop);
        _offerFirstClass(_lslEeg, sample, lslCapacity, _bumpLslDrop);
        _offerDropOldest(_netEeg, sample, networkCapacity, _bumpNetDrop);
        _offerDropOldest(_uiEeg, sample, uiCapacity, _bumpUiDrop);
        _csvSignal.add(null);
        _lslSignal.add(null);
        _netSignal.add(null);
        _uiSignal.add(null);
      case DecodeMotionOk(:final sample):
        _offerFirstClass(_csvMotion, sample, csvCapacity, _bumpCsvDrop);
        _offerFirstClass(_lslMotion, sample, lslCapacity, _bumpLslDrop);
        _offerDropOldest(_netMotion, sample, networkCapacity, _bumpNetDrop);
        _csvSignal.add(null);
        _lslSignal.add(null);
        _netSignal.add(null);
      case DecodeFailed():
        onHealth((h) => h.copyWith(decodeFailures: h.decodeFailures + 1));
    }
  }

  void publishRaw(RawPacket packet) {
    _offerFirstClass(_csvRaw, packet, csvCapacity, _bumpCsvDrop);
    _csvSignal.add(null);
  }

  List<EegSample> takeCsvEeg({int max = 64}) => _take(_csvEeg, max);
  List<MotionSample> takeCsvMotion({int max = 64}) => _take(_csvMotion, max);
  List<RawPacket> takeCsvRaw({int max = 64}) => _take(_csvRaw, max);
  List<EegSample> takeLslEeg({int max = 64}) => _take(_lslEeg, max);
  List<MotionSample> takeLslMotion({int max = 64}) => _take(_lslMotion, max);
  List<EegSample> takeNetworkEeg({int max = 32}) => _take(_netEeg, max);
  List<MotionSample> takeNetworkMotion({int max = 32}) => _take(_netMotion, max);
  List<EegSample> takeUiEeg({int max = 8}) => _take(_uiEeg, max);

  void clear() {
    _csvEeg.clear();
    _csvMotion.clear();
    _csvRaw.clear();
    _lslEeg.clear();
    _lslMotion.clear();
    _netEeg.clear();
    _netMotion.clear();
    _uiEeg.clear();
  }

  Future<void> dispose() async {
    await _csvSignal.close();
    await _lslSignal.close();
    await _netSignal.close();
    await _uiSignal.close();
  }

  void _offerFirstClass<T>(
    Queue<T> q,
    T item,
    int capacity,
    void Function() onDrop,
  ) {
    if (q.length >= capacity) {
      q.removeFirst();
      onDrop();
    }
    q.addLast(item);
  }

  void _offerDropOldest<T>(
    Queue<T> q,
    T item,
    int capacity,
    void Function() onDrop,
  ) {
    if (q.length >= capacity) {
      q.removeFirst();
      onDrop();
    }
    q.addLast(item);
  }

  List<T> _take<T>(Queue<T> q, int max) {
    final out = <T>[];
    while (q.isNotEmpty && out.length < max) {
      out.add(q.removeFirst());
    }
    return out;
  }

  void _bumpCsvDrop() =>
      onHealth((h) => h.copyWith(csvDropped: h.csvDropped + 1));
  void _bumpLslDrop() =>
      onHealth((h) => h.copyWith(lslDropped: h.lslDropped + 1));
  void _bumpNetDrop() =>
      onHealth((h) => h.copyWith(networkDropped: h.networkDropped + 1));
  void _bumpUiDrop() =>
      onHealth((h) => h.copyWith(uiDropped: h.uiDropped + 1));
}

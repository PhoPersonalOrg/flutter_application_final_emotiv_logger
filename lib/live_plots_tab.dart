import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'emotiv_ble_manager.dart';

class LivePlotsContent extends StatefulWidget {
  final EmotivBLEManager bleManager;
  const LivePlotsContent({super.key, required this.bleManager});

  @override
  State<LivePlotsContent> createState() => _LivePlotsContentState();
}

class _LivePlotsContentState extends State<LivePlotsContent>
    with WidgetsBindingObserver {
  static const int eegChannels = 14;
  static const int motionChannels = 6;
  static const int eegCapacity = 1280; // 10s @ 128 Hz
  static const int motionCapacity = 160; // 10s @ ~16 Hz

  late final List<_FixedRingBuffer> _eegBuffers;
  late final List<_FixedRingBuffer> _motionBuffers;
  StreamSubscription<List<double>>? _eegSub;
  StreamSubscription<List<double>>? _motionSub;
  StreamSubscription<bool>? _connSub;

  bool _renderEnabled = true;
  int _selectedBank = 0; // 0 = EEG, 1 = Motion
  Timer? _repaintTimer;
  bool _isConnected = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Seed with current connection state so repaint timer runs immediately when already connected
    _isConnected = widget.bleManager.isConnected;
    _eegBuffers = List.generate(eegChannels, (_) => _FixedRingBuffer(eegCapacity));
    _motionBuffers = List.generate(motionChannels, (_) => _FixedRingBuffer(motionCapacity));

    _eegSub = widget.bleManager.eegDataStream.listen((sample) {
      if (sample.length >= eegChannels) {
        for (int i = 0; i < eegChannels; i++) {
          _eegBuffers[i].add(sample[i]);
        }
      }
    });

    _motionSub = widget.bleManager.motionDataStream.listen((sample) {
      if (sample.length >= motionChannels) {
        for (int i = 0; i < motionChannels; i++) {
          _motionBuffers[i].add(sample[i]);
        }
      }
    });

    _connSub = widget.bleManager.connectionStream.listen((connected) {
      setState(() => _isConnected = connected);
      if (!connected) {
        for (final b in _eegBuffers) b.clear();
        for (final b in _motionBuffers) b.clear();
      }
    });

    _startRepaintTimer();
  }

  void _startRepaintTimer() {
    _repaintTimer?.cancel();
    _repaintTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (!mounted) return;
      if (_renderEnabled && _isConnected) {
        setState(() {});
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      _renderEnabled = false; // release rendering pressure in background
    } else if (state == AppLifecycleState.resumed) {
      _renderEnabled = true;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _repaintTimer?.cancel();
    _eegSub?.cancel();
    _motionSub?.cancel();
    _connSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isEEG = _selectedBank == 0;
    final channelCount = isEEG ? eegChannels : motionChannels;
    final buffers = isEEG ? _eegBuffers : _motionBuffers;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('EEG')),
                ButtonSegment(value: 1, label: Text('Motion')),
              ],
              selected: {_selectedBank},
              onSelectionChanged: (s) => setState(() => _selectedBank = s.first),
            ),
            const Spacer(),
            Row(
              children: [
                const Text('Render'),
                Switch(
                  value: _renderEnabled,
                  onChanged: (v) => setState(() => _renderEnabled = v),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: !_isConnected
              ? const Center(
                  child: Text(
                    'Not connected... Connect a headset to view live plots',
                    textAlign: TextAlign.center,
                  ),
                )
              : ListView.builder(
                  itemCount: channelCount,
                  itemBuilder: (context, index) {
                    final label = isEEG
                        ? _eegLabels[index]
                        : _motionLabels[index];
                    return SizedBox(
                      height: 80,
                      child: Card(
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 40,
                                child: Text(
                                  label,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _renderEnabled
                                    ? CustomPaint(
                                        painter: _LinePlotPainter(
                                          buffers[index].snapshot(),
                                          gridLines: 2,
                                        ),
                                        willChange: true,
                                      )
                                    : const SizedBox.shrink(),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _FixedRingBuffer {
  final List<double> _data;
  int _writeIndex = 0;
  int _count = 0;
  _FixedRingBuffer(int capacity) : _data = List.filled(capacity, 0.0);

  void add(double v) {
    _data[_writeIndex] = v;
    _writeIndex = (_writeIndex + 1) % _data.length;
    if (_count < _data.length) _count++;
  }

  void clear() {
    for (int i = 0; i < _data.length; i++) {
      _data[i] = 0.0;
    }
    _writeIndex = 0;
    _count = 0;
  }

  List<double> snapshot() {
    if (_count == 0) return const [];
    final out = List<double>.filled(_count, 0.0);
    // Ensure positive start index for circular buffer wrap-around
    final start = (_writeIndex - _count + _data.length) % _data.length;
    for (int i = 0; i < _count; i++) {
      final idx = (start + i) % _data.length;
      out[i] = _data[idx];
    }
    return out;
  }
}

class _LinePlotPainter extends CustomPainter {
  final List<double> samples;
  final int gridLines;
  _LinePlotPainter(this.samples, {this.gridLines = 2});

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = Colors.white;
    canvas.drawRect(Offset.zero & size, bg);

    // Grid
    final gridPaint = Paint()
      ..color = Colors.grey.withOpacity(0.25)
      ..strokeWidth = 1;
    for (int i = 1; i <= gridLines; i++) {
      final y = size.height * i / (gridLines + 1);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    if (samples.isEmpty) return;

    // Auto-scale with clamp
    double minV = samples.reduce(math.min);
    double maxV = samples.reduce(math.max);
    if (minV == maxV) {
      minV -= 1;
      maxV += 1;
    }
    final range = (maxV - minV);
    final yFor = (double v) => size.height - ((v - minV) / range) * size.height;

    final path = Path();
    final dx = size.width / (samples.length - 1).clamp(1, 1 << 30);
    for (int i = 0; i < samples.length; i++) {
      final x = i * dx;
      final y = yFor(samples[i]);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    final line = Paint()
      ..color = Colors.blueAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    canvas.drawPath(path, line);
  }

  @override
  bool shouldRepaint(covariant _LinePlotPainter oldDelegate) {
    return !identical(oldDelegate.samples, samples) ||
        oldDelegate.samples.length != samples.length;
  }
}

const List<String> _eegLabels = [
  'AF3', 'F7', 'F3', 'FC5', 'T7', 'P7', 'O1', 'O2', 'P8', 'T8', 'FC6', 'F4', 'F8', 'AF4'
];

const List<String> _motionLabels = [
  'AccX', 'AccY', 'AccZ', 'GyroX', 'GyroY', 'GyroZ'
];



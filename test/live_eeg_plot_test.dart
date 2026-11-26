import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_emotiv_logger/domain/samples.dart';
import 'package:flutter_emotiv_logger/plot/contact_quality_head_map.dart';
import 'package:flutter_emotiv_logger/plot/contact_quality_history_strip.dart';
import 'package:flutter_emotiv_logger/plot/contact_quality_tier.dart';
import 'package:flutter_emotiv_logger/plot/eeg_stacked_lane_plot.dart';
import 'package:flutter_emotiv_logger/plot/live_eeg_ring_buffer.dart';
import 'package:flutter_emotiv_logger/sinks/sample_hub.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ContactQualityTier', () {
    test('maps discrete Cortex CQ grades {0, 1, 2, 3, 4} and palette colors', () {
      expect(ContactQualityTier.fromCortexGrade(null), ContactQualityTier.unknown);
      expect(ContactQualityTier.fromCortexGrade(0), ContactQualityTier.unknown);
      expect(ContactQualityTier.fromCortexGrade(1), ContactQualityTier.poor);
      expect(ContactQualityTier.fromCortexGrade(2), ContactQualityTier.fair);
      expect(ContactQualityTier.fromCortexGrade(3), ContactQualityTier.good);
      expect(ContactQualityTier.fromCortexGrade(4), ContactQualityTier.excellent);

      expect(ContactQualityTier.unknown.color, const Color(0xFF808080));
      expect(ContactQualityTier.poor.color, const Color(0xFFD32F2F));
      expect(ContactQualityTier.fair.color, const Color(0xFFF57C00));
      expect(ContactQualityTier.good.color, const Color(0xFFFDD835));
      expect(ContactQualityTier.excellent.color, const Color(0xFF43A047));
    });

    test('roundtrips tier index 0..4', () {
      for (final tier in ContactQualityTier.values) {
        expect(ContactQualityTier.fromTierIndex(tier.index_), tier);
      }
    });
  });

  group('SampleHub UI capacity', () {
    test('defaults uiCapacity to 256', () {
      final hub = SampleHub(onHealth: (_) {});
      expect(hub.uiCapacity, 256);
      hub.dispose();
    });
  });

  group('LiveEegRingBuffer', () {
    test('pushes and wraps chronological samples and per-electrode CQ grades', () {
      final ring = LiveEegRingBuffer(
        channelCount: 2,
        windowSamples: 4,
        targetDrawPoints: 4,
      );

      for (var i = 1; i <= 6; i++) {
        ring.push(
          EegSample(
            values: [i.toDouble(), (i * 10).toDouble()],
            receiveMonoUs: i * 10000,
            wallClock: DateTime.fromMillisecondsSinceEpoch(i * 10),
            contactQualityGrades: [i.isEven ? 4 : 1, 2],
          ),
        );
      }

      expect(ring.length, 4);
      expect(ring.readChannelChronological(0), [3.0, 4.0, 5.0, 6.0]);
      expect(ring.readChannelChronological(1), [30.0, 40.0, 50.0, 60.0]);
      expect(ring.latestChannelGrades, [4, 2]);
      expect(ring.latestOverallCq, 75);

      final snap = ring.snapshot();
      expect(snap.sampleCount, 4);
      expect(snap.downsampledChannels.length, 2);
      expect(snap.downsampledChannels[0], [3.0, 4.0, 5.0, 6.0]);
      expect(snap.latestTier, ContactQualityTier.excellent);
    });

    test('LTTB downsampler preserves endpoints and spike extrema', () {
      final raw = Float64List(200);
      for (var i = 0; i < raw.length; i++) {
        raw[i] = math.sin(i * 0.05);
      }
      raw[77] = 50.0;
      raw[143] = -42.0;

      final ds = LiveEegRingBuffer.lttbDownsampleUniform(raw, raw.length, 24);
      expect(ds.length, 24);
      expect(ds.first, raw.first);
      expect(ds.last, raw.last);
      expect(ds, contains(50.0));
      expect(ds, contains(-42.0));
    });

    test('commits per-channel CQ history bins immutably without retroactive mutation', () {
      final ring = LiveEegRingBuffer(
        channelCount: 2,
        windowSamples: 16,
        targetDrawPoints: 8,
        cqBinDurationUs: 100000,
        cqHistoryBins: 8,
      );

      void pushAt(int monoUs, List<int> grades) {
        ring.push(
          EegSample(
            values: const [1.0, 2.0],
            receiveMonoUs: monoUs,
            wallClock: DateTime.fromMicrosecondsSinceEpoch(monoUs),
            contactQualityGrades: grades,
          ),
        );
      }

      // Bin 0: ch0 = poor(1), ch1 = fair(2)
      pushAt(10000, const [1, 2]);
      final snap0 = ring.snapshot();
      expect(snap0.cqHistoryChannelTiers, [1, 2]);

      // Bin 1: ch0 = excellent(4), ch1 = poor(1). Bin 0 stays [1, 2].
      pushAt(120000, const [4, 1]);
      final snap1 = ring.snapshot();
      expect(snap1.cqHistoryChannelTiers, [1, 2, 4, 1]);

      // Update within bin 1: only live rightmost bin mutates; bin 0 untouched!
      pushAt(180000, const [4, 4]);
      final snap1b = ring.snapshot();
      expect(snap1b.cqHistoryChannelTiers, [1, 2, 4, 4]);
    });

    test('clear resets ring samples and CQ history', () {
      final ring = LiveEegRingBuffer(
        channelCount: 2,
        windowSamples: 8,
        targetDrawPoints: 4,
      );
      ring.push(
        EegSample(
          values: const [5.0, 6.0],
          receiveMonoUs: 300000,
          wallClock: DateTime.fromMillisecondsSinceEpoch(300),
          contactQualityGrades: const [4, 4],
          overallCq: 100,
        ),
      );
      expect(ring.length, 1);
      ring.clear();
      expect(ring.length, 0);
      expect(ring.latestOverallCq, 0);
      expect(ring.latestChannelGrades, [0, 0]);
      expect(ring.snapshot().cqHistoryTiers, isEmpty);
      expect(ring.snapshot().cqHistoryChannelTiers, isEmpty);
    });
  });

  group('EpocXHeadSvgGeometry', () {
    test('parses all 14 electrode circles and silhouette paths from bundled SVG', () {
      final svgFile = File('assets/emotiv_epoc_x_head_layout.svg');
      expect(svgFile.existsSync(), isTrue);
      final parsed = EpocXHeadSvgGeometry.parseSvgXml(svgFile.readAsStringSync());
      expect(parsed.viewBox, const Rect.fromLTWH(0, 0, 262, 354));
      expect(parsed.electrodes.keys.toSet(), EegSample.channelNames.toSet());
      expect(parsed.silhouettePaths, isNotEmpty);
      expect(parsed.electrodes['AF3']!.cx, closeTo(99.15, 1e-2));
      expect(parsed.electrodes['O2']!.cy, closeTo(312.34, 1e-2));
    });
  });

  group('Plot widgets smoke', () {
    testWidgets(
      'EegStackedLanePlot, ContactQualityHeadMap, and ContactQualityHistoryStrip render per-electrode CQ',
      (tester) async {
        final ring = LiveEegRingBuffer();
        for (var i = 0; i < 200; i++) {
          ring.push(
            EegSample(
              values: List<double>.generate(
                EegSample.channelCount,
                (ch) => 40.0 * math.sin((i + ch * 5) * 0.12),
              ),
              receiveMonoUs: i * 7812,
              wallClock: DateTime.fromMillisecondsSinceEpoch(1000 + i * 8),
              contactQualityGrades: List<int>.generate(
                EegSample.channelCount,
                (ch) => (ch % 3 == 0) ? 4 : ((ch % 3 == 1) ? 2 : 1),
              ),
            ),
          );
        }
        final snap = ring.snapshot();

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: Column(
                  children: [
                    EegStackedLanePlot(snapshot: snap),
                    ContactQualityHistoryStrip(
                      cqHistoryTiers: snap.cqHistoryTiers,
                      cqHistoryChannelTiers: snap.cqHistoryChannelTiers,
                    ),
                    ContactQualityHeadMap(
                      channelGrades: snap.latestChannelGrades,
                      overallCq: snap.latestOverallCq,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        expect(find.byType(EegStackedLanePlot), findsOneWidget);
        expect(find.byType(ContactQualityHistoryStrip), findsOneWidget);
        expect(find.byType(ContactQualityHeadMap), findsOneWidget);
        expect(find.text('Excellent'), findsOneWidget);
      },
    );
  });
}

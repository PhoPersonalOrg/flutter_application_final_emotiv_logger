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
    test('maps Mode-7 raw 0..127 bands to pyPhoTimeline tiers and hex colors', () {
      expect(ContactQualityTier.fromMode7Raw(null), ContactQualityTier.unknown);
      expect(ContactQualityTier.fromMode7Raw(-1), ContactQualityTier.unknown);
      expect(ContactQualityTier.fromMode7Raw(0), ContactQualityTier.unknown);

      expect(ContactQualityTier.fromMode7Raw(1), ContactQualityTier.poor);
      expect(ContactQualityTier.fromMode7Raw(31), ContactQualityTier.poor);

      expect(ContactQualityTier.fromMode7Raw(32), ContactQualityTier.fair);
      expect(ContactQualityTier.fromMode7Raw(63), ContactQualityTier.fair);

      expect(ContactQualityTier.fromMode7Raw(64), ContactQualityTier.good);
      expect(ContactQualityTier.fromMode7Raw(95), ContactQualityTier.good);

      expect(ContactQualityTier.fromMode7Raw(96), ContactQualityTier.excellent);
      expect(ContactQualityTier.fromMode7Raw(127), ContactQualityTier.excellent);

      // Exact pyPhoTimeline hex palette.
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
    test('pushes and wraps chronological samples per channel', () {
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
            contactQuality: i * 15,
          ),
        );
      }

      expect(ring.length, 4);
      expect(ring.readChannelChronological(0), [3.0, 4.0, 5.0, 6.0]);
      expect(ring.readChannelChronological(1), [30.0, 40.0, 50.0, 60.0]);
      expect(ring.latestContactQuality, 90);

      final snap = ring.snapshot();
      expect(snap.sampleCount, 4);
      expect(snap.downsampledChannels.length, 2);
      expect(snap.downsampledChannels[0], [3.0, 4.0, 5.0, 6.0]);
      expect(snap.latestTier, ContactQualityTier.good);
    });

    test('LTTB downsampler preserves endpoints and spike extrema', () {
      final raw = Float64List(200);
      for (var i = 0; i < raw.length; i++) {
        raw[i] = math.sin(i * 0.05);
      }
      raw[77] = 50.0; // sharp positive spike
      raw[143] = -42.0; // sharp negative spike

      final ds = LiveEegRingBuffer.lttbDownsampleUniform(raw, raw.length, 24);
      expect(ds.length, 24);
      expect(ds.first, raw.first);
      expect(ds.last, raw.last);
      expect(ds, contains(50.0));
      expect(ds, contains(-42.0));
    });

    test('CQ history commits completed bins immutably without retroactive mutation', () {
      final ring = LiveEegRingBuffer(
        channelCount: 2,
        windowSamples: 16,
        targetDrawPoints: 8,
        cqBinDurationUs: 100000, // 100 ms bins
        cqHistoryBins: 8,
      );

      void pushAt(int monoUs, int cq) {
        ring.push(
          EegSample(
            values: const [1.0, 2.0],
            receiveMonoUs: monoUs,
            wallClock: DateTime.fromMicrosecondsSinceEpoch(monoUs),
            contactQuality: cq,
          ),
        );
      }

      // Bin 0: poor (10)
      pushAt(10000, 10);
      pushAt(50000, 20);
      final snap0 = ring.snapshot();
      expect(snap0.cqHistoryTiers, [ContactQualityTier.poor.index_]);

      // Advance to bin 1: fair (40). Bin 0 is now committed as poor.
      pushAt(120000, 40);
      final snap1 = ring.snapshot();
      expect(snap1.cqHistoryTiers, [
        ContactQualityTier.poor.index_,
        ContactQualityTier.fair.index_,
      ]);

      // Advance to bin 2: excellent (110). Past bins [poor, fair] stay identical.
      pushAt(230000, 110);
      final snap2 = ring.snapshot();
      expect(snap2.cqHistoryTiers, [
        ContactQualityTier.poor.index_,
        ContactQualityTier.fair.index_,
        ContactQualityTier.excellent.index_,
      ]);

      // Update within bin 2 to good (70): only the live rightmost cell changes;
      // committed history [poor, fair] is untouched.
      pushAt(280000, 70);
      final snap2b = ring.snapshot();
      expect(snap2b.cqHistoryTiers, [
        ContactQualityTier.poor.index_,
        ContactQualityTier.fair.index_,
        ContactQualityTier.good.index_,
      ]);
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
          contactQuality: 100,
        ),
      );
      expect(ring.length, 1);
      ring.clear();
      expect(ring.length, 0);
      expect(ring.latestContactQuality, 0);
      expect(ring.snapshot().cqHistoryTiers, isEmpty);
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
    testWidgets('EegStackedLanePlot, ContactQualityHeadMap, and ContactQualityHistoryStrip build with synthetic ring data',
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
            contactQuality: (i < 64) ? 25 : (i < 128 ? 55 : 108),
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
                  ContactQualityHistoryStrip(cqHistoryTiers: snap.cqHistoryTiers),
                  ContactQualityHeadMap(contactQuality: snap.latestContactQuality),
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
    });
  });
}

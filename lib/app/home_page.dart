import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../domain/acquisition_health.dart';
import '../domain/acquisition_state.dart';
import '../plot/contact_quality_head_map.dart';
import '../plot/contact_quality_history_strip.dart';
import '../plot/contact_quality_tier.dart';
import '../plot/eeg_stacked_lane_plot.dart';
import '../plot/live_eeg_ring_buffer.dart';
import 'providers.dart';
import 'settings_page.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ensurePermissions();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      ref.read(acquisitionSessionProvider).flush();
    }
  }

  Future<void> _ensurePermissions() async {
    final permissions = <Permission>[
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ];
    // Android 13+ needs POST_NOTIFICATIONS for the streaming FGS notification.
    if (Platform.isAndroid) {
      permissions.add(Permission.notification);
    }
    await permissions.request();
  }

  @override
  Widget build(BuildContext context) {
    final asyncState = ref.watch(acquisitionStateProvider);
    final buildInfoAsync = ref.watch(buildInfoProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Emotiv Acquisition'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: asyncState.when(
              data: (state) => _Body(state: state),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('State error: $e')),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Text(
              buildInfoAsync.when(
                data: (info) => info.label,
                loading: () => '',
                error: (_, __) => '',
              ),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.state});

  final AcquisitionState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final health = state.health;
    final plotAsync = ref.watch(liveEegPlotSnapshotProvider);
    final sessionActive = state is AcquisitionStreaming ||
        state is AcquisitionPreparing ||
        state is AcquisitionConnecting ||
        state is AcquisitionReconnecting;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _StateChip(state: state),
            if (health.batteryPercent != null)
              _BatteryChip(percent: health.batteryPercent!),
          ],
        ),
        const SizedBox(height: 12),
        _HealthCard(health: health),
        const SizedBox(height: 12),
        _Controls(state: state),
        const SizedBox(height: 12),
        if (state is AcquisitionScanning) ...[
          if ((state as AcquisitionScanning).errorMessage != null) ...[
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: ListTile(
                title: Text((state as AcquisitionScanning).errorMessage!),
                subtitle: const Text('Device list kept — tap Connect to retry'),
              ),
            ),
            const SizedBox(height: 12),
          ],
          _DeviceList(scanning: state as AcquisitionScanning),
          const SizedBox(height: 12),
        ],
        if (state is AcquisitionFailed) ...[
          Card(
            color: Theme.of(context).colorScheme.errorContainer,
            child: ListTile(
              title: Text((state as AcquisitionFailed).message),
              trailing: TextButton(
                onPressed: () =>
                    ref.read(acquisitionSessionProvider).resetFromFailure(),
                child: const Text('Reset'),
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
        _SignalPreviewCard(
          sessionActive: sessionActive,
          snapshot: plotAsync.value ?? LiveEegPlotSnapshot.empty,
        ),
      ],
    );
  }
}

class _StateChip extends StatelessWidget {
  const _StateChip({required this.state});
  final AcquisitionState state;

  Color _color(BuildContext context) {
    return switch (state) {
      AcquisitionStreaming() => Colors.green.shade700,
      AcquisitionReconnecting() => Colors.orange.shade800,
      AcquisitionFailed() => Colors.red.shade700,
      AcquisitionScanning() || AcquisitionConnecting() || AcquisitionPreparing() =>
        Colors.blue.shade700,
      _ => Colors.grey.shade700,
    };
  }

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Icon(Icons.circle, size: 12, color: _color(context)),
      label: Text(state.label, style: const TextStyle(fontWeight: FontWeight.w600)),
    );
  }
}

class _BatteryChip extends StatelessWidget {
  const _BatteryChip({required this.percent});
  final int percent;

  Color get _color {
    if (percent >= 50) return Colors.green.shade700;
    if (percent >= 20) return Colors.orange.shade800;
    return Colors.red.shade700;
  }

  IconData get _icon {
    if (percent >= 90) return Icons.battery_full;
    if (percent >= 60) return Icons.battery_5_bar;
    if (percent >= 40) return Icons.battery_4_bar;
    if (percent >= 20) return Icons.battery_2_bar;
    return Icons.battery_alert;
  }

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Icon(_icon, size: 18, color: _color),
      label: Text(
        '$percent%',
        style: TextStyle(fontWeight: FontWeight.w600, color: _color),
      ),
    );
  }
}

class _HealthCard extends StatelessWidget {
  const _HealthCard({required this.health});
  final AcquisitionHealth health;

  @override
  Widget build(BuildContext context) {
    final lslLabel = switch (health.lslStatus) {
      LslSubsystemStatus.active => 'Active',
      LslSubsystemStatus.degraded => 'Degraded',
      LslSubsystemStatus.disabled => 'Disabled',
      LslSubsystemStatus.idle => 'Idle',
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Health', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 16,
              runSpacing: 8,
              children: [
                _metric(
                  'Battery',
                  health.batteryPercent != null
                      ? '${health.batteryPercent}%'
                      : '—',
                ),
                _metric('EEG Hz', health.eegHz.toStringAsFixed(0)),
                _metric('Motion Hz', health.motionHz.toStringAsFixed(0)),
                _metric('EEG pkts', '${health.eegPackets}'),
                _metric('Decode fail', '${health.decodeFailures}'),
                _metric('Gaps', '${health.gapCount}'),
                _metric('CSV drop', '${health.csvDropped}'),
                _metric(
                  'CSV',
                  health.csvUsingFallback ? 'Fallback' : 'OK',
                ),
                _metric('LSL drop', '${health.lslDropped}'),
                _metric('LSL', lslLabel),
                _metric(
                  'Net',
                  health.networkEnabled
                      ? (health.networkConnected ? 'Up' : 'Down')
                      : 'Off',
                ),
              ],
            ),
            if (health.decodeMessage != null) ...[
              const SizedBox(height: 8),
              Text(
                health.decodeMessage!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.orange.shade900,
                    ),
              ),
            ],
            if (health.csvMessage != null) ...[
              const SizedBox(height: 8),
              Text(
                health.csvMessage!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: health.csvUsingFallback
                          ? Colors.orange.shade900
                          : null,
                    ),
              ),
            ],
            if (health.csvSessionPath != null) ...[
              const SizedBox(height: 4),
              Text(
                health.csvSessionPath!,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (health.lslMessage != null) ...[
              const SizedBox(height: 4),
              Text(
                health.lslMessage!,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (health.networkMessage != null) ...[
              const SizedBox(height: 4),
              Text(
                health.networkMessage!,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (health.syncMessage != null) ...[
              const SizedBox(height: 4),
              Text(
                health.syncMessage!,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ] else if (health.dropboxMessage != null) ...[
              const SizedBox(height: 4),
              Text(
                health.dropboxMessage!,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _metric(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.black54)),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
      ],
    );
  }
}

class _Controls extends ConsumerWidget {
  const _Controls({required this.state});
  final AcquisitionState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.read(acquisitionSessionProvider);
    final settings = ref.watch(settingsProvider);
    final canScan = state is AcquisitionIdle ||
        state is AcquisitionFailed ||
        state is AcquisitionScanning;
    final scanning = state is AcquisitionScanning;
    final scanActive = scanning && (state as AcquisitionScanning).active;
    final streaming = state is AcquisitionStreaming ||
        state is AcquisitionPreparing ||
        state is AcquisitionConnecting ||
        state is AcquisitionReconnecting;
    final preferredName =
        settings.preferredDeviceName ?? session.preferredDeviceName;

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (!streaming)
          FilledButton.icon(
            onPressed: canScan
                ? () => scanActive ? session.stopScan() : session.startScan()
                : null,
            icon: Icon(
              scanActive ? Icons.stop : Icons.bluetooth_searching,
            ),
            label: Text(scanActive ? 'Stop scan' : 'Scan'),
          ),
        if (!streaming &&
            preferredName != null &&
            preferredName.isNotEmpty &&
            canScan)
          FilledButton.tonalIcon(
            onPressed: () => session.reconnectPreferred(),
            icon: const Icon(Icons.link),
            label: Text('Reconnect $preferredName'),
          ),
        if (streaming)
          FilledButton.tonalIcon(
            onPressed: () => session.disconnect(),
            icon: const Icon(Icons.link_off),
            label: const Text('Stop'),
          ),
      ],
    );
  }
}

class _SignalPreviewCard extends StatelessWidget {
  const _SignalPreviewCard({
    required this.sessionActive,
    required this.snapshot,
  });

  final bool sessionActive;
  final LiveEegPlotSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final cq = snapshot.latestContactQuality;
    final tier = snapshot.latestTier;
    final hasCq = snapshot.hasSamples && cq > 0;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Signal preview',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                _CqReadoutChip(
                  cq: cq,
                  tier: tier,
                  active: sessionActive && snapshot.hasSamples,
                  hasCq: hasCq,
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (!sessionActive && !snapshot.hasSamples)
              Row(
                children: [
                  Icon(
                    Icons.radio_button_unchecked,
                    size: 18,
                    color: Colors.grey.shade600,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Idle — connect headset for live 14-ch EEG and contact quality',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                ],
              )
            else ...[
              EegStackedLanePlot(
                snapshot: snapshot,
                streaming: sessionActive,
                height: 184,
              ),
              const SizedBox(height: 8),
              ContactQualityHistoryStrip(
                cqHistoryTiers: snapshot.cqHistoryTiers,
                height: 40,
              ),
              const SizedBox(height: 10),
              ContactQualityHeadMap(
                contactQuality: cq,
                height: 128,
              ),
              const SizedBox(height: 4),
              Text(
                'Mode-7: single headset CQ (all sensors)',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.grey.shade600,
                    ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CqReadoutChip extends StatelessWidget {
  const _CqReadoutChip({
    required this.cq,
    required this.tier,
    required this.active,
    required this.hasCq,
  });

  final int cq;
  final ContactQualityTier tier;
  final bool active;
  final bool hasCq;

  @override
  Widget build(BuildContext context) {
    final bg = active ? tier.color : Colors.grey.shade300;
    final fg = active ? tier.labelColor : Colors.black87;
    final text = active
        ? (hasCq ? 'CQ $cq · ${tier.label}' : 'CQ 0 · ${tier.label}')
        : 'CQ —';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: fg,
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}

class _DeviceList extends ConsumerWidget {
  const _DeviceList({required this.scanning});
  final AcquisitionScanning scanning;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final devices = scanning.devices;
    if (devices.isEmpty) {
      return Card(
        child: ListTile(
          leading: scanning.active
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.bluetooth_disabled),
          title: Text(
            scanning.active
                ? 'Scanning for Emotiv headsets…'
                : 'No Emotiv headsets found',
          ),
          subtitle: Text(
            scanning.active
                ? 'Looking for EPOC / Epoc X advertising names'
                : 'Power the headset, wear it nearby, then scan again',
          ),
        ),
      );
    }
    return Card(
      child: Column(
        children: [
          ListTile(
            dense: true,
            title: Text(
              scanning.active
                  ? 'Found ${devices.length} · scanning…'
                  : 'Found ${devices.length} · tap Connect',
            ),
          ),
          for (final d in devices)
            ListTile(
              leading: Icon(
                d.isPreferred ? Icons.star : Icons.headphones,
                color: d.isPreferred
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
              title: Text(d.name),
              subtitle: Text(
                [
                  if (d.serialHex != null) 'SN ${d.serialHex}',
                  if (d.rssi != null) '${d.rssi} dBm',
                  d.id,
                ].join(' · '),
              ),
              trailing: FilledButton(
                onPressed: () =>
                    ref.read(acquisitionSessionProvider).connect(d.id),
                child: Text(d.isPreferred ? 'Reconnect' : 'Connect'),
              ),
            ),
        ],
      ),
    );
  }
}

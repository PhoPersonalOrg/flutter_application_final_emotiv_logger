import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../domain/acquisition_health.dart';
import '../domain/acquisition_state.dart';
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
    await [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
  }

  @override
  Widget build(BuildContext context) {
    final asyncState = ref.watch(acquisitionStateProvider);

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
      body: asyncState.when(
        data: (state) => _Body(state: state),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('State error: $e')),
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
    final preview = ref.watch(uiEegPreviewProvider);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _StateChip(state: state),
        const SizedBox(height: 12),
        _HealthCard(health: health),
        const SizedBox(height: 12),
        _Controls(state: state),
        const SizedBox(height: 12),
        if (state is AcquisitionScanning) ...[
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
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('EEG preview', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                preview.when(
                  data: (values) => Text(
                    values.isEmpty
                        ? '—'
                        : values
                            .take(6)
                            .map((v) => v.toStringAsFixed(1))
                            .join('  '),
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                  loading: () => const Text('—'),
                  error: (error, stack) => const Text('—'),
                ),
              ],
            ),
          ),
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
    return Align(
      alignment: Alignment.centerLeft,
      child: Chip(
        avatar: Icon(Icons.circle, size: 12, color: _color(context)),
        label: Text(state.label, style: const TextStyle(fontWeight: FontWeight.w600)),
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
            onPressed: scanActive
                ? null
                : () => session.reconnectPreferred(),
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

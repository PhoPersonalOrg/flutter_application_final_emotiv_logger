import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../directory_helper.dart';
import 'providers.dart';
import 'settings.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  late TextEditingController _host;
  late TextEditingController _port;
  late AppSettings _draft;

  @override
  void initState() {
    super.initState();
    _draft = ref.read(settingsProvider);
    _host = TextEditingController(text: _draft.networkHost);
    _port = TextEditingController(text: '${_draft.networkPort}');
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  Future<void> _pickDirectory() async {
    await DirectoryHelper.requestStoragePermission();
    final path = await DirectoryHelper.selectDirectory();
    if (path != null) {
      setState(() => _draft = _draft.copyWith(saveDirectory: path));
    }
  }

  Future<void> _apply() async {
    final port = int.tryParse(_port.text.trim()) ?? AppSettings.defaultPort;
    final next = _draft.copyWith(
      networkHost: _host.text.trim().isEmpty
          ? AppSettings.defaultHost
          : _host.text.trim(),
      networkPort: port,
    );
    await ref.read(settingsProvider.notifier).save(next);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            title: const Text('Save directory'),
            subtitle: Text(_draft.saveDirectory ?? '(app documents)'),
            trailing: IconButton(
              icon: const Icon(Icons.folder_open),
              onPressed: _pickDirectory,
            ),
          ),
          SwitchListTile(
            title: const Text('LSL outlet'),
            subtitle: const Text('First-class sink; degrades if native lib fails'),
            value: _draft.lslEnabled,
            onChanged: (v) => setState(() => _draft = _draft.copyWith(lslEnabled: v)),
          ),
          const Divider(),
          SwitchListTile(
            title: const Text('Network stream (best-effort)'),
            value: _draft.useNetworkStream,
            onChanged: (v) =>
                setState(() => _draft = _draft.copyWith(useNetworkStream: v)),
          ),
          TextField(
            controller: _host,
            decoration: const InputDecoration(labelText: 'Host'),
            enabled: _draft.useNetworkStream,
          ),
          TextField(
            controller: _port,
            decoration: const InputDecoration(labelText: 'Port'),
            keyboardType: TextInputType.number,
            enabled: _draft.useNetworkStream,
          ),
          DropdownButtonFormField<NetworkProtocol>(
            initialValue: _draft.networkProtocol,
            decoration: const InputDecoration(labelText: 'Protocol'),
            items: [
              for (final p in NetworkProtocol.values)
                DropdownMenuItem(value: p, child: Text(p.name.toUpperCase())),
            ],
            onChanged: _draft.useNetworkStream
                ? (p) {
                    if (p != null) {
                      setState(
                        () => _draft = _draft.copyWith(networkProtocol: p),
                      );
                    }
                  }
                : null,
          ),
          const SizedBox(height: 24),
          FilledButton(onPressed: _apply, child: const Text('Apply')),
        ],
      ),
    );
  }
}

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../directory_helper.dart';
import '../sessions/dropbox_config.dart';
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
  late TextEditingController _dropboxRoot;
  late AppSettings _draft;
  bool _dropboxBusy = false;
  String? _dropboxStatus;

  @override
  void initState() {
    super.initState();
    _draft = ref.read(settingsProvider);
    _host = TextEditingController(text: _draft.networkHost);
    _port = TextEditingController(text: '${_draft.networkPort}');
    _dropboxRoot = TextEditingController(text: _draft.dropboxRemoteRoot);
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshDropboxStatus());
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _dropboxRoot.dispose();
    super.dispose();
  }

  Future<void> _refreshDropboxStatus() async {
    if (!DropboxConfig.isConfigured) {
      if (mounted) {
        setState(
          () => _dropboxStatus =
              'Not configured — rebuild with DROPBOX_APP_KEY (see README)',
        );
      }
      return;
    }
    final linked = await ref.read(dropboxSyncProvider).isLinked();
    if (!mounted) return;
    setState(() => _dropboxStatus = linked ? 'Connected' : 'Not connected');
  }

  Future<void> _pickDirectory() async {
    await DirectoryHelper.requestStoragePermission();
    final path = await DirectoryHelper.selectDirectory();
    if (path != null) {
      setState(() => _draft = _draft.copyWith(saveDirectory: path));
    }
  }

  Future<void> _connectDropbox() async {
    setState(() {
      _dropboxBusy = true;
      _dropboxStatus = 'Authorizing…';
    });
    try {
      await ref.read(dropboxSyncProvider).connect();
      ref.invalidate(dropboxLinkedProvider);
      if (!mounted) return;
      setState(() => _dropboxStatus = 'Connected');
    } catch (e) {
      if (!mounted) return;
      setState(() => _dropboxStatus = 'Connect failed: $e');
    } finally {
      if (mounted) setState(() => _dropboxBusy = false);
    }
  }

  Future<void> _disconnectDropbox() async {
    setState(() => _dropboxBusy = true);
    try {
      await ref.read(dropboxSyncProvider).unlink();
      ref.invalidate(dropboxLinkedProvider);
      if (!mounted) return;
      setState(() {
        _draft = _draft.copyWith(dropboxAutoUpload: false);
        _dropboxStatus = 'Not connected';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _dropboxStatus = 'Disconnect failed: $e');
    } finally {
      if (mounted) setState(() => _dropboxBusy = false);
    }
  }

  Future<void> _apply() async {
    final port = int.tryParse(_port.text.trim()) ?? AppSettings.defaultPort;
    final root = _dropboxRoot.text.trim().isEmpty
        ? AppSettings.defaultDropboxRemoteRoot
        : _dropboxRoot.text.trim();
    final next = _draft.copyWith(
      networkHost: _host.text.trim().isEmpty
          ? AppSettings.defaultHost
          : _host.text.trim(),
      networkPort: port,
      dropboxRemoteRoot: root,
    );
    await ref.read(settingsProvider.notifier).save(next);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final linkedAsync = ref.watch(dropboxLinkedProvider);
    final linked = linkedAsync.asData?.value ?? false;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (Platform.isIOS)
            const ListTile(
              title: Text('Save directory'),
              subtitle: Text(
                'App documents (Files → On My iPhone → Flutter Emotiv Logger)',
              ),
            )
          else
            ListTile(
              title: const Text('Save directory'),
              subtitle: Text(_draft.saveDirectory ?? '(app documents)'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_draft.saveDirectory != null)
                    IconButton(
                      tooltip: 'Use app documents',
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        setState(
                          () => _draft =
                              _draft.copyWith(clearSaveDirectory: true),
                        );
                      },
                    ),
                  IconButton(
                    tooltip: 'Pick folder',
                    icon: const Icon(Icons.folder_open),
                    onPressed: _pickDirectory,
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              Platform.isIOS
                  ? 'Recordings always go to app documents on iOS so they stay '
                      'writable across launches. Open them in the Files app or '
                      'transfer from the Sessions tab.'
                  : 'App documents is the reliable default. Custom folders often '
                      'lose permission after relaunch; acquisition will fall '
                      'back automatically if a custom path is denied.',
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ),
          SwitchListTile(
            title: const Text('LSL outlet'),
            subtitle: const Text('First-class sink; degrades if native lib fails'),
            value: _draft.lslEnabled,
            onChanged: (v) =>
                setState(() => _draft = _draft.copyWith(lslEnabled: v)),
          ),
          const Divider(),
          const ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('Dropbox'),
            subtitle: Text('App Folder sync for session uploads'),
          ),
          if (_dropboxStatus != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                _dropboxStatus!,
                style: TextStyle(
                  color: linked ? Colors.green.shade800 : Colors.black54,
                  fontSize: 13,
                ),
              ),
            ),
          Row(
            children: [
              FilledButton.tonal(
                onPressed: _dropboxBusy || !DropboxConfig.isConfigured
                    ? null
                    : (linked ? _disconnectDropbox : _connectDropbox),
                child: _dropboxBusy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(linked ? 'Disconnect' : 'Connect Dropbox'),
              ),
            ],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Auto-upload after Stop'),
            subtitle: const Text('Uploads the finished session folder'),
            value: _draft.dropboxAutoUpload,
            onChanged: linked
                ? (v) => setState(
                      () => _draft = _draft.copyWith(dropboxAutoUpload: v),
                    )
                : null,
          ),
          TextField(
            controller: _dropboxRoot,
            enabled: linked,
            decoration: const InputDecoration(
              labelText: 'Dropbox folder (under App Folder)',
              hintText: 'EmotivSessions',
            ),
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

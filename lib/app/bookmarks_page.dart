import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../sessions/server_bookmark.dart';
import '../sessions/session_transfer.dart';
import 'providers.dart';

String _newBookmarkId() {
  final r = Random.secure().nextInt(0x7fffffff);
  return '${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}_$r';
}

/// Manage SFTP/SMB server bookmarks.
class BookmarksPage extends ConsumerWidget {
  const BookmarksPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(bookmarkStoreProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Server bookmarks')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _edit(context, ref, null),
        child: const Icon(Icons.add),
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (state) {
          if (state.bookmarks.isEmpty) {
            return const Center(
              child: Text('No bookmarks yet. Tap + to add a server.'),
            );
          }
          return ListView.builder(
            itemCount: state.bookmarks.length,
            itemBuilder: (context, i) {
              final b = state.bookmarks[i];
              final isLast = b.id == state.lastUsedBookmarkId;
              return ListTile(
                leading: Icon(
                  b.protocol == TransferProtocol.sftp
                      ? Icons.terminal
                      : Icons.storage,
                ),
                title: Text(b.name),
                subtitle: Text(
                  '${b.protocol.label}  ${b.username}@${b.host}:${b.port}'
                  '${b.protocol == TransferProtocol.smb && b.smbShare.isNotEmpty ? ' /${b.smbShare}' : ''}'
                  '${isLast ? '  · last used' : ''}',
                ),
                isThreeLine: true,
                trailing: PopupMenuButton<String>(
                  onSelected: (value) async {
                    switch (value) {
                      case 'edit':
                        await _edit(context, ref, b);
                      case 'default':
                        await ref
                            .read(bookmarkStoreProvider.notifier)
                            .setLastUsed(b.id);
                      case 'delete':
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('Delete bookmark?'),
                            content: Text('Remove “${b.name}”?'),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, false),
                                child: const Text('Cancel'),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.pop(ctx, true),
                                child: const Text('Delete'),
                              ),
                            ],
                          ),
                        );
                        if (ok == true) {
                          await ref
                              .read(bookmarkStoreProvider.notifier)
                              .delete(b.id);
                        }
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'edit', child: Text('Edit')),
                    PopupMenuItem(
                      value: 'default',
                      child: Text('Set as last used'),
                    ),
                    PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                ),
                onTap: () => _edit(context, ref, b),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    ServerBookmark? existing,
  ) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BookmarkEditorPage(existing: existing),
      ),
    );
  }
}

class BookmarkEditorPage extends ConsumerStatefulWidget {
  const BookmarkEditorPage({super.key, this.existing});

  final ServerBookmark? existing;

  @override
  ConsumerState<BookmarkEditorPage> createState() => _BookmarkEditorPageState();
}

class _BookmarkEditorPageState extends ConsumerState<BookmarkEditorPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _remotePath;
  late final TextEditingController _smbShare;
  late final TextEditingController _domain;
  late TransferProtocol _protocol;
  late bool _rememberPassword;
  bool _testing = false;
  bool _saving = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _protocol = e?.protocol ?? TransferProtocol.sftp;
    _name = TextEditingController(text: e?.name ?? '');
    _host = TextEditingController(text: e?.host ?? '');
    _port = TextEditingController(
      text: '${e?.port ?? _protocol.defaultPort}',
    );
    _username = TextEditingController(text: e?.username ?? '');
    _password = TextEditingController();
    _remotePath = TextEditingController(text: e?.remotePath ?? '');
    _smbShare = TextEditingController(text: e?.smbShare ?? '');
    _domain = TextEditingController(text: e?.domain ?? '');
    _rememberPassword = e?.rememberPassword ?? true;
    if (e != null && e.rememberPassword) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final pw =
            await ref.read(bookmarkStoreProvider.notifier).readPassword(e.id);
        if (pw != null && mounted) {
          _password.text = pw;
        }
      });
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    _username.dispose();
    _password.dispose();
    _remotePath.dispose();
    _smbShare.dispose();
    _domain.dispose();
    super.dispose();
  }

  ServerBookmark _draft() {
    final id = widget.existing?.id ?? _newBookmarkId();
    return ServerBookmark(
      id: id,
      name: _name.text.trim().isEmpty ? _host.text.trim() : _name.text.trim(),
      protocol: _protocol,
      host: _host.text.trim(),
      port: int.tryParse(_port.text.trim()) ?? _protocol.defaultPort,
      username: _username.text.trim(),
      remotePath: _remotePath.text.trim(),
      smbShare: _smbShare.text.trim(),
      domain: _domain.text.trim(),
      rememberPassword: _rememberPassword,
    );
  }

  Future<void> _test() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _testing = true;
      _status = 'Testing…';
    });
    try {
      await SessionTransfer.testConnection(
        bookmark: _draft(),
        password: _password.text,
      );
      if (!mounted) return;
      setState(() => _status = 'Connection OK');
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Failed: $e');
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      await ref.read(bookmarkStoreProvider.notifier).upsert(
            _draft(),
            password: _password.text,
          );
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Save failed: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null ? 'Add bookmark' : 'Edit bookmark'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Save'),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            SegmentedButton<TransferProtocol>(
              segments: const [
                ButtonSegment(
                  value: TransferProtocol.sftp,
                  label: Text('SFTP'),
                  icon: Icon(Icons.terminal),
                ),
                ButtonSegment(
                  value: TransferProtocol.smb,
                  label: Text('SMB'),
                  icon: Icon(Icons.storage),
                ),
              ],
              selected: {_protocol},
              onSelectionChanged: (s) {
                final next = s.first;
                setState(() {
                  _protocol = next;
                  if (_port.text == '22' || _port.text == '445') {
                    _port.text = '${next.defaultPort}';
                  }
                });
              },
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Name',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _host,
              decoration: const InputDecoration(
                labelText: 'Host',
                border: OutlineInputBorder(),
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Required' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _port,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Port',
                border: OutlineInputBorder(),
              ),
              validator: (v) {
                final n = int.tryParse(v?.trim() ?? '');
                if (n == null || n <= 0) return 'Invalid port';
                return null;
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _username,
              decoration: const InputDecoration(
                labelText: 'Username',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _password,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Password',
                border: OutlineInputBorder(),
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Remember password'),
              subtitle: const Text('Stored in secure device storage'),
              value: _rememberPassword,
              onChanged: (v) => setState(() => _rememberPassword = v),
            ),
            if (_protocol == TransferProtocol.smb) ...[
              TextFormField(
                controller: _smbShare,
                decoration: const InputDecoration(
                  labelText: 'SMB share',
                  border: OutlineInputBorder(),
                ),
                validator: (v) {
                  if (_protocol != TransferProtocol.smb) return null;
                  if (v == null || v.trim().isEmpty) return 'Required for SMB';
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _domain,
                decoration: const InputDecoration(
                  labelText: 'Domain (optional)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
            ],
            TextFormField(
              controller: _remotePath,
              decoration: InputDecoration(
                labelText: _protocol == TransferProtocol.sftp
                    ? 'Remote path'
                    : 'Remote path (under share)',
                hintText: _protocol == TransferProtocol.sftp
                    ? '/home/user/emotiv'
                    : 'emotiv/recordings',
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _testing ? null : _test,
              icon: _testing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.network_check),
              label: const Text('Test connection'),
            ),
            if (_status != null) ...[
              const SizedBox(height: 12),
              Text(_status!),
            ],
          ],
        ),
      ),
    );
  }
}

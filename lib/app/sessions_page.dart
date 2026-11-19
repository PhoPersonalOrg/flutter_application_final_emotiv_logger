import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../sessions/dropbox_config.dart';
import '../sessions/server_bookmark.dart';
import '../sessions/session_library.dart';
import '../sessions/session_transfer.dart';
import 'bookmarks_page.dart';
import 'providers.dart';
import 'settings_page.dart';

String _formatStarted(DateTime? dt) {
  if (dt == null) return 'Unknown time';
  final l = dt.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${l.year}-${two(l.month)}-${two(l.day)} '
      '${two(l.hour)}:${two(l.minute)}';
}

/// Lists prior CSV sessions and transfers them via SFTP/SMB/Dropbox.
class SessionsPage extends ConsumerStatefulWidget {
  const SessionsPage({super.key});

  @override
  ConsumerState<SessionsPage> createState() => _SessionsPageState();
}

class _SessionsPageState extends ConsumerState<SessionsPage> {
  final Set<String> _selected = {};
  bool _selectMode = false;

  @override
  Widget build(BuildContext context) {
    final sessionsAsync = ref.watch(sessionListProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(_selectMode ? '${_selected.length} selected' : 'Sessions'),
        actions: [
          if (_selectMode) ...[
            IconButton(
              tooltip: 'Transfer',
              onPressed: _selected.isEmpty ? null : _transferSelected,
              icon: const Icon(Icons.upload),
            ),
            IconButton(
              tooltip: 'Delete',
              onPressed: _selected.isEmpty ? null : _deleteSelected,
              icon: const Icon(Icons.delete_outline),
            ),
            IconButton(
              tooltip: 'Cancel',
              onPressed: () => setState(() {
                _selectMode = false;
                _selected.clear();
              }),
              icon: const Icon(Icons.close),
            ),
          ] else ...[
            IconButton(
              tooltip: 'Sync All',
              onPressed: _syncAll,
              icon: const Icon(Icons.sync),
            ),
            IconButton(
              tooltip: 'Select',
              onPressed: () => setState(() => _selectMode = true),
              icon: const Icon(Icons.checklist),
            ),
            IconButton(
              tooltip: 'Bookmarks',
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const BookmarksPage(),
                  ),
                );
              },
              icon: const Icon(Icons.dns_outlined),
            ),
          ],
        ],
      ),
      body: sessionsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (sessions) {
          if (sessions.isEmpty) {
            return RefreshIndicator(
              onRefresh: () =>
                  ref.read(sessionListProvider.notifier).refresh(),
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: const [
                  SizedBox(height: 120),
                  Center(
                    child: Text(
                      'No recording sessions yet.\nConnect a headset on the Record tab.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
            );
          }

          return RefreshIndicator(
            onRefresh: () => ref.read(sessionListProvider.notifier).refresh(),
            child: ListView.builder(
              itemCount: sessions.length,
              itemBuilder: (context, i) {
                final s = sessions[i];
                final selected = _selected.contains(s.path);
                final subtitle = [
                  _formatStarted(s.startedAt),
                  s.sizeLabel,
                  if (s.isActive) 'recording',
                ].join(' · ');

                return ListTile(
                  leading: _selectMode
                      ? Checkbox(
                          value: selected,
                          onChanged: s.isActive
                              ? null
                              : (v) => _toggle(s.path, v ?? false),
                        )
                      : Icon(
                          s.isActive
                              ? Icons.fiber_manual_record
                              : Icons.folder,
                          color: s.isActive ? Colors.red : null,
                        ),
                  title: Text(s.deviceName),
                  subtitle: Text('$subtitle\n${s.folderName}'),
                  isThreeLine: true,
                  enabled: !s.isActive || !_selectMode,
                  onTap: () {
                    if (_selectMode) {
                      if (!s.isActive) _toggle(s.path, !selected);
                      return;
                    }
                    _showSessionActions(s);
                  },
                  onLongPress: () {
                    if (s.isActive) return;
                    setState(() {
                      _selectMode = true;
                      _selected.add(s.path);
                    });
                  },
                );
              },
            ),
          );
        },
      ),
    );
  }

  void _toggle(String path, bool on) {
    setState(() {
      if (on) {
        _selected.add(path);
      } else {
        _selected.remove(path);
      }
    });
  }

  Future<void> _showSessionActions(SessionRecord session) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(session.deviceName),
                subtitle: Text(session.folderName),
              ),
              ListTile(
                leading: const Icon(Icons.upload),
                title: const Text('Transfer…'),
                enabled: !session.isActive,
                onTap: () {
                  Navigator.pop(ctx);
                  setState(() {
                    _selected
                      ..clear()
                      ..add(session.path);
                  });
                  _transferSelected();
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Delete'),
                enabled: !session.isActive,
                onTap: () {
                  Navigator.pop(ctx);
                  setState(() {
                    _selected
                      ..clear()
                      ..add(session.path);
                  });
                  _deleteSelected();
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _deleteSelected() async {
    final paths = _selected.toList();
    if (paths.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete sessions?'),
        content: Text(
          'Permanently delete ${paths.length} session'
          '${paths.length == 1 ? '' : 's'} from this device?',
        ),
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
    if (ok != true || !mounted) return;

    for (final path in paths) {
      await SessionLibrary.deleteSession(path);
    }
    setState(() {
      _selected.clear();
      _selectMode = false;
    });
    await ref.read(sessionListProvider.notifier).refresh();
  }

  Future<void> _promptNoDestinations() async {
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('No transfer destinations'),
        content: const Text(
          'Connect Dropbox in Settings or add an SFTP/SMB bookmark.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'settings'),
            child: const Text('Settings'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'bookmark'),
            child: const Text('Add bookmark'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (action == 'bookmark') {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const BookmarksPage()),
      );
    } else if (action == 'settings') {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
      );
    }
  }

  /// Upload every finished session to every ready destination (Dropbox + bookmarks
  /// with a remembered password). Bookmarks without a password are reported skipped.
  Future<void> _syncAll() async {
    final sessions = ref.read(sessionListProvider).valueOrNull ?? const [];
    final paths =
        sessions.where((s) => !s.isActive).map((s) => s.path).toList();
    if (paths.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No finished sessions to sync')),
      );
      return;
    }

    final bookmarkState = await ref.read(bookmarkStoreProvider.future);
    final dropboxLinked = await ref.read(dropboxSyncProvider).isLinked();
    if (!mounted) return;

    final readyBookmarks = <({ServerBookmark bookmark, String password})>[];
    final skippedNoPassword = <String>[];
    for (final b in bookmarkState.bookmarks) {
      final password =
          await ref.read(bookmarkStoreProvider.notifier).readPassword(b.id);
      if (password != null && password.isNotEmpty) {
        readyBookmarks.add((bookmark: b, password: password));
      } else {
        skippedNoPassword.add(b.name);
      }
    }

    if (!dropboxLinked && readyBookmarks.isEmpty) {
      await _promptNoDestinations();
      return;
    }

    final destinationLines = <String>[
      if (dropboxLinked) 'Dropbox (App Folder)',
      for (final e in readyBookmarks)
        '${e.bookmark.name} (${e.bookmark.protocol.label})',
    ];
    final skippedLines = [
      for (final name in skippedNoPassword) '$name (no password)',
    ];

    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sync All'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Upload ${paths.length} session'
                '${paths.length == 1 ? '' : 's'} to:',
              ),
              const SizedBox(height: 8),
              for (final line in destinationLines) Text('• $line'),
              if (skippedLines.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text('Skipped destinations:'),
                for (final line in skippedLines) Text('• $line'),
              ],
              const SizedBox(height: 12),
              const Text(
                'Identical files already on Dropbox/SMB are skipped.',
                style: TextStyle(fontSize: 12, color: Colors.black54),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sync All'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await _runMultiDestinationSync(
      sessionPaths: paths,
      includeDropbox: dropboxLinked,
      bookmarks: readyBookmarks,
      skippedDestinations: skippedNoPassword,
    );
  }

  Future<void> _transferSelected() async {
    final paths = _selected.toList();
    if (paths.isEmpty) return;

    final bookmarkState = await ref.read(bookmarkStoreProvider.future);
    final dropboxLinked = await ref.read(dropboxSyncProvider).isLinked();
    if (!mounted) return;

    final hasBookmarks = bookmarkState.bookmarks.isNotEmpty;
    if (!hasBookmarks && !dropboxLinked) {
      await _promptNoDestinations();
      return;
    }

    ServerBookmark? chosen =
        hasBookmarks ? (bookmarkState.lastUsed ?? bookmarkState.bookmarks.first) : null;
    var password = '';
    if (chosen != null && chosen.rememberPassword) {
      password = await ref
              .read(bookmarkStoreProvider.notifier)
              .readPassword(chosen.id) ??
          '';
    }

    if (!mounted) return;
    final result = await showDialog<_TransferDialogResult>(
      context: context,
      builder: (ctx) => _TransferConfirmDialog(
        bookmarks: bookmarkState.bookmarks,
        initialBookmark: chosen,
        initialPassword: password,
        dropboxLinked: dropboxLinked,
        preferDropbox: dropboxLinked && !hasBookmarks,
        sessionCount: paths.length,
      ),
    );
    if (result == null || !mounted) return;

    if (result.useDropbox) {
      await _runDropboxTransfer(sessionPaths: paths);
      return;
    }

    final bookmark = result.bookmark!;
    await ref.read(bookmarkStoreProvider.notifier).setLastUsed(bookmark.id);
    await _runTransfer(
      bookmark: bookmark,
      password: result.password,
      sessionPaths: paths,
      rememberPassword: result.rememberPassword,
    );
  }

  Future<void> _runDropboxTransfer({required List<String> sessionPaths}) async {
    var cancelled = false;
    final progress = ValueNotifier<_SyncUiProgress>(
      const _SyncUiProgress(destination: 'Dropbox'),
    );
    final remoteRoot = ref.read(settingsProvider).dropboxRemoteRoot;

    _showTransferProgressDialog(
      title: 'Uploading to Dropbox',
      progress: progress,
      onCancel: () => cancelled = true,
    );

    String? error;
    var skippedFiles = 0;
    try {
      if (!DropboxConfig.isConfigured) {
        throw StateError('Dropbox app key not configured (see README)');
      }
      await ref.read(dropboxSyncProvider).uploadSessions(
            sessionPaths,
            remoteRoot: remoteRoot,
            isCancelled: () => cancelled,
            onProgress: (p) {
              if (p.skipped) skippedFiles++;
              progress.value = _SyncUiProgress(
                destination: 'Dropbox',
                file: p,
              );
            },
          );
    } on TransferCancelled {
      error = 'Cancelled';
    } catch (e) {
      error = '$e';
    }

    progress.dispose();
    if (mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
    if (!mounted) return;

    if (error == null && !cancelled) {
      final skipNote =
          skippedFiles > 0 ? ' ($skippedFiles identical file(s) skipped)' : '';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Uploaded ${sessionPaths.length} session'
            '${sessionPaths.length == 1 ? '' : 's'} to Dropbox$skipNote',
          ),
        ),
      );
      setState(() {
        _selected.clear();
        _selectMode = false;
      });
    } else if (error != null && error != 'Cancelled') {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Dropbox upload failed: $error')),
      );
    }
  }

  Future<void> _runTransfer({
    required ServerBookmark bookmark,
    required String password,
    required List<String> sessionPaths,
    required bool rememberPassword,
  }) async {
    if (rememberPassword) {
      await ref.read(bookmarkStoreProvider.notifier).upsert(
            bookmark.copyWith(rememberPassword: true),
            password: password,
          );
    }

    var cancelled = false;
    final progress = ValueNotifier<_SyncUiProgress>(
      _SyncUiProgress(destination: bookmark.name),
    );

    _showTransferProgressDialog(
      title: 'Transferring',
      progress: progress,
      onCancel: () => cancelled = true,
    );

    String? error;
    var skippedFiles = 0;
    try {
      await SessionTransfer.uploadSessions(
        bookmark: bookmark,
        password: password,
        sessionPaths: sessionPaths,
        isCancelled: () => cancelled,
        onProgress: (p) {
          if (p.skipped) skippedFiles++;
          progress.value = _SyncUiProgress(
            destination: bookmark.name,
            file: p,
          );
        },
      );
    } on TransferCancelled {
      error = 'Cancelled';
    } catch (e) {
      error = '$e';
    }

    progress.dispose();
    if (mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
    if (!mounted) return;

    if (error == null && !cancelled) {
      final skipNote =
          skippedFiles > 0 ? ' ($skippedFiles identical file(s) skipped)' : '';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Transferred ${sessionPaths.length} session'
            '${sessionPaths.length == 1 ? '' : 's'} to ${bookmark.name}$skipNote',
          ),
        ),
      );
      setState(() {
        _selected.clear();
        _selectMode = false;
      });
    } else if (error != null && error != 'Cancelled') {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Transfer failed: $error')),
      );
    }
  }

  Future<void> _runMultiDestinationSync({
    required List<String> sessionPaths,
    required bool includeDropbox,
    required List<({ServerBookmark bookmark, String password})> bookmarks,
    required List<String> skippedDestinations,
  }) async {
    var cancelled = false;
    final progress = ValueNotifier<_SyncUiProgress>(
      const _SyncUiProgress(destination: 'Starting…'),
    );

    _showTransferProgressDialog(
      title: 'Sync All',
      progress: progress,
      onCancel: () => cancelled = true,
    );

    final synced = <String>[];
    final failed = <String>[];
    var skippedFiles = 0;
    final remoteRoot = ref.read(settingsProvider).dropboxRemoteRoot;

    void onFileProgress(String destination, TransferProgress p) {
      if (p.skipped) skippedFiles++;
      progress.value = _SyncUiProgress(destination: destination, file: p);
    }

    if (includeDropbox && !cancelled) {
      progress.value = const _SyncUiProgress(destination: 'Dropbox');
      try {
        if (!DropboxConfig.isConfigured) {
          throw StateError('Dropbox app key not configured (see README)');
        }
        await ref.read(dropboxSyncProvider).uploadSessions(
              sessionPaths,
              remoteRoot: remoteRoot,
              isCancelled: () => cancelled,
              onProgress: (p) => onFileProgress('Dropbox', p),
            );
        synced.add('Dropbox');
      } on TransferCancelled {
        cancelled = true;
      } catch (e) {
        failed.add('Dropbox ($e)');
      }
    }

    for (final entry in bookmarks) {
      if (cancelled) break;
      final label = entry.bookmark.name;
      progress.value = _SyncUiProgress(destination: label);
      try {
        await SessionTransfer.uploadSessions(
          bookmark: entry.bookmark,
          password: entry.password,
          sessionPaths: sessionPaths,
          isCancelled: () => cancelled,
          onProgress: (p) => onFileProgress(label, p),
        );
        synced.add(label);
      } on TransferCancelled {
        cancelled = true;
        break;
      } catch (e) {
        failed.add('$label ($e)');
      }
    }

    progress.dispose();
    if (mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
    if (!mounted || cancelled) return;

    final parts = <String>[];
    if (synced.isNotEmpty) {
      parts.add('Synced to ${synced.join(', ')}');
    }
    if (skippedDestinations.isNotEmpty) {
      parts.add(
        'skipped ${skippedDestinations.join(', ')} (no password)',
      );
    }
    if (skippedFiles > 0) {
      parts.add('$skippedFiles identical file(s) already present');
    }
    if (failed.isNotEmpty) {
      parts.add('failed: ${failed.join('; ')}');
    }
    if (parts.isEmpty) {
      parts.add('Nothing to sync');
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(parts.join('; '))),
    );
  }

  void _showTransferProgressDialog({
    required String title,
    required ValueNotifier<_SyncUiProgress> progress,
    required VoidCallback onCancel,
  }) {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return ValueListenableBuilder<_SyncUiProgress>(
          valueListenable: progress,
          builder: (ctx, ui, _) {
            final p = ui.file;
            return AlertDialog(
              title: Text(title),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(ui.destination),
                  if (p == null)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text('Connecting…'),
                    )
                  else ...[
                    Text(p.sessionFolder),
                    Text(
                      p.fileName.isEmpty
                          ? 'Finishing…'
                          : p.skipped
                              ? '${p.fileName} skipped '
                                  '(${p.fileIndex}/${p.fileCount})'
                              : '${p.fileName} '
                                  '(${p.fileIndex}/${p.fileCount})',
                    ),
                    const SizedBox(height: 12),
                    LinearProgressIndicator(
                      value: p.skipped
                          ? 1
                          : (p.bytesTotal > 0 ? p.fraction : null),
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: onCancel,
                  child: const Text('Cancel'),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _SyncUiProgress {
  const _SyncUiProgress({
    required this.destination,
    this.file,
  });

  final String destination;
  final TransferProgress? file;
}

class _TransferDialogResult {
  const _TransferDialogResult.bookmark({
    required this.bookmark,
    required this.password,
    required this.rememberPassword,
  }) : useDropbox = false;

  const _TransferDialogResult.dropbox()
      : useDropbox = true,
        bookmark = null,
        password = '',
        rememberPassword = false;

  final bool useDropbox;
  final ServerBookmark? bookmark;
  final String password;
  final bool rememberPassword;
}

class _TransferConfirmDialog extends StatefulWidget {
  const _TransferConfirmDialog({
    required this.bookmarks,
    required this.initialBookmark,
    required this.initialPassword,
    required this.dropboxLinked,
    required this.preferDropbox,
    required this.sessionCount,
  });

  final List<ServerBookmark> bookmarks;
  final ServerBookmark? initialBookmark;
  final String initialPassword;
  final bool dropboxLinked;
  final bool preferDropbox;
  final int sessionCount;

  @override
  State<_TransferConfirmDialog> createState() => _TransferConfirmDialogState();
}

class _TransferConfirmDialogState extends State<_TransferConfirmDialog> {
  static const _dropboxId = '__dropbox__';

  late String _destinationId;
  ServerBookmark? _bookmark;
  late final TextEditingController _password;
  late bool _remember;

  @override
  void initState() {
    super.initState();
    if (widget.preferDropbox && widget.dropboxLinked) {
      _destinationId = _dropboxId;
      _bookmark = widget.initialBookmark;
    } else {
      _bookmark = widget.initialBookmark ?? widget.bookmarks.first;
      _destinationId = _bookmark!.id;
    }
    _password = TextEditingController(text: widget.initialPassword);
    _remember = _bookmark?.rememberPassword ?? false;
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final useDropbox = _destinationId == _dropboxId;
    return AlertDialog(
      title: Text(
        'Transfer ${widget.sessionCount} session'
        '${widget.sessionCount == 1 ? '' : 's'}',
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButtonFormField<String>(
            initialValue: _destinationId,
            decoration: const InputDecoration(
              labelText: 'Destination',
              border: OutlineInputBorder(),
            ),
            items: [
              if (widget.dropboxLinked)
                const DropdownMenuItem(
                  value: _dropboxId,
                  child: Text('Dropbox (App Folder)'),
                ),
              for (final b in widget.bookmarks)
                DropdownMenuItem(
                  value: b.id,
                  child: Text('${b.name} (${b.protocol.label})'),
                ),
            ],
            onChanged: (id) {
              if (id == null) return;
              setState(() {
                _destinationId = id;
                if (id != _dropboxId) {
                  _bookmark = widget.bookmarks.firstWhere((b) => b.id == id);
                  _remember = _bookmark!.rememberPassword;
                }
              });
            },
          ),
          if (!useDropbox) ...[
            const SizedBox(height: 12),
            TextField(
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
              value: _remember,
              onChanged: (v) => setState(() => _remember = v),
            ),
          ] else
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text(
                'Uploads into your Dropbox App Folder (see Settings for path).',
                style: TextStyle(fontSize: 12, color: Colors.black54),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (useDropbox) {
              Navigator.pop(context, const _TransferDialogResult.dropbox());
              return;
            }
            Navigator.pop(
              context,
              _TransferDialogResult.bookmark(
                bookmark: _bookmark!.copyWith(rememberPassword: _remember),
                password: _password.text,
                rememberPassword: _remember,
              ),
            );
          },
          child: const Text('Transfer'),
        ),
      ],
    );
  }
}

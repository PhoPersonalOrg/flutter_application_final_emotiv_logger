import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../sessions/background_transfer.dart';
import '../sessions/server_bookmark.dart';
import '../sessions/session_library.dart';
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

/// Lists prior CSV sessions and transfers them asynchronously via SFTP/SMB/Dropbox.
///
/// Local CSV files are always retained on device; only explicit user [Delete]
/// removes local sessions.
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
    final transferState = ref.watch(backgroundTransferProvider);

    ref.listen<BackgroundTransferState>(backgroundTransferProvider, (prev, next) {
      final report = next.lastReport;
      if (report != null && !identical(prev?.lastReport, report) && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(report.summaryLine())),
        );
      }
    });

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
      body: Column(
        children: [
          if (transferState.hasVisibleBanner)
            _BackgroundTransferBanner(state: transferState),
          Expanded(
            child: sessionsAsync.when(
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
                  onRefresh: () =>
                      ref.read(sessionListProvider.notifier).refresh(),
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
          ),
        ],
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

  /// Upload every finished session to every ready destination (Dropbox + bookmarks
  /// with a remembered password). Bookmarks without a password are reported skipped.
  Future<void> _syncAll() async {
    final sessions = ref.read(sessionListProvider).value ?? const [];
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
                'Identical files already on Dropbox/SMB are skipped. '
                'Transfers run in the background.',
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

    final notifier = ref.read(backgroundTransferProvider.notifier);
    if (dropboxLinked) {
      final remoteRoot = ref.read(settingsProvider).dropboxRemoteRoot;
      notifier.enqueueDropbox(sessionPaths: paths, remoteRoot: remoteRoot);
    }
    for (final entry in readyBookmarks) {
      notifier.enqueueBookmark(
        bookmark: entry.bookmark,
        password: entry.password,
        sessionPaths: paths,
      );
    }

    final queued = [
      if (dropboxLinked) 'Dropbox',
      ...readyBookmarks.map((e) => e.bookmark.name),
    ];
    final skipNote = skippedNoPassword.isEmpty
        ? ''
        : '; skipped ${skippedNoPassword.join(', ')} (no password)';
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Queued sync of ${paths.length} session'
          '${paths.length == 1 ? '' : 's'} to ${queued.join(', ')}$skipNote',
        ),
      ),
    );
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

    ServerBookmark? chosen = hasBookmarks
        ? (bookmarkState.lastUsed ?? bookmarkState.bookmarks.first)
        : null;
    var password = '';
    if (chosen != null && chosen.rememberPassword) {
      password =
          await ref.read(bookmarkStoreProvider.notifier).readPassword(chosen.id) ??
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

    // Exit selection mode immediately and run the upload asynchronously in the
    // background so navigation and recording are never blocked.
    setState(() {
      _selected.clear();
      _selectMode = false;
    });

    if (result.useDropbox) {
      final remoteRoot = ref.read(settingsProvider).dropboxRemoteRoot;
      ref.read(backgroundTransferProvider.notifier).enqueueDropbox(
            sessionPaths: paths,
            remoteRoot: remoteRoot,
          );
      return;
    }

    final bookmark = result.bookmark!;
    if (result.rememberPassword) {
      unawaited(
        ref.read(bookmarkStoreProvider.notifier).upsert(
              bookmark.copyWith(rememberPassword: true),
              password: result.password,
            ),
      );
    }
    unawaited(ref.read(bookmarkStoreProvider.notifier).setLastUsed(bookmark.id));
    ref.read(backgroundTransferProvider.notifier).enqueueBookmark(
          bookmark: bookmark,
          password: result.password,
          sessionPaths: paths,
        );
  }
}

class _BackgroundTransferBanner extends ConsumerWidget {
  const _BackgroundTransferBanner({required this.state});

  final BackgroundTransferState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(backgroundTransferProvider.notifier);
    if (state.isRunning) {
      final p = state.progress;
      final queuedSuffix =
          state.queuedJobs > 0 ? ' (+${state.queuedJobs} queued)' : '';
      final detail = p == null
          ? 'Connecting…'
          : (p.error != null
              ? 'Error on ${p.fileName.isEmpty ? p.sessionFolder : "${p.sessionFolder}/${p.fileName}"} — continuing…'
              : (p.fileName.isEmpty
                  ? '${p.sessionFolder} · finishing…'
                  : p.skipped
                      ? '${p.sessionFolder}/${p.fileName} skipped (${p.fileIndex}/${p.fileCount})'
                      : '${p.sessionFolder}/${p.fileName} (${p.fileIndex}/${p.fileCount})'));

      return Card(
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Uploading to ${state.activeDestination ?? "server"}$queuedSuffix',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  TextButton(
                    onPressed: notifier.cancelActive,
                    child: const Text('Cancel'),
                  ),
                ],
              ),
              Text(
                detail,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 6),
              LinearProgressIndicator(
                value: (p != null && p.bytesTotal > 0) ? p.fraction : null,
              ),
            ],
          ),
        ),
      );
    }

    final report = state.lastReport;
    if (report == null) return const SizedBox.shrink();

    final hasIssues = report.hasFailures || report.cancelled;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      color: hasIssues ? Colors.orange.shade50 : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(
                hasIssues
                    ? Icons.warning_amber_rounded
                    : Icons.check_circle_outline,
                size: 20,
                color: hasIssues
                    ? Colors.orange.shade900
                    : Colors.green.shade700,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    report.summaryLine(),
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  if (report.failures.length > 1)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        report.failures
                            .skip(1)
                            .take(2)
                            .map((f) => f.label)
                            .join('\n'),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Dismiss',
              onPressed: notifier.dismissReport,
              icon: const Icon(Icons.close, size: 18),
            ),
          ],
        ),
      ),
    );
  }
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
                'Uploads in background to your Dropbox App Folder (local files are kept).',
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
          child: const Text('Transfer in background'),
        ),
      ],
    );
  }
}

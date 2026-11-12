import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../sessions/server_bookmark.dart';
import '../sessions/session_library.dart';
import '../sessions/session_transfer.dart';
import 'bookmarks_page.dart';
import 'providers.dart';

String _formatStarted(DateTime? dt) {
  if (dt == null) return 'Unknown time';
  final l = dt.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${l.year}-${two(l.month)}-${two(l.day)} '
      '${two(l.hour)}:${two(l.minute)}';
}

/// Lists prior CSV sessions and transfers them via SFTP/SMB bookmarks.
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

  Future<void> _transferSelected() async {
    final paths = _selected.toList();
    if (paths.isEmpty) return;

    final bookmarkState = await ref.read(bookmarkStoreProvider.future);
    if (!mounted) return;

    if (bookmarkState.bookmarks.isEmpty) {
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('No server bookmarks'),
          content: const Text(
            'Add an SFTP or SMB bookmark before transferring.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Add bookmark'),
            ),
          ],
        ),
      );
      if (go == true && mounted) {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const BookmarksPage()),
        );
      }
      return;
    }

    var chosen = bookmarkState.lastUsed ?? bookmarkState.bookmarks.first;
    var password = '';
    if (chosen.rememberPassword) {
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
        initial: chosen,
        initialPassword: password,
        sessionCount: paths.length,
      ),
    );
    if (result == null || !mounted) return;

    await ref
        .read(bookmarkStoreProvider.notifier)
        .setLastUsed(result.bookmark.id);
    await _runTransfer(
      bookmark: result.bookmark,
      password: result.password,
      sessionPaths: paths,
      rememberPassword: result.rememberPassword,
    );
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
    final progress = ValueNotifier<TransferProgress?>(null);

    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return ValueListenableBuilder<TransferProgress?>(
          valueListenable: progress,
          builder: (ctx, p, _) {
            return AlertDialog(
              title: const Text('Transferring'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (p == null)
                    const Text('Connecting…')
                  else ...[
                    Text(p.sessionFolder),
                    Text(
                      p.fileName.isEmpty
                          ? 'Finishing…'
                          : '${p.fileName} (${p.fileIndex}/${p.fileCount})',
                    ),
                    const SizedBox(height: 12),
                    LinearProgressIndicator(
                      value: p.bytesTotal > 0 ? p.fraction : null,
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => cancelled = true,
                  child: const Text('Cancel'),
                ),
              ],
            );
          },
        );
      },
    );

    String? error;
    try {
      await SessionTransfer.uploadSessions(
        bookmark: bookmark,
        password: password,
        sessionPaths: sessionPaths,
        isCancelled: () => cancelled,
        onProgress: (p) => progress.value = p,
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Transferred ${sessionPaths.length} session'
            '${sessionPaths.length == 1 ? '' : 's'} to ${bookmark.name}',
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
}

class _TransferDialogResult {
  const _TransferDialogResult({
    required this.bookmark,
    required this.password,
    required this.rememberPassword,
  });

  final ServerBookmark bookmark;
  final String password;
  final bool rememberPassword;
}

class _TransferConfirmDialog extends StatefulWidget {
  const _TransferConfirmDialog({
    required this.bookmarks,
    required this.initial,
    required this.initialPassword,
    required this.sessionCount,
  });

  final List<ServerBookmark> bookmarks;
  final ServerBookmark initial;
  final String initialPassword;
  final int sessionCount;

  @override
  State<_TransferConfirmDialog> createState() => _TransferConfirmDialogState();
}

class _TransferConfirmDialogState extends State<_TransferConfirmDialog> {
  late ServerBookmark _bookmark;
  late final TextEditingController _password;
  late bool _remember;

  @override
  void initState() {
    super.initState();
    _bookmark = widget.initial;
    _password = TextEditingController(text: widget.initialPassword);
    _remember = _bookmark.rememberPassword;
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        'Transfer ${widget.sessionCount} session'
        '${widget.sessionCount == 1 ? '' : 's'}',
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButtonFormField<String>(
            initialValue: _bookmark.id,
            decoration: const InputDecoration(
              labelText: 'Bookmark',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final b in widget.bookmarks)
                DropdownMenuItem(
                  value: b.id,
                  child: Text('${b.name} (${b.protocol.label})'),
                ),
            ],
            onChanged: (id) {
              if (id == null) return;
              final next = widget.bookmarks.firstWhere((b) => b.id == id);
              setState(() {
                _bookmark = next;
                _remember = next.rememberPassword;
              });
            },
          ),
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
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.pop(
              context,
              _TransferDialogResult(
                bookmark: _bookmark.copyWith(rememberPassword: _remember),
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

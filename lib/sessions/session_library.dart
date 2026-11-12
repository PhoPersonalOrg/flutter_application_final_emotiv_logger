import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// One on-disk CSV recording session (`session_*` folder).
class SessionRecord {
  const SessionRecord({
    required this.path,
    required this.folderName,
    required this.deviceName,
    required this.startedAt,
    required this.totalBytes,
    this.isActive = false,
  });

  final String path;
  final String folderName;
  final String deviceName;
  final DateTime? startedAt;
  final int totalBytes;
  final bool isActive;

  String get sizeLabel {
    if (totalBytes < 1024) return '$totalBytes B';
    if (totalBytes < 1024 * 1024) {
      return '${(totalBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(totalBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// Discovers `session_*` folders under the configured save directory.
class SessionLibrary {
  /// Lists sessions under [saveDirectory] or app documents.
  ///
  /// When [baseDirectoryOverride] is set (tests), that path is used instead
  /// of resolving from settings / path_provider.
  static Future<List<SessionRecord>> listSessions({
    String? saveDirectory,
    String? activeSessionPath,
    String? baseDirectoryOverride,
  }) async {
    final base = await resolveBaseDirectory(
      saveDirectory: saveDirectory,
      baseDirectoryOverride: baseDirectoryOverride,
    );
    if (base == null || !await base.exists()) {
      return const [];
    }

    final active = activeSessionPath == null
        ? null
        : p.normalize(activeSessionPath);

    final entries = await base.list().toList();
    final sessions = <SessionRecord>[];

    for (final entity in entries) {
      if (entity is! Directory) continue;
      final name = p.basename(entity.path);
      if (!name.startsWith('session_')) continue;

      final metaFile = File(p.join(entity.path, 'session.json'));
      if (!await metaFile.exists()) continue;

      String deviceName = 'Unknown device';
      DateTime? startedAt;
      try {
        final raw = jsonDecode(await metaFile.readAsString());
        if (raw is Map) {
          deviceName = raw['deviceName'] as String? ?? deviceName;
          final started = raw['startedAt'] as String?;
          if (started != null) {
            startedAt = DateTime.tryParse(started);
          }
        }
      } catch (_) {
        // Keep defaults when metadata is corrupt.
      }

      final totalBytes = await _directorySize(entity);
      final normalized = p.normalize(entity.path);
      sessions.add(
        SessionRecord(
          path: entity.path,
          folderName: name,
          deviceName: deviceName,
          startedAt: startedAt,
          totalBytes: totalBytes,
          isActive: active != null && normalized == active,
        ),
      );
    }

    sessions.sort((a, b) {
      final aTime = a.startedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bTime = b.startedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bTime.compareTo(aTime);
    });
    return sessions;
  }

  static Future<Directory?> resolveBaseDirectory({
    String? saveDirectory,
    String? baseDirectoryOverride,
  }) async {
    if (baseDirectoryOverride != null && baseDirectoryOverride.isNotEmpty) {
      return Directory(baseDirectoryOverride);
    }
    final preferred =
        (saveDirectory != null && saveDirectory.isNotEmpty) ? saveDirectory : null;
    if (preferred != null) {
      final dir = Directory(preferred);
      if (await dir.exists()) return dir;
    }
    return getApplicationDocumentsDirectory();
  }

  static Future<void> deleteSession(String sessionPath) async {
    final dir = Directory(sessionPath);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  static Future<int> _directorySize(Directory dir) async {
    var total = 0;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        try {
          total += await entity.length();
        } catch (_) {}
      }
    }
    return total;
  }
}

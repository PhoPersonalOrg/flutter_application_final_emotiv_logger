import 'dart:convert';
import 'dart:typed_data';

import 'package:dropbox_client/dropbox_client.dart';
import 'package:http/http.dart' as http;

/// Dropbox content API upload_session helpers (start / append / finish).
///
/// [dropbox_client] only exposes full-file [Dropbox.upload]; live sync needs
/// byte append while CSV files grow.
class DropboxUploadSessionClient {
  DropboxUploadSessionClient({http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  final http.Client _http;

  static const _contentBase = 'https://content.dropboxapi.com/2/files';
  static const maxChunkBytes = 4 * 1024 * 1024;

  Future<String> _accessToken() async {
    final direct = await Dropbox.getAccessToken();
    if (direct != null && direct.isNotEmpty) return direct;
    final credentials = await Dropbox.getCredentials();
    if (credentials == null || credentials.isEmpty) {
      throw StateError('Dropbox not authorized');
    }
    try {
      final json = jsonDecode(credentials);
      if (json is Map && json['access_token'] is String) {
        final token = json['access_token'] as String;
        if (token.isNotEmpty) return token;
      }
    } catch (_) {}
    throw StateError('Dropbox credentials missing access_token');
  }

  /// Starts a session with [firstChunk] (may be empty). Returns session id and
  /// offset after the first chunk.
  Future<({String sessionId, int offset})> start({
    Uint8List? firstChunk,
    bool close = false,
  }) async {
    final token = await _accessToken();
    final body = firstChunk ?? Uint8List(0);
    final response = await _http.post(
      Uri.parse('$_contentBase/upload_session/start'),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/octet-stream',
        'Dropbox-API-Arg': jsonEncode({'close': close}),
      },
      body: body,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        'upload_session/start ${response.statusCode}: ${response.body}',
      );
    }
    final decoded = jsonDecode(response.body);
    final sessionId = decoded is Map ? decoded['session_id'] as String? : null;
    if (sessionId == null || sessionId.isEmpty) {
      throw StateError('upload_session/start missing session_id');
    }
    return (sessionId: sessionId, offset: body.length);
  }

  Future<int> append({
    required String sessionId,
    required int offset,
    required Uint8List data,
    bool close = false,
  }) async {
    if (data.isEmpty) return offset;
    final token = await _accessToken();
    var cursorOffset = offset;
    var start = 0;
    while (start < data.length) {
      final end = (start + maxChunkBytes < data.length)
          ? start + maxChunkBytes
          : data.length;
      final slice = Uint8List.sublistView(data, start, end);
      final isLast = end >= data.length;
      final response = await _http.post(
        Uri.parse('$_contentBase/upload_session/append_v2'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/octet-stream',
          'Dropbox-API-Arg': jsonEncode({
            'cursor': {
              'session_id': sessionId,
              'offset': cursorOffset,
            },
            'close': close && isLast,
          }),
        },
        body: slice,
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError(
          'upload_session/append_v2 ${response.statusCode}: ${response.body}',
        );
      }
      cursorOffset += slice.length;
      start = end;
    }
    return cursorOffset;
  }

  /// Commits the session to [remotePath] (App Folder path starting with `/`).
  Future<void> finish({
    required String sessionId,
    required int offset,
    required String remotePath,
    Uint8List? finalChunk,
    bool mute = true,
  }) async {
    final token = await _accessToken();
    final body = finalChunk ?? Uint8List(0);
    final response = await _http.post(
      Uri.parse('$_contentBase/upload_session/finish'),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/octet-stream',
        'Dropbox-API-Arg': jsonEncode({
          'cursor': {
            'session_id': sessionId,
            'offset': offset,
          },
          'commit': {
            'path': remotePath,
            'mode': 'overwrite',
            'autorename': false,
            'mute': mute,
          },
        }),
      },
      body: body,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        'upload_session/finish ${response.statusCode}: ${response.body}',
      );
    }
  }

  /// Full-file overwrite via a one-shot upload session (for static files).
  Future<void> uploadBytes({
    required String remotePath,
    required Uint8List data,
    bool mute = true,
  }) async {
    final started = await start(firstChunk: Uint8List(0), close: false);
    await finish(
      sessionId: started.sessionId,
      offset: 0,
      remotePath: remotePath,
      finalChunk: data,
      mute: mute,
    );
  }

  void close() {
    _http.close();
  }
}

/// Tracks one open Dropbox upload_session for a growing local file.
class DropboxGrowingUpload {
  DropboxGrowingUpload(this.client, this.remotePath);

  final DropboxUploadSessionClient client;
  final String remotePath;

  String? sessionId;
  int offset = 0;
  bool finished = false;

  Future<void> ensureStarted() async {
    if (sessionId != null) return;
    final started = await client.start();
    sessionId = started.sessionId;
    offset = started.offset;
  }

  Future<void> appendBytes(Uint8List data) async {
    if (data.isEmpty || finished) return;
    await ensureStarted();
    offset = await client.append(
      sessionId: sessionId!,
      offset: offset,
      data: data,
    );
  }

  Future<void> commit() async {
    if (finished) return;
    await ensureStarted();
    await client.finish(
      sessionId: sessionId!,
      offset: offset,
      remotePath: remotePath,
    );
    finished = true;
  }
}

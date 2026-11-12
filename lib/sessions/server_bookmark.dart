import 'dart:convert';

enum TransferProtocol { sftp, smb }

extension TransferProtocolX on TransferProtocol {
  String get storageValue => name;

  static TransferProtocol fromStorage(String? raw) {
    return switch (raw) {
      'smb' => TransferProtocol.smb,
      _ => TransferProtocol.sftp,
    };
  }

  int get defaultPort => switch (this) {
        TransferProtocol.sftp => 22,
        TransferProtocol.smb => 445,
      };

  String get label => switch (this) {
        TransferProtocol.sftp => 'SFTP',
        TransferProtocol.smb => 'SMB',
      };
}

/// Non-secret server bookmark for SFTP/SMB transfer.
class ServerBookmark {
  const ServerBookmark({
    required this.id,
    required this.name,
    required this.protocol,
    required this.host,
    required this.port,
    required this.username,
    required this.remotePath,
    this.smbShare = '',
    this.domain = '',
    this.rememberPassword = false,
  });

  final String id;
  final String name;
  final TransferProtocol protocol;
  final String host;
  final int port;
  final String username;
  final String remotePath;
  final String smbShare;
  final String domain;
  final bool rememberPassword;

  ServerBookmark copyWith({
    String? id,
    String? name,
    TransferProtocol? protocol,
    String? host,
    int? port,
    String? username,
    String? remotePath,
    String? smbShare,
    String? domain,
    bool? rememberPassword,
  }) {
    return ServerBookmark(
      id: id ?? this.id,
      name: name ?? this.name,
      protocol: protocol ?? this.protocol,
      host: host ?? this.host,
      port: port ?? this.port,
      username: username ?? this.username,
      remotePath: remotePath ?? this.remotePath,
      smbShare: smbShare ?? this.smbShare,
      domain: domain ?? this.domain,
      rememberPassword: rememberPassword ?? this.rememberPassword,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'protocol': protocol.storageValue,
        'host': host,
        'port': port,
        'username': username,
        'remotePath': remotePath,
        'smbShare': smbShare,
        'domain': domain,
        'rememberPassword': rememberPassword,
      };

  factory ServerBookmark.fromJson(Map<String, dynamic> json) {
    final protocol = TransferProtocolX.fromStorage(json['protocol'] as String?);
    return ServerBookmark(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? 'Server',
      protocol: protocol,
      host: json['host'] as String? ?? '',
      port: (json['port'] as num?)?.toInt() ?? protocol.defaultPort,
      username: json['username'] as String? ?? '',
      remotePath: json['remotePath'] as String? ?? '',
      smbShare: json['smbShare'] as String? ?? '',
      domain: json['domain'] as String? ?? '',
      rememberPassword: json['rememberPassword'] as bool? ?? false,
    );
  }

  static String encodeList(List<ServerBookmark> bookmarks) =>
      jsonEncode(bookmarks.map((b) => b.toJson()).toList());

  static List<ServerBookmark> decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    return decoded
        .whereType<Map>()
        .map((e) => ServerBookmark.fromJson(Map<String, dynamic>.from(e)))
        .where((b) => b.id.isNotEmpty)
        .toList();
  }
}

class BookmarkStoreState {
  const BookmarkStoreState({
    this.bookmarks = const [],
    this.lastUsedBookmarkId,
  });

  final List<ServerBookmark> bookmarks;
  final String? lastUsedBookmarkId;

  ServerBookmark? get lastUsed {
    if (bookmarks.isEmpty) return null;
    if (lastUsedBookmarkId != null) {
      for (final b in bookmarks) {
        if (b.id == lastUsedBookmarkId) return b;
      }
    }
    return bookmarks.first;
  }

  BookmarkStoreState copyWith({
    List<ServerBookmark>? bookmarks,
    String? lastUsedBookmarkId,
    bool clearLastUsed = false,
  }) {
    return BookmarkStoreState(
      bookmarks: bookmarks ?? this.bookmarks,
      lastUsedBookmarkId: clearLastUsed
          ? null
          : (lastUsedBookmarkId ?? this.lastUsedBookmarkId),
    );
  }
}

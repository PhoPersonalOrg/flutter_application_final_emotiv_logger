import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'server_bookmark.dart';

/// Persists bookmark metadata in SharedPreferences and passwords in
/// flutter_secure_storage (only when [ServerBookmark.rememberPassword]).
class BookmarkStore {
  BookmarkStore({
    SharedPreferences? prefs,
    FlutterSecureStorage? secureStorage,
  })  : _prefsOverride = prefs,
        _secure = secureStorage ??
            const FlutterSecureStorage(aOptions: AndroidOptions());

  final SharedPreferences? _prefsOverride;
  final FlutterSecureStorage _secure;

  static const _bookmarksKey = 'acq.v1.transferBookmarks';
  static const _lastUsedKey = 'acq.v1.transferLastUsedId';
  static const _passwordPrefix = 'acq.v1.xfer.pw.';

  Future<SharedPreferences> _prefs() async =>
      _prefsOverride ?? SharedPreferences.getInstance();

  Future<BookmarkStoreState> load() async {
    final prefs = await _prefs();
    return BookmarkStoreState(
      bookmarks: ServerBookmark.decodeList(prefs.getString(_bookmarksKey)),
      lastUsedBookmarkId: prefs.getString(_lastUsedKey),
    );
  }

  Future<void> saveState(BookmarkStoreState state) async {
    final prefs = await _prefs();
    await prefs.setString(
      _bookmarksKey,
      ServerBookmark.encodeList(state.bookmarks),
    );
    final last = state.lastUsedBookmarkId;
    if (last == null || last.isEmpty) {
      await prefs.remove(_lastUsedKey);
    } else {
      await prefs.setString(_lastUsedKey, last);
    }
  }

  Future<void> upsert(
    ServerBookmark bookmark, {
    String? password,
    required BookmarkStoreState current,
  }) async {
    final list = [...current.bookmarks];
    final idx = list.indexWhere((b) => b.id == bookmark.id);
    if (idx >= 0) {
      list[idx] = bookmark;
    } else {
      list.add(bookmark);
    }
    final next = current.copyWith(
      bookmarks: list,
      lastUsedBookmarkId: bookmark.id,
    );
    await saveState(next);

    if (bookmark.rememberPassword && password != null && password.isNotEmpty) {
      await _secure.write(key: _passwordKey(bookmark.id), value: password);
    } else {
      await _secure.delete(key: _passwordKey(bookmark.id));
    }
  }

  Future<BookmarkStoreState> delete(
    String id, {
    required BookmarkStoreState current,
  }) async {
    final list = current.bookmarks.where((b) => b.id != id).toList();
    final clearLast = current.lastUsedBookmarkId == id;
    final next = current.copyWith(
      bookmarks: list,
      lastUsedBookmarkId: clearLast
          ? (list.isNotEmpty ? list.first.id : null)
          : current.lastUsedBookmarkId,
      clearLastUsed: clearLast && list.isEmpty,
    );
    await saveState(next);
    await _secure.delete(key: _passwordKey(id));
    return next;
  }

  Future<void> setLastUsed(String id, BookmarkStoreState current) async {
    await saveState(current.copyWith(lastUsedBookmarkId: id));
  }

  Future<String?> readPassword(String bookmarkId) {
    return _secure.read(key: _passwordKey(bookmarkId));
  }

  String _passwordKey(String id) => '$_passwordPrefix$id';
}

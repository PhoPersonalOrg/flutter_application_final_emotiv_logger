import 'dart:io';

/// Custom save folders are not durable on iOS without security-scoped bookmarks.
/// Always return null there so CSV/Sessions use app Documents.
String? effectiveSaveDirectory(
  String? saveDirectory, {
  bool? isIOS,
}) {
  final ios = isIOS ?? Platform.isIOS;
  if (ios) return null;
  if (saveDirectory == null || saveDirectory.isEmpty) return null;
  return saveDirectory;
}

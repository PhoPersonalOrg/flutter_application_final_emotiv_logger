/// SMB share names must not include path separators (libsmb2 builds
/// `//{host}/{share}`; a leading `/` becomes `//host//share`).
String normalizeSmbShare(String raw) {
  var s = raw.trim().replaceAll('\\', '/');
  while (s.startsWith('/')) {
    s = s.substring(1);
  }
  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  if (s.isEmpty) return '';
  final parts = s.split('/').where((e) => e.isNotEmpty).toList();
  if (parts.isEmpty) return '';
  // Path-like input (`foo/bar` or `/foo`) → first segment only.
  return parts.first;
}

/// Share-relative remote path (no leading slash).
String normalizeSmbRemotePath(String path) {
  var s = path.trim().replaceAll('\\', '/');
  while (s.startsWith('/')) {
    s = s.substring(1);
  }
  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

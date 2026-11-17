import 'package:flutter_emotiv_logger/sessions/smb_paths.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('normalizeSmbShare', () {
    test('strips leading slash that caused //host//share', () {
      expect(normalizeSmbShare('/h'), 'h');
    });

    test('strips backslash and trailing slash', () {
      expect(normalizeSmbShare(r'\h'), 'h');
      expect(normalizeSmbShare('h/'), 'h');
      expect(normalizeSmbShare(r'\h\'), 'h');
    });

    test('keeps bare share names', () {
      expect(normalizeSmbShare('h'), 'h');
      expect(normalizeSmbShare('data'), 'data');
    });

    test('takes first segment of path-like input', () {
      expect(normalizeSmbShare('foo/bar'), 'foo');
      expect(normalizeSmbShare('/foo/bar'), 'foo');
    });

    test('empty and whitespace become empty', () {
      expect(normalizeSmbShare(''), '');
      expect(normalizeSmbShare('   '), '');
      expect(normalizeSmbShare('/'), '');
    });
  });

  group('normalizeSmbRemotePath', () {
    test('strips leading slashes for share-relative paths', () {
      expect(normalizeSmbRemotePath('/emotiv/recordings'), 'emotiv/recordings');
      expect(normalizeSmbRemotePath('emotiv'), 'emotiv');
      expect(normalizeSmbRemotePath(''), '');
    });
  });
}

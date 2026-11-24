import 'package:flutter_emotiv_logger/app/build_info.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BuildInfo.label', () {
    test('version and build number without builtAt', () {
      const info = BuildInfo(version: '1.0.1', buildNumber: '42');
      expect(info.label, '1.0.1+42');
    });

    test('omits empty build number', () {
      const info = BuildInfo(version: '1.0.1', buildNumber: '');
      expect(info.label, '1.0.1');
    });

    test('appends formatted builtAt', () {
      const info = BuildInfo(
        version: '1.0.1',
        buildNumber: '42',
        builtAt: '2026-11-19T19:03:00Z',
      );
      expect(info.label, '1.0.1+42 · 2026-11-19 19:03 UTC');
    });

    test('falls back to unknown for blank version', () {
      const info = BuildInfo(version: '  ', buildNumber: '3');
      expect(info.label, 'unknown+3');
    });
  });

  group('BuildInfo.formatBuiltAt', () {
    test('formats ISO UTC', () {
      expect(
        BuildInfo.formatBuiltAt('2026-11-19T19:03:00Z'),
        '2026-11-19 19:03 UTC',
      );
    });

    test('returns empty for blank', () {
      expect(BuildInfo.formatBuiltAt(''), '');
      expect(BuildInfo.formatBuiltAt('   '), '');
    });

    test('passes through non-ISO strings', () {
      expect(BuildInfo.formatBuiltAt('local-dev'), 'local-dev');
    });
  });
}

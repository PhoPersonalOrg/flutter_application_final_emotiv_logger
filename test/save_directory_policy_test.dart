import 'package:flutter_emotiv_logger/app/save_directory_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('effectiveSaveDirectory', () {
    test('returns null on iOS even when a custom path is set', () {
      expect(
        effectiveSaveDirectory(
          '/private/var/mobile/.../File Provider Storage/EEG',
          isIOS: true,
        ),
        isNull,
      );
    });

    test('returns null for empty or null paths', () {
      expect(effectiveSaveDirectory(null, isIOS: false), isNull);
      expect(effectiveSaveDirectory('', isIOS: false), isNull);
    });

    test('keeps custom paths on non-iOS', () {
      expect(
        effectiveSaveDirectory('/storage/emulated/0/EEG', isIOS: false),
        '/storage/emulated/0/EEG',
      );
    });
  });
}

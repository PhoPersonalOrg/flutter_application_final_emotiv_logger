import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:flutter_emotiv_logger/file_storage.dart';

class FakePathProviderPlatform extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  String? documentsPath;

  @override
  Future<String?> getApplicationDocumentsPath() async {
    return documentsPath;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FileStorage storage;
  late FakePathProviderPlatform fakePathProvider;
  late Directory tempDir;

  setUp(() async {
    storage = FileStorage();
    fakePathProvider = FakePathProviderPlatform();
    PathProviderPlatform.instance = fakePathProvider;

    tempDir = await Directory.systemTemp.createTemp('file_storage_test');
    fakePathProvider.documentsPath = tempDir.path;
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('FileStorage', () {
    test('readCounter returns 0 when file does not exist', () async {
      final counter = await storage.readCounter();
      expect(counter, 0);
    });

    test('readCounter returns correct value when file exists', () async {
      final file = File('${tempDir.path}/counter.txt');
      await file.writeAsString('42');

      final counter = await storage.readCounter();
      expect(counter, 42);
    });

    test('readCounter returns 0 when file contains invalid content', () async {
      final file = File('${tempDir.path}/counter.txt');
      await file.writeAsString('not a number');

      final counter = await storage.readCounter();
      expect(counter, 0);
    });

    test('writeCounter writes the correct value to file', () async {
      await storage.writeCounter(123);

      final file = File('${tempDir.path}/counter.txt');
      final contents = await file.readAsString();
      expect(contents, '123');
    });

    test('readCounter returns the value written by writeCounter', () async {
      await storage.writeCounter(99);
      final counter = await storage.readCounter();
      expect(counter, 99);
    });
  });
}

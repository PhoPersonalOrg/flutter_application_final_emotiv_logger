import 'dart:io';
import 'dart:async';
import 'package:path_provider/path_provider.dart';


class FileStorage {
  Future<String>? _cachedLocalPath;

  Future<String> get _localPath {
    _cachedLocalPath ??= getApplicationDocumentsDirectory().then((dir) => dir.path);
    return _cachedLocalPath!;
  }

  Future<File> get _localFile async {
	final path = await _localPath;
	return File('$path/counter.txt');
  }

  Future<int> readCounter() async {
	try {
	  final file = await _localFile;

	  // Read the file
	  final contents = await file.readAsString();

	  return int.parse(contents);
	} catch (e) {
	  // If encountering an error, return 0
	  return 0;
	}
  }

  Future<File> writeCounter(int counter) async {
	final file = await _localFile;

	// Write the file
	return file.writeAsString('$counter');
  }

}

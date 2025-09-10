import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';

class GenericFileWriter {
  File? _dataFile;
  IOSink? _dataSink;
  Timer? _flushTimer;
  final List<String> _writeBuffer = [];

  String _headerLine = 'timestamp,*raw*';
  static const int _bufferSize = 100; // Buffer before writing
  static const int _flushIntervalMs = 3000; // Flush every second

  bool _isInitialized = false;
  bool _isDisposed = false;

  final Function(String)? onStatusUpdate;
  final String? customDirectoryPath;

  GenericFileWriter({
    this.onStatusUpdate,
    this.customDirectoryPath,
  });

  Future<bool> initialize() async {
    if (_isInitialized || _isDisposed) return false;

    try {
      // Determine base directory (custom or app documents)
      Directory baseDirectory;
      if (customDirectoryPath != null && customDirectoryPath!.isNotEmpty) {
        baseDirectory = Directory(customDirectoryPath!);
      } else {
        baseDirectory = await getApplicationDocumentsDirectory();
      }

      // Create MOTION_RECORDINGS subfolder
      final Directory dataDir =
          Directory('${baseDirectory.path}/GENERIC_RECORDINGS');
      if (!await dataDir.exists()) {
        try {
          await dataDir.create(recursive: true);
          _updateStatus('Created generic directory: ${dataDir.path}');
        } catch (e) {
          _updateStatus('Error creating generic directory: $e');
          return false;
        }
      }
      // Create file
      final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
      final fileName = 'generic_data_$timestamp.csv';
      _dataFile = File('${dataDir.path}/$fileName');

      // Test write
      try {
        await _dataFile!.writeAsString('timestamp,test\n');
      } catch (e) {
        _updateStatus('Generic test write failed: $e');
        return false;
      }

      _dataSink = _dataFile!.openWrite();
      // Header: timestamp, Acc + Gyro
      _dataSink!.writeln(_headerLine);

      // Periodic flush
      _flushTimer = Timer.periodic(
        const Duration(milliseconds: _flushIntervalMs),
        (_) async => _flushBuffer(),
      );

      _isInitialized = true;
      _updateStatus(
        'Generic file writer initialized: $fileName in ${dataDir.path}',
      );
      return true;
    } catch (e) {
      _updateStatus('Error initializing generic file writer: $e');
      return false;
    }
  }

  void writeGenericData(Uint8List genericData) {
    if (!_isInitialized || _isDisposed || _dataSink == null) return;
    try {
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final csvLine = '$timestamp,${genericData.join(',')}';
      _writeBuffer.add(csvLine);
      if (_writeBuffer.length >= _bufferSize) {
        _flushBuffer();
      }
    } catch (e) {
      _updateStatus('Error writing generic data: $e');
    }
  }

  Future<void> _flushBuffer() async {
    if (_dataSink == null || _writeBuffer.isEmpty || _isDisposed) return;
    final local = List<String>.from(_writeBuffer);
    _writeBuffer.clear();
    try {
      _dataSink!.writeAll(local, '\n');
      _dataSink!.writeln();
      await _dataSink!.flush();
    } catch (e) {
      _updateStatus('Error flushing generic buffer: $e');
      _flushTimer?.cancel();
      _flushTimer = null;
    }
  }

  Future<void> flush() async {
    if (!_isDisposed) {
      await _flushBuffer();
    }
  }

  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    try {
      _flushTimer?.cancel();
      _flushTimer = null;
      if (_dataSink != null && _writeBuffer.isNotEmpty) {
        await _flushBuffer();
      }
      if (_dataSink != null) {
        try {
          await _dataSink!.close();
        } catch (e) {
          _updateStatus('Error closing generic sink: $e');
        }
        _dataSink = null;
      }
      _dataFile = null;
      _writeBuffer.clear();
      _isInitialized = false;
      _updateStatus('Generic file writer closed');
    } catch (e) {
      _updateStatus('Error closing generic file writer: $e');
      _dataSink = null;
      _dataFile = null;
      _writeBuffer.clear();
      _isInitialized = false;
    }
  }

  String? get filePath => _dataFile?.path;
  bool get isInitialized => _isInitialized && !_isDisposed;

  void _updateStatus(String status) {
    // print for debug and callback
    // ignore: avoid_print
    print('GenericFileWriter: $status');
    onStatusUpdate?.call(status);
  }
}



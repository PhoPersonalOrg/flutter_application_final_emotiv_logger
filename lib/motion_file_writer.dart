import 'dart:async';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

class MotionFileWriter {
  File? _motionDataFile;
  IOSink? _motionDataSink;
  Timer? _flushTimer;
  final List<String> _writeBuffer = [];

  static const int _bufferSize = 100; // Buffer before writing
  static const int _flushIntervalMs = 1000; // Flush every second

  bool _isInitialized = false;
  bool _isDisposed = false;

  final Function(String)? onStatusUpdate;
  final String? customDirectoryPath;

  MotionFileWriter({
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
      final Directory motionDir =
          Directory('${baseDirectory.path}/MOTION_RECORDINGS');
      if (!await motionDir.exists()) {
        try {
          await motionDir.create(recursive: true);
          _updateStatus('Created motion directory: ${motionDir.path}');
        } catch (e) {
          _updateStatus('Error creating motion directory: $e');
          return false;
        }
      }

      // Create file
      final timestamp =
          DateTime.now().toIso8601String().replaceAll(':', '-');
      final fileName = 'motion_data_$timestamp.csv';
      _motionDataFile = File('${motionDir.path}/$fileName');

      // Test write
      try {
        await _motionDataFile!.writeAsString('timestamp,test\n');
      } catch (e) {
        _updateStatus('Motion test write failed: $e');
        return false;
      }

      _motionDataSink = _motionDataFile!.openWrite();
      // Header: timestamp, Acc + Gyro
      _motionDataSink!
          .writeln('timestamp,AccX,AccY,AccZ,GyroX,GyroY,GyroZ');

      // Periodic flush
      _flushTimer = Timer.periodic(
        const Duration(milliseconds: _flushIntervalMs),
        (_) async => _flushBuffer(),
      );

      _isInitialized = true;
      _updateStatus(
        'Motion file writer initialized: $fileName in ${motionDir.path}',
      );
      return true;
    } catch (e) {
      _updateStatus('Error initializing motion file writer: $e');
      return false;
    }
  }

  void writeMotionData(List<double> motionData) {
    if (!_isInitialized || _isDisposed || _motionDataSink == null) return;
    try {
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final csvLine = '$timestamp,${motionData.join(',')}';
      _writeBuffer.add(csvLine);
      if (_writeBuffer.length >= _bufferSize) {
        _flushBuffer();
      }
    } catch (e) {
      _updateStatus('Error writing motion data: $e');
    }
  }

  Future<void> _flushBuffer() async {
    if (_motionDataSink == null || _writeBuffer.isEmpty || _isDisposed) return;
    final local = List<String>.from(_writeBuffer);
    _writeBuffer.clear();
    try {
      _motionDataSink!.writeAll(local, '\n');
      _motionDataSink!.writeln();
      await _motionDataSink!.flush();
    } catch (e) {
      _updateStatus('Error flushing motion buffer: $e');
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
      if (_motionDataSink != null && _writeBuffer.isNotEmpty) {
        await _flushBuffer();
      }
      if (_motionDataSink != null) {
        try {
          await _motionDataSink!.close();
        } catch (e) {
          _updateStatus('Error closing motion sink: $e');
        }
        _motionDataSink = null;
      }
      _motionDataFile = null;
      _writeBuffer.clear();
      _isInitialized = false;
      _updateStatus('Motion file writer closed');
    } catch (e) {
      _updateStatus('Error closing motion file writer: $e');
      _motionDataSink = null;
      _motionDataFile = null;
      _writeBuffer.clear();
      _isInitialized = false;
    }
  }

  String? get filePath => _motionDataFile?.path;
  bool get isInitialized => _isInitialized && !_isDisposed;

  void _updateStatus(String status) {
    // print for debug and callback
    // ignore: avoid_print
    print('MotionFileWriter: $status');
    onStatusUpdate?.call(status);
  }
}



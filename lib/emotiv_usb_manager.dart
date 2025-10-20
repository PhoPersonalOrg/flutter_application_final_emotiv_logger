import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:lsl_flutter/lsl_flutter.dart';
import 'crypto_utils.dart';
import 'eeg_file_writer.dart';
import 'motion_file_writer.dart';
import 'generic_file_writer.dart';

// NOTE: This implementation targets Windows first.
// It mirrors the public API shape of EmotivBLEManager to minimize UI changes.
// The underlying HID plugin API names can vary; adjust open/enumerate calls as needed.

class EmotivUSBManager {
  static const int readSize = 32;

  // Streams
  final StreamController<List<double>> _eegDataController = StreamController<List<double>>.broadcast();
  final StreamController<List<double>> _motionDataController = StreamController<List<double>>.broadcast();
  final StreamController<bool> _connectionController = StreamController<bool>.broadcast();
  final StreamController<String> _statusController = StreamController<String>.broadcast();
  final StreamController<List<String>> _foundDevicesController = StreamController<List<String>>.broadcast();

  Stream<List<double>> get eegDataStream => _eegDataController.stream;
  Stream<List<double>> get motionDataStream => _motionDataController.stream;
  Stream<bool> get connectionStream => _connectionController.stream;
  Stream<String> get statusStream => _statusController.stream;
  Stream<List<String>> get foundDevicesStream => _foundDevicesController.stream;

  bool _isConnected = false;
  bool _isEnumerating = false;
  bool get isConnected => _isConnected;
  bool get isScanning => _isEnumerating; // to match BLE naming in UI

  // HID device handle (keep dynamic to avoid tight coupling with plugin types)
  dynamic _hidDevice;
  List<dynamic> _enumeratedInfos = [];

  // Derived key from HID serial
  Uint8List? _derivedKeyBytes;
  String? serialNumber;

  // File writers
  EEGFileWriter? _eegFileWriter;
  MotionFileWriter? _motionFileWriter;
  GenericFileWriter? _rawFileWriter;
  String? _customSaveDirectory;

  // LSL
  OutletWorker? _lslWorker;
  StreamInfo? _eegStreamInfo;
  StreamInfo? _motionStreamInfo;
  bool _lslInitialized = false;

  void setCustomSaveDirectory(String? directoryPath) {
    _customSaveDirectory = directoryPath;
  }

  Future<bool> _initializeLSLOutlet() async {
    try {
      if (_lslInitialized) {
        _updateStatus("LSL outlet already initialized");
        return true;
      }
      final deviceId = serialNumber ?? "emotiv_usb_unknown";
      _eegStreamInfo = StreamInfoFactory.createDoubleStreamInfo(
        "Epoc X",
        "EEG",
        Float32ChannelFormat(),
        channelCount: 14,
        nominalSRate: 128.0,
        sourceId: deviceId,
      );
      _lslWorker = await OutletWorker.spawn();
      final eegAdded = await _lslWorker!.addStream(_eegStreamInfo!);

      _motionStreamInfo = StreamInfoFactory.createDoubleStreamInfo(
        "Epoc X Motion",
        "Accelerometer",
        Float32ChannelFormat(),
        channelCount: 6,
        nominalSRate: 16.0,
        sourceId: deviceId,
      );
      final motionAdded = await _lslWorker!.addStream(_motionStreamInfo!);

      if (eegAdded && motionAdded) {
        _lslInitialized = true;
        _updateStatus("LSL outlet initialized successfully");
        return true;
      }
      _updateStatus("Failed to add LSL streams");
      return false;
    } catch (e) {
      _updateStatus("Error initializing LSL outlet: $e");
      return false;
    }
  }

  Future<bool> _pushToLSL(List<double> sample) async {
    if (!_lslInitialized || _lslWorker == null || _eegStreamInfo == null) {
      return false;
    }
    try {
      await _lslWorker!.pushSample("Epoc X", sample);
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<bool> _pushMotionToLSL(List<double> sample) async {
    if (!_lslInitialized || _lslWorker == null || _motionStreamInfo == null) {
      return false;
    }
    try {
      await _lslWorker!.pushSample("Epoc X Motion", sample);
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<void> _initializeFileWriters() async {
    try {
      await _eegFileWriter?.dispose();
      _eegFileWriter = EEGFileWriter(onStatusUpdate: _updateStatus, customDirectoryPath: _customSaveDirectory);
      final ok = await _eegFileWriter!.initialize();
      if (!ok) {
        _updateStatus("USB: Failed to initialize EEG file writer");
        _eegFileWriter = null;
      }
    } catch (e) {
      _updateStatus("USB: Error initializing EEG file writer: $e");
      _eegFileWriter = null;
    }

    try {
      await _motionFileWriter?.dispose();
      _motionFileWriter = MotionFileWriter(onStatusUpdate: _updateStatus, customDirectoryPath: _customSaveDirectory);
      final ok = await _motionFileWriter!.initialize();
      if (!ok) {
        _updateStatus("USB: Failed to initialize motion file writer");
        _motionFileWriter = null;
      }
    } catch (e) {
      _updateStatus("USB: Error initializing motion file writer: $e");
      _motionFileWriter = null;
    }

    try {
      await _rawFileWriter?.dispose();
      _rawFileWriter = GenericFileWriter(onStatusUpdate: _updateStatus, customDirectoryPath: _customSaveDirectory);
      final ok = await _rawFileWriter!.initialize();
      if (!ok) {
        _updateStatus("USB: Failed to initialize raw file writer");
        _rawFileWriter = null;
      }
    } catch (e) {
      _updateStatus("USB: Error initializing raw file writer: $e");
      _rawFileWriter = null;
    }
  }

  Future<void> startScanning() async {
    if (!Platform.isWindows) {
      _updateStatus("USB not available on this platform");
      return;
    }
    if (_isEnumerating) return;
    _isEnumerating = true;
    _updateStatus("USB: Enumerating HID devices...");

    try {
      // Best-effort API usage; adjust per actual hid plugin.
      // Expect enumeration to return a list of device info maps or typed objects.
      final List<dynamic> devices = await _hidEnumerate();
      _enumeratedInfos = devices;

      final names = <String>[];
      for (final info in devices) {
        final manufacturer = _getField(info, ['manufacturerString', 'manufacturer_string', 'manufacturer'])?.toString() ?? '';
        final product = _getField(info, ['productString', 'product_string', 'product'])?.toString() ?? '';
        if (manufacturer.toLowerCase().contains('emotiv') || product.toLowerCase().contains('emotiv')) {
          final serial = _getField(info, ['serialNumber', 'serial_number'])?.toString() ?? '';
          final label = product.isNotEmpty ? product : 'Emotiv Receiver';
          names.add(serial.isNotEmpty ? "$label ($serial)" : label);
        }
      }
      _foundDevicesController.add(names);
    } catch (e) {
      _updateStatus("USB enumerate error: $e");
    } finally {
      _isEnumerating = false;
    }
  }

  Future<void> stopScanning() async {
    _isEnumerating = false;
    _updateStatus("USB: Stopped enumerating");
  }

  Future<void> connectToDeviceByName(String deviceName) async {
    try {
      // Re-find matching info
      dynamic info;
      for (final d in _enumeratedInfos) {
        final product = _getField(d, ['productString', 'product_string', 'product'])?.toString() ?? '';
        if (product == deviceName || deviceName.startsWith(product)) {
          info = d;
          break;
        }
      }
      info ??= _enumeratedInfos.isNotEmpty ? _enumeratedInfos.first : null;
      if (info == null) {
        throw Exception('Device not found: $deviceName');
      }

      await _openDevice(info);

      // Serial → key
      final serial = _getField(info, ['serialNumber', 'serial_number'])?.toString() ?? '';
      serialNumber = serial;
      _derivedKeyBytes = CryptoUtils.deriveKeyFromUsbSerial(serial);

      await _initializeFileWriters();
      await _initializeLSLOutlet();

      _isConnected = true;
      _connectionController.add(true);
      _updateStatus("USB: Connected to $deviceName");

      _startReadLoop();
    } catch (e) {
      _updateStatus("USB connect failed: $e");
      _isConnected = false;
      _connectionController.add(false);
      await disconnect();
    }
  }

  Future<void> disconnect() async {
    try {
      if (_hidDevice != null) {
        try { await _hidDevice.close(); } catch (_) {}
        _hidDevice = null;
      }
      await _closeFileWriters();
      await _closeLSLOutlet();
    } finally {
      _isConnected = false;
      _connectionController.add(false);
      _updateStatus("USB: Disconnected");
    }
  }

  void dispose() {
    _closeFileWriters();
    _closeLSLOutlet();
    _eegDataController.close();
    _motionDataController.close();
    _connectionController.close();
    _statusController.close();
    _foundDevicesController.close();
  }

  Future<void> flushFileBuffer() async {
    await _eegFileWriter?.flush();
    await _motionFileWriter?.flush();
    await _rawFileWriter?.flush();
  }

  // Internal helpers
  void _startReadLoop() {
    // Read 32-byte reports repeatedly on a periodic timer
    Timer.periodic(const Duration(milliseconds: 5), (timer) async {
      if (!_isConnected || _hidDevice == null) {
        timer.cancel();
        return;
      }
      try {
        final data = await _readReport(readSize);
        if (data == null || data.isEmpty) return;
        _processRawData(data);
        _processPacket(Uint8List.fromList(data));
      } catch (e) {
        _updateStatus("USB read error: $e");
      }
    });
  }

  void _processRawData(List<int> data) {
    _rawFileWriter?.writeGenericData(data);
  }

  void _processPacket(Uint8List data) {
    if (!_validateData(data)) return;
    final keyBytes = _derivedKeyBytes;
    if (keyBytes == null) return;

    // Decrypt EEG values assuming Epoc X mapping (XOR + AES), 14 EEG channels
    final decodedValues = CryptoUtils.decryptToDoubleListWithKeyBytes(keyBytes, data);
    if (decodedValues.isNotEmpty) {
      _eegDataController.add(decodedValues);
      _eegFileWriter?.writeEEGData(decodedValues);
      _pushToLSL(decodedValues);
      return;
    }

    // Attempt motion decode when EEG not parsed
    final motionValues = CryptoUtils.decodeMotionData(data);
    if (motionValues.isNotEmpty && motionValues.any((v) => v != 0.0)) {
      _motionDataController.add(motionValues);
      _motionFileWriter?.writeMotionData(motionValues);
      _pushMotionToLSL(motionValues);
    }
  }

  bool _validateData(Uint8List data) {
    if (data.length < readSize) {
      _updateStatus("USB: Data size too small: ${data.length}, expected: $readSize");
      return false;
    }
    return true;
  }

  Future<void> _closeFileWriters() async {
    if (_eegFileWriter != null) {
      await _eegFileWriter!.dispose();
      _eegFileWriter = null;
    }
    if (_motionFileWriter != null) {
      await _motionFileWriter!.dispose();
      _motionFileWriter = null;
    }
    if (_rawFileWriter != null) {
      await _rawFileWriter!.dispose();
      _rawFileWriter = null;
    }
  }

  Future<void> _closeLSLOutlet() async {
    try {
      if (_lslWorker != null) {
        if (_eegStreamInfo != null) await _lslWorker!.removeStream("Epoc X");
        if (_motionStreamInfo != null) await _lslWorker!.removeStream("Epoc X Motion");
        _lslWorker = null;
      }
      _eegStreamInfo = null;
      _motionStreamInfo = null;
      _lslInitialized = false;
      _updateStatus("USB: LSL outlet closed");
    } catch (e) {
      _updateStatus("USB: Error closing LSL outlet: $e");
    }
  }

  void _updateStatus(String status) {
    _statusController.add(status);
  }

  // HID glue (best-effort; adjust to actual hid plugin):
  Future<List<dynamic>> _hidEnumerate() async {
    // Try common static calls; fall back to platform channel if needed
    try {
      // Example API shape: await hid.enumerate(); returning list of maps/objects
      // ignore: undefined_identifier
      final result = await (await _hid()).enumerate();
      return List<dynamic>.from(result);
    } catch (_) {
      return <dynamic>[];
    }
  }

  Future<void> _openDevice(dynamic info) async {
    try {
      // Prefer opening by path when available
      final path = _getField(info, ['path'])?.toString();
      if (path != null && path.isNotEmpty) {
        // ignore: undefined_identifier
        _hidDevice = await (await _hid()).openPath(path);
        return;
      }
      final vid = int.tryParse((_getField(info, ['vendorId', 'vendor_id']) ?? '').toString()) ?? 0;
      final pid = int.tryParse((_getField(info, ['productId', 'product_id']) ?? '').toString()) ?? 0;
      final serial = _getField(info, ['serialNumber', 'serial_number'])?.toString();
      // ignore: undefined_identifier
      _hidDevice = await (await _hid()).open(vid: vid, pid: pid, serialNumber: serial);
    } catch (e) {
      rethrow;
    }
  }

  Future<List<int>?> _readReport(int len) async {
    try {
      if (_hidDevice == null) return null;
      // Example API: await device.read(len, timeoutMs: 5)
      final data = await _hidDevice.read(len, timeoutMs: 5);
      if (data is Uint8List) return data.toList();
      if (data is List<int>) return data;
      return null;
    } catch (e) {
      return null;
    }
  }

  dynamic _getField(dynamic info, List<String> keys) {
    try {
      for (final k in keys) {
        if (info is Map && info.containsKey(k)) return info[k];
        if (info != null && info.toString().contains(k)) {
          try { return info.__getattribute__(k); } catch (_) {}
        }
      }
    } catch (_) {}
    return null;
  }

  // Lazy load hid singleton if plugin exposes it this way
  Future<dynamic> _hid() async {
    // This is a placeholder accessor for the HID plugin entry point.
    // Replace with actual import and class (e.g., `Hid()` from 'package:hid/hid.dart').
    throw UnimplementedError('HID plugin access not wired yet');
  }
}



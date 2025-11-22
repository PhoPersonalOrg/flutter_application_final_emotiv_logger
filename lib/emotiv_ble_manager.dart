import 'dart:async';
import 'dart:typed_data';
import 'dart:io';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_emotiv_logger/generic_file_writer.dart';
import 'package:lsl_flutter/lsl_flutter.dart';
import 'crypto_utils.dart';
import 'eeg_file_writer.dart';
import 'motion_file_writer.dart';
import 'services/network_streamer.dart';
import 'settings/app_settings.dart';

class EmotivBLEManager {
  // TODO: get the device serial number dynamically upon connection using the following code:
  // self.serial_number = bytes(("\x00" * 12),'utf-8') + bytearray.fromhex(str(BT_key[6:8] + BT_key[4:6] + BT_key[2:4] + BT_key[0:2]))

  // UUIDs from your Swift code
  static const String controlUuid = "81072F40-9F3D-11E3-A9DC-0002A5D5C51B";
  static const String eegDataUuid =
      "81072F41-9F3D-11E3-A9DC-0002A5D5C51B"; // UUID of the main data stream with ID 0x10
  static const String motionDataUuid =
      "81072F42-9F3D-11E3-A9DC-0002A5D5C51B"; // UUID of the gyro/other? data stream with ID 0x20

  // service.characteristics[0].uuid.toString().toUpperCase()
  // "2A00"
  // service.characteristics[1].uuid.toString().toUpperCase()
  // "2A01"
  // service.characteristics[2].uuid.toString().toUpperCase()
  // "2A04"
  // service.characteristics[3].uuid.toString().toUpperCase()
  // "2AA6"

  static const int readSize = 32;

  BluetoothDevice? _emotivDevice;
  // control characteristic (0x40)
  // BluetoothCharacteristic? _controlCharacteristic;

  // data characteristics
  BluetoothCharacteristic? _eegDataCharacteristic; // 0x41
  BluetoothCharacteristic? _motionDataCharacteristic; // 0x42

  final bool _shouldAutoConnectToFirst = false;
  String? btleDeviceName;
  // Uint8List? serialNumber;
  String? serialNumber;
  Uint8List? _derivedKeyBytes;
  bool _isConnected = false;
  bool _isScanning = false;

  // Add this field to store discovered devices
  List<BluetoothDevice> _discoveredDevices = [];

  // Stream controllers for data
  final StreamController<List<double>> _eegDataController =
      StreamController<List<double>>.broadcast();
  final StreamController<List<double>> _motionDataController =
      StreamController<List<double>>.broadcast();
  final StreamController<bool> _connectionController =
      StreamController<bool>.broadcast();
  final StreamController<String> _statusController =
      StreamController<String>.broadcast();
  // Add a stream controller for found devices
  final StreamController<List<String>> _foundDevicesController =
      StreamController<List<String>>.broadcast();
  final StreamController<NetworkStreamStatus> _networkStatusController =
      StreamController<NetworkStreamStatus>.broadcast();

  // File writer instance
  EEGFileWriter? _eegFileWriter;
  MotionFileWriter? _motionFileWriter;
  GenericFileWriter? _rawFileWriter;

  // LSL outlet components
  OutletWorker? _lslWorker;
  StreamInfo? _eegStreamInfo;
  StreamInfo? _motionStreamInfo;
  bool _lslInitialized = false;

  // Add this field
  String? _customSaveDirectory;
  AppSettings _appSettings = const AppSettings();
  NetworkStreamer? _networkStreamer;
  StreamSubscription<NetworkStreamStatus>? _networkStatusSubscription;

  // Getters for streams
  Stream<List<double>> get eegDataStream => _eegDataController.stream;
  Stream<List<double>> get motionDataStream => _motionDataController.stream;
  Stream<bool> get connectionStream => _connectionController.stream;
  Stream<String> get statusStream => _statusController.stream;
  Stream<List<String>> get foundDevicesStream => _foundDevicesController.stream;
  Stream<NetworkStreamStatus> get networkStatusStream =>
      _networkStatusController.stream;

  bool get isConnected => _isConnected;
  bool get isScanning => _isScanning;
  //   bool get serialNumber => _serialNumber;

  // Add method to set custom directory
  void setCustomSaveDirectory(String? directoryPath) {
    print(
      "EmotivBLEManager: Updating custom save directory directoryPath: $directoryPath",
    );
    _customSaveDirectory = directoryPath;
  }

  Future<void> updateAppSettings(AppSettings settings) async {
    _appSettings = settings;

    if (!settings.useNetworkStream) {
      await _teardownNetworkStreamer();
      return;
    }

    final needsNewStreamer =
        _networkStreamer == null ||
        !_networkStreamer!.matchesDestination(
          otherHost: settings.networkHost,
          otherPort: settings.networkPort,
          otherProtocol: settings.networkProtocol,
        );

    if (needsNewStreamer) {
      await _teardownNetworkStreamer();
      _networkStreamer = NetworkStreamer(
        host: settings.networkHost,
        port: settings.networkPort,
        protocol: settings.networkProtocol,
        deviceId: serialNumber,
      );
      _networkStatusSubscription = _networkStreamer!.statusStream.listen(
        _networkStatusController.add,
      );
    } else {
      _networkStreamer?.updateDeviceId(serialNumber);
    }

    try {
      await _networkStreamer?.start();
    } catch (_) {
      // Status stream already notified listeners; swallow to avoid crashes.
    }
  }

  Future<void> _teardownNetworkStreamer() async {
    await _networkStatusSubscription?.cancel();
    _networkStatusSubscription = null;
    if (_networkStreamer != null) {
      await _networkStreamer!.dispose();
      _networkStreamer = null;
    }
    if (!_networkStatusController.isClosed) {
      _networkStatusController.add(NetworkStreamStatus.disabled());
    }
  }

  // Initialize LSL outlet for EEG data streaming
  Future<bool> _initializeLSLOutlet() async {
    try {
      if (_lslInitialized) {
        _updateStatus("LSL outlet already initialized");
        return true;
      }

      // Create EEG stream info - determine channels from Emotiv data
      // Based on the crypto_utils processing, each 16-byte chunk produces 8 values
      final deviceId = _emotivDevice?.remoteId.toString() ?? "emotiv_unknown";

      _eegStreamInfo = StreamInfoFactory.createDoubleStreamInfo(
        "Epoc X",
        "EEG",
        Float32ChannelFormat(),
        channelCount: 14, // 8 EEG channels from decrypted data
        nominalSRate: 128.0, // Emotiv typically runs at 128 Hz
        sourceId: deviceId,
      );

      // Spawn LSL worker
      _lslWorker = await OutletWorker.spawn();

      // Add the stream
      final eegAdded = await _lslWorker!.addStream(_eegStreamInfo!);

      // Motion stream info (6 channels @ ~16 Hz)
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
      } else {
        _updateStatus("Failed to add LSL streams");
        return false;
      }
    } catch (e) {
      _updateStatus("Error initializing LSL outlet: $e");
      return false;
    }
  }

  // Push sample data to LSL stream safely
  Future<bool> _pushToLSL(List<double> sample) async {
    if (!_lslInitialized || _lslWorker == null || _eegStreamInfo == null) {
      return false;
    }

    try {
      await _lslWorker!.pushSample("Epoc X", sample);
      return true;
    } catch (e) {
      print("LSL push error: $e");
      return false;
    }
  }

  // Push motion samples to LSL
  Future<bool> _pushMotionToLSL(List<double> sample) async {
    if (!_lslInitialized || _lslWorker == null || _motionStreamInfo == null) {
      return false;
    }

    try {
      await _lslWorker!.pushSample("Epoc X Motion", sample);
      return true;
    } catch (e) {
      print("LSL motion push error: $e");
      return false;
    }
  }

  Future<void> _initializeFileWriter() async {
    try {
      // Dispose existing file writer if any
      await _eegFileWriter?.dispose();

      // Create new file writer with custom directory
      _eegFileWriter = EEGFileWriter(
        onStatusUpdate: _updateStatus,
        customDirectoryPath: _customSaveDirectory, // Pass custom directory
      );
      // Initialize the file writer
      final success = await _eegFileWriter!.initialize();

      if (!success) {
        _updateStatus("EmotivBLEManager: Failed to initialize EEG file writer");
        _eegFileWriter = null;
      }
    } catch (e) {
      _updateStatus("EmotivBLEManager: Error initializing EEG file writer: $e");
      _eegFileWriter = null;
    }

    try {
      // Dispose existing file writer if any
      await _motionFileWriter?.dispose();

      // Create motion writer in MOTION_RECORDINGS subfolder of same base path
      _motionFileWriter = MotionFileWriter(
        onStatusUpdate: _updateStatus,
        customDirectoryPath: _customSaveDirectory,
      );

      // Initialize the file writer
      final motionSuccess = await _motionFileWriter!.initialize();

      if (!motionSuccess) {
        _updateStatus(
          "EmotivBLEManager: Failed to initialize motion file writer",
        );
        _motionFileWriter = null;
      }
    } catch (e) {
      _updateStatus(
        "EmotivBLEManager: Error initializing motion file writer: $e",
      );
      _motionFileWriter = null;
    }

    try {
      // Dispose existing file writer if any
      await _rawFileWriter?.dispose();

      _rawFileWriter = GenericFileWriter(
        onStatusUpdate: _updateStatus,
        customDirectoryPath: _customSaveDirectory,
      );

      // Initialize the file writer
      final rawSuccess = await _rawFileWriter!.initialize();

      if (!rawSuccess) {
        _updateStatus("EmotivBLEManager: Failed to initialize raw file writer");
        _rawFileWriter = null;
      }
    } catch (e) {
      _updateStatus("EmotivBLEManager: Error initializing raw file writer: $e");
      _rawFileWriter = null;
    }
  }

  Future<void> startScanning() async {
    if (_isScanning) return;

    _isScanning = true;
    _updateStatus("EmotivBLEManager: Starting scan for Emotiv devices...");

    // Clear previous discoveries
    _discoveredDevices.clear();

    try {
      // Start scanning for devices with the specific service UUID
      await FlutterBluePlus.startScan(
        withServices: [Guid(controlUuid)],
        timeout: const Duration(seconds: 30),
      );

      // Listen for scan results
      FlutterBluePlus.scanResults.listen((results) {
        // Store the actual devices
        _discoveredDevices = results
            .map((result) => result.device)
            .where((device) => device.platformName.isNotEmpty)
            .toList();

        // Extract device names for your list
        List<String> deviceNames = _discoveredDevices
            .map((device) => device.platformName)
            .toList();

        // Update your UI with the found devices
        _updateFoundDevices(deviceNames);

        for (ScanResult result in results) {
          _updateStatus("Found device: ${result.device.platformName}");
          print(
            "EmotivBLEManager: Found device: ${result.device.platformName} (${result.device.remoteId})",
          );

          // Connect to the first Emotiv device found
          if (_shouldAutoConnectToFirst &&
              result.device.platformName.isNotEmpty) {
            stopScanning();
            connectToDevice(result.device);
            break;
          }
        }
      });
    } catch (e) {
      _updateStatus("Error starting scan: $e");
      _isScanning = false;
    }
  }

  // Add this new method
  Future<void> connectToDeviceByName(String deviceName) async {
    try {
      // Find the device with the matching name
      final device = _discoveredDevices.firstWhere(
        (device) => device.platformName == deviceName,
        orElse: () => throw Exception('Device not found: $deviceName'),
      );

      // Stop scanning before connecting
      if (_isScanning) {
        await stopScanning();
      }

      // Connect to the found device
      await connectToDevice(device);
    } catch (e) {
      _updateStatus("Failed to connect to $deviceName: $e");
      throw e; // Re-throw so the UI can handle it
    }
  }

  Future<void> stopScanning() async {
    if (!_isScanning) return;

    await FlutterBluePlus.stopScan();
    _isScanning = false;
    _updateStatus("Stopped scanning");
  }

  Future<void> connectToDevice(BluetoothDevice device) async {
    try {
      _updateStatus("Connecting to ${device.platformName}...");

      await device.connect(
        timeout: const Duration(seconds: 15),
        license: License.free,
      );
      _emotivDevice = device;
      _isConnected = true;
      _connectionController.add(true);

      _updateStatus("Connected to ${device.platformName}");

      // TODO 2025-08-12 - get the device serial number to use as the decoding key
      final btKeyValue = (RegExp(r'\(([^)]+)\)')
          .firstMatch(device.platformName)
          ?.group(1)); // "E50202E9" -> '6566565666756557'
      // Emotiv Epoc+ (2025-08-13 - Apogee - from CyKit via USB Reciever)
      // [32, 13, 6, 255, 6, 38, 59, 154, 204, 166, 43, 1, 128, 0, 16, 32, 16]
      // Device Firmware = 0x6ff
      // Software Firmware = 0x626
      // Using Device: EEG Signals
      // Serial Number: UD20221202006756
      // AES Key = [54, 53, 53, 55, 55, 55, 53, 54, 54, 54, 53, 53, 54, 54, 53, 54]

      // // Emotiv EpocX (2025-08-13 - Apogee - from CyKit via USB Reciever)
      // [32, 32, 6, 255, 7, 32, 229, 2, 2, 233, 43, 1, 128, 0, 16, 32, 16]
      // Device Firmware = 0x6ff
      // Software Firmware = 0x720
      // Using Device: EEG Signals
      // Serial Number: UD20221202006756
      // Company: None
      // Device: None
      // Vendor: 0x8086
      // Product: 0x7ae0
      // AES Key = [54, 53, 53, 55, 55, 55, 53, 54, 54, 54, 53, 53, 54, 54, 53, 54]

      // "Found device: EPOCX (E50202E9)"
      // "Found device: EPOC+ (3B9ACCA6)"
      // serialNumber = _emotivDevice.advName
      // INPUT: "E50202E9"
      // List.generate(btKeyValue!.length ~/ 2, (i) {String pair = btKeyValue!.substring(i*2, i*2+2); return int.parse(pair, radix: 16).toString();}).join() // "22922233"
      // btKeyValue!.split('').map((c) => int.parse(c, radix: 16).toString()).join() // "1450202149"

      // Create 16-byte serial number bytes from BLE-advertised hex key (E.g. E50202E9)
      Uint8List serialNumberList = CryptoUtils.createSerialNumber(btKeyValue!);
      // Derive Epoc X key bytes per emotiv-lsl mapping (model 8)
      _derivedKeyBytes = CryptoUtils.deriveEpocXKeyFromSerial(serialNumberList);
      serialNumber = String.fromCharCodes(
        _derivedKeyBytes!,
      ); // keep legacy string for any UI/debug
      _networkStreamer?.updateDeviceId(serialNumber);

      // Initialize file writer after successful connection
      await _initializeFileWriter();

      // Initialize LSL outlet
      await _initializeLSLOutlet();

      // Listen for disconnection
      device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _handleDisconnection();
        }
      });

      // Discover services
      await _discoverServices();
    } catch (e) {
      _updateStatus("Failed to connect: $e");
      _isConnected = false;
      _connectionController.add(false);
    }
  }

  Future<void> _discoverServices() async {
    if (_emotivDevice == null) return;

    try {
      _updateStatus("Discovering services...");

      List<BluetoothService> services = await _emotivDevice!.discoverServices();

      for (BluetoothService service in services) {
        print("Discovered service: ${service.uuid}");

        for (BluetoothCharacteristic c in service.characteristics) {
          print("Discovered characteristic: ${c.uuid}");

          final id = c.uuid.toString().toUpperCase();

          if (id == eegDataUuid) {
            _eegDataCharacteristic = c;
            await _setupEEGDataCharacteristic(c);
          } else if (id == motionDataUuid) {
            _motionDataCharacteristic = c;
            await _setupMotionCharacteristic(c); // only setNotifyValue
          }
        } // end for characteristics
      } // end for services

      // Now ask the headset to start both streams
      await _enableBluetoothDataStreams();

      _updateStatus("Setup complete - receiving data");
    } catch (e) {
      _updateStatus("Error discovering services: $e");
    }
  }

  /// Send the start command (0x100) to initiate data streaming
  Future<void> _sendStartCommand(BluetoothCharacteristic characteristic) async {
    try {
      // Create the start command similar to C++ code: newValue.Data[0] = 0x100;
      Uint8List startCommand = Uint8List.fromList([
        0x00,
        0x01,
        0x00,
        0x00,
      ]); // 0x100 in little-endian

      await characteristic.write(startCommand, withoutResponse: false);
      print("> Sent start command to characteristic: ${characteristic.uuid}");
    } catch (e) {
      print("> Error sending start command: $e");
    }
  }

  // 0x0001 -> start EEG (0x41)
  // 0x0002 -> start MEMS (0x42)
  Future<void> _enableBluetoothDataStreams() async {
    // TODO 2025-09-10 - Definitely noticed I was getting data (maybe even both EEG and Motion!) before this function was ever called -- I noticed due to having a breakpoint here.
    if (_eegDataCharacteristic != null) {
      await _sendStartCommand(_eegDataCharacteristic!);
      print('wrote 0x01 to _eegDataCharacteristic)');
    }

    if (_motionDataCharacteristic != null) {
      await _sendStartCommand(_motionDataCharacteristic!);
      print('wrote 0x01 to _motionDataCharacteristic)');
    }

    // final c = _eegDataCharacteristic;
    // if (c == null) return;

    // final data = Uint8List.fromList([0x01, 0x00]);

    // try {
    //   if (c.properties.writeWithoutResponse) {
    //     await c.write(data, withoutResponse: true);
    //   } else if (c.properties.write) {
    //     await c.write(data, withoutResponse: false);
    //   } else {
    //     _updateStatus("EEG characteristic is not writable (${c.uuid})");
    //     return;
    //   }
    //   print(
    //     'wrote 0x01 to ${c.uuid} (wNR:${c.properties.writeWithoutResponse})',
    //   );
    // } catch (e) {
    //   _updateStatus("Enable streams write failed on ${c.uuid}: $e");
    // }
  }

  Future<void> _setupEEGDataCharacteristic(
    BluetoothCharacteristic characteristic,
  ) async {
    try {
      // Enable notifications
      await characteristic.setNotifyValue(true);

      // Listen for data
      characteristic.lastValueStream.listen((data) {
        if (data.isNotEmpty) {
          // List<int>
          _processRawData(data); // output raw
          _processEEGData(Uint8List.fromList(data));
        }
      });

      // // Write configuration data (equivalent to your Swift code) -- I think this is to indicate to the headset that we are connected.
      // if (characteristic.properties.write) {
      // 	final configData = Uint8List.fromList([0x01, 0x00]); // 0x0001 as little-endian
      // 	await characteristic.write(configData, withoutResponse: false);
      // }

      // // Send the start command (0x100) similar to C++ code
      // await _sendStartCommand(characteristic);

      _updateStatus("EEG characteristic configured");
    } catch (e) {
      _updateStatus("Error setting up EEG data characteristic: $e");
    }
  }

  void _processEEGData(Uint8List data) {
    // print("_processEEGData(rawData: [${data.map((v) => v.toString()).join(', ')}]");

    // _processRawData(data);

    if (!_validateData(data)) return;

    // Decrypt and decode the data
    final keyString = serialNumber;
    final keyBytes = _derivedKeyBytes;
    final decodedValues = (keyBytes != null)
        ? CryptoUtils.decryptToDoubleListWithKeyBytes(keyBytes, data)
        : CryptoUtils.decryptToDoubleList(keyString!, data);

    if (decodedValues.isNotEmpty) {
      _eegDataController.add(decodedValues);
      // print("EEG Data: ${decodedValues.take(5).join(', ')}..."); // Print first 5 values

      // Write to file using the file writer
      _eegFileWriter?.writeEEGData(decodedValues);

      // Push to LSL stream
      _pushToLSL(decodedValues);
      final timestampSeconds =
          DateTime.now().microsecondsSinceEpoch / 1000000.0;
      _networkStreamer?.sendSample(
        streamName: 'eeg',
        values: decodedValues,
        timestampSeconds: timestampSeconds,
        metadata: {'sampleRate': 128.0, 'channelCount': decodedValues.length},
      );
    }
  }

  Future<void> _setupMotionCharacteristic(
    BluetoothCharacteristic characteristic,
  ) async {
    try {
      await characteristic.setNotifyValue(true);

      characteristic.lastValueStream.listen((data) {
        if (data.isNotEmpty) {
          _processRawData(data); // output raw
          _processMotionData(Uint8List.fromList(data));
        }
      });

      // // Write configuration data (equivalent to your Swift code) -- I think this is to indicate to the headset that we are connected.
      // if (characteristic.properties.write) {
      // 	final configData = Uint8List.fromList([0x01, 0x00]); // 0x0001 as little-endian
      // 	await characteristic.write(configData, withoutResponse: false);
      // }
      // Send the start command (0x100) similar to C++ code
      // await _sendStartCommand(characteristic);

      _updateStatus("Motion characteristic configured");
    } catch (e) {
      _updateStatus("Error setting up Motion characteristic: $e");
    }
  }

  void _processMotionData(Uint8List data) {
    // if (!_validateData(data)) return; // I think that's okay here
    print(
      "_processMotionData(rawData: [${data.map((v) => v.toString()).join(', ')}]",
    );
    // Process raw Motion data and emit only the decoded motion data
    // _processRawData(data); // output raw

    // Decode motion data from Motion packet
    final motionValues = CryptoUtils.decodeMotionData(data);
    if (motionValues.isNotEmpty && motionValues.any((v) => v != 0.0)) {
      _motionDataController.add(motionValues);
      print(
        "Motion Data: [${motionValues.map((v) => v.toStringAsFixed(3)).join(', ')}]",
      );
      // Write to motion CSV
      _motionFileWriter?.writeMotionData(motionValues);

      // Push to Motion LSL stream
      _pushMotionToLSL(motionValues);
      final timestampSeconds =
          DateTime.now().microsecondsSinceEpoch / 1000000.0;
      _networkStreamer?.sendSample(
        streamName: 'motion',
        values: motionValues,
        timestampSeconds: timestampSeconds,
        metadata: {'sampleRate': 16.0, 'channelCount': motionValues.length},
      );
    }
  }

  // void _processRawData(Uint8List data) {
  bool enableRawDebugLogging = false; // gate noisy logging
  void _processRawData(List<int> data) {
    // called by both `_processEEGData` and `_processMotionData`
    // if (!_validateData(data)) return; // I think that's okay here
    if (enableRawDebugLogging) {
      print(
        "_processRawData(rawData: [${data.map((v) => v.toString()).join(', ')}]",
      );
    }
    // Process raw Motion data and emit only the decoded motion data

    // Decode motion data from Motion packet

    if (data.isNotEmpty) {
      // _motionDataController.add(data);
      // print(
      //   "Motion Data: [${data.map((v) => v.toStringAsFixed(3)).join(', ')}]",
      // );
      // Write to motion CSV
      _rawFileWriter?.writeGenericData(data);

      // Push to LSL stream
      // _pushToLSL(motionValues);
    }
  }

  bool _validateData(Uint8List data) {
    if (data.length < readSize) {
      // Looks like it might be 20 for motion, 32 for EEG?
      print(
        "EmotivBLEManager: Data size too small: ${data.length}, expected size: ${readSize}\nread data: ${data}",
      );
      return false;
    }
    return true;
  }

  void _handleDisconnection() {
    _isConnected = false;
    _emotivDevice = null;
    serialNumber = null;

    // _controlCharacteristic = null;
    _eegDataCharacteristic = null;
    _motionDataCharacteristic = null;
    _connectionController.add(false);
    _updateStatus("Disconnected - closing file and LSL stream...");

    // Close file writer immediately to prevent timer conflicts
    _closeFileWriter();

    // Close LSL outlet
    _closeLSLOutlet();
    _networkStreamer?.stop();

    // // Optionally restart scanning
    // Future.delayed(const Duration(seconds: 2), () {
    //   if (!_isConnected) { // Only restart if still disconnected
    //     startScanning();
    //   }
    // });
  }

  Future<void> _closeFileWriter() async {
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
        // Remove the stream if it was added
        if (_eegStreamInfo != null) await _lslWorker!.removeStream("Epoc X");
        if (_motionStreamInfo != null)
          await _lslWorker!.removeStream("Epoc X Motion");

        // Clean up the worker
        _lslWorker = null;
      }

      _eegStreamInfo = null;
      _motionStreamInfo = null;
      _lslInitialized = false;
      _updateStatus("LSL outlet closed");
    } catch (e) {
      _updateStatus("Error closing LSL outlet: $e");
    }
  }

  void _updateStatus(String status) {
    print(status);
    _statusController.add(status);
  }

  void _updateFoundDevices(List<String> devices) {
    // Add this method to update found devices
    _foundDevicesController.add(devices);
  }

  Future<void> disconnect() async {
    if (_emotivDevice != null && _isConnected) {
      await _emotivDevice!.disconnect();
    } else {
      await _closeFileWriter();
      await _closeLSLOutlet();
    }
  }

  void dispose() {
    _closeFileWriter();
    _closeLSLOutlet();
    _networkStatusSubscription?.cancel();
    _networkStreamer?.dispose();
    _networkStatusController.close();
    _eegDataController.close();
    _motionDataController.close();
    _connectionController.close();
    _statusController.close();
    _foundDevicesController.close();
  }

  // Utility method to get current file info
  Future<Map<String, dynamic>?> getFileInfo() async {
    return await _eegFileWriter?.getFileInfo();
  }

  // Additional utility methods for file writer
  String? get currentFilePath => _eegFileWriter?.filePath;
  bool get isFileWriterInitialized => _eegFileWriter?.isInitialized ?? false;
  int get bufferedLines => _eegFileWriter?.bufferedLines ?? 0;

  // Force flush any buffered data
  Future<void> flushFileBuffer() async {
    await _eegFileWriter?.flush();
    await _motionFileWriter?.flush();
    await _rawFileWriter?.flush();
  }
}

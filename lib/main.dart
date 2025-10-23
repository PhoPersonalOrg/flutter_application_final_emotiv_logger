import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'emotiv_ble_manager.dart';
import 'file_storage.dart';
import 'live_plots_tab.dart';
import 'connection_bar.dart';
import 'live_table_tab.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  runApp(const EmotivBLEApp());
}

class EmotivBLEApp extends StatelessWidget {
  const EmotivBLEApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Emotiv BLE LSL Logger',
      theme: ThemeData(primarySwatch: Colors.purple, useMaterial3: true),
      home: EmotivHomePage(storage: FileStorage.new()),
    );
  }
}

class EmotivHomePage extends StatefulWidget {
  const EmotivHomePage({super.key, required this.storage});
  final FileStorage storage;

  @override
  State<EmotivHomePage> createState() => _EmotivHomePageState();
}

class _EmotivHomePageState extends State<EmotivHomePage>
    with WidgetsBindingObserver {
  final EmotivBLEManager _bleManager = EmotivBLEManager();
  bool _isConnected = false;
  late StreamSubscription _eegSubscription;
  late StreamSubscription _motionSubscription;
  late StreamSubscription _connectionSubscription;

  // bool _useLSLStreams = false; // reserved for future use

  String _connectedDeviceName = '';
  
  // EEG data history for table display
  List<Map<String, dynamic>> _eegRecords = [];
  // Motion data history for table display
  List<Map<String, dynamic>> _motionRecords = [];
  // Throttle redraws
  DateTime _lastUiUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _uiUpdateInterval = Duration(milliseconds: 200); // 5 Hz

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeBluetooth();
    _setupStreamListeners();
  }

  void _setupStreamListeners() {
    // Always listen for connection changes
    _connectionSubscription = _bleManager.connectionStream.listen((connected) {
      setState(() {
        _isConnected = connected;
      });
    });

    _eegSubscription = _bleManager.eegDataStream.listen((data) {
      final now = DateTime.now();
      if (now.difference(_lastUiUpdate) >= _uiUpdateInterval) {
        _lastUiUpdate = now;
        if (mounted) {
          setState(() {
            _addEegRecord(data);
          });
        }
      }
    });

    _motionSubscription = _bleManager.motionDataStream.listen((data) {
      final now = DateTime.now();
      if (now.difference(_lastUiUpdate) >= _uiUpdateInterval) {
        _lastUiUpdate = now;
        if (mounted) {
          setState(() {
            _addMotionRecord(data);
          });
        }
      }
    });

  }

  Future<void> _initializeBluetooth() async {
    // Request permissions
    await _requestPermissions();

    // Check if Bluetooth is available
    if (await FlutterBluePlus.isAvailable == false) {
      return;
    }

    // Check Bluetooth state
    FlutterBluePlus.adapterState.listen((state) {
      if (state == BluetoothAdapterState.on) {
      } else {
      }
    });
  }

  Future<void> _requestPermissions() async {
    if (Platform.isAndroid || Platform.isIOS) {
      // MissingPluginException (MissingPluginException(No implementation found for method requestPermissions on channel flutter.baseflow.com/permissions/methods))
      await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.bluetoothAdvertise,
        Permission.location,
        Permission.manageExternalStorage,
        Permission.storage,
      ].request();

      // ignore permissions result; ConnectionBar will surface connection state
    }
  }

  // ConnectionBar will handle scanning and connect actions directly on manager

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      // Flush buffered data when app goes to background
      _bleManager.flushFileBuffer();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _eegSubscription.cancel();
    _motionSubscription.cancel();
    _connectionSubscription.cancel();
    _bleManager.dispose();
    super.dispose();
  }

  // Add EEG record to history (keep last 5)
  void _addEegRecord(List<double> eegData) {
    if (eegData.length >= 14) { // Ensure we have all 14 channels
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final record = {
        'timestamp': timestamp,
        'AF3': eegData[0],
        'F7': eegData[1],
        'F3': eegData[2],
        'FC5': eegData[3],
        'T7': eegData[4],
        'P7': eegData[5],
        'O1': eegData[6],
        'O2': eegData[7],
        'P8': eegData[8],
        'T8': eegData[9],
        'FC6': eegData[10],
        'F4': eegData[11],
        'F8': eegData[12],
        'AF4': eegData[13],
      };
      
      _eegRecords.add(record);
      
      // Keep only last 5 records
      if (_eegRecords.length > 5) {
        _eegRecords.removeAt(0);
      }
    }
  }

  // Add Motion record to history (keep last 5)
  void _addMotionRecord(List<double> motionData) {
    if (motionData.length >= 6) {
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final record = {
        'timestamp': timestamp,
        'AccX': motionData[0],
        'AccY': motionData[1],
        'AccZ': motionData[2],
        'GyroX': motionData[3],
        'GyroY': motionData[4],
        'GyroZ': motionData[5],
      };

      _motionRecords.add(record);

      // Keep only last 5 records
      if (_motionRecords.length > 5) {
        _motionRecords.removeAt(0);
      }
    }
  }

  // Settings UI removed from top bar for now; can be re-introduced later

  int _currentTabIndex = 0; // 0 = Live Plots, 1 = Live Tables

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: ConnectionBar(
        bleManager: _bleManager,
        isConnected: _isConnected,
        connectedDeviceName: _connectedDeviceName,
      ),
      body: IndexedStack(
        index: _currentTabIndex,
        children: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: LivePlotsContent(bleManager: _bleManager),
          ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: LiveTableTab(
              eegRecords: _eegRecords,
              motionRecords: _motionRecords,
              isConnected: _isConnected,
            ),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentTabIndex,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.show_chart), label: 'Live Plots'),
          NavigationDestination(icon: Icon(Icons.table_chart), label: 'Live Tables'),
        ],
        onDestinationSelected: (idx) => setState(() => _currentTabIndex = idx),
      ),
    );
  }
}

///////////////////////////////////////////////////////////////////////////

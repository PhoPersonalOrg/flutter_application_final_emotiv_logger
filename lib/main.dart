import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_emotiv_logger/directory_helper.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'emotiv_ble_manager.dart';
import 'file_storage.dart';
import 'settings/app_settings.dart';
import 'services/network_streamer.dart';

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
	  home: EmotivHomePage(storage: FileStorage()),
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
  final AppSettingsRepository _settingsRepository = AppSettingsRepository();
  List<double> _latestEEGData = [];
  List<double> _latestMotionData = [];
  String _statusMessage = "Ready to connect";
  bool _isConnected = false;
  late StreamSubscription _eegSubscription;
  late StreamSubscription _motionSubscription;
  late StreamSubscription _statusSubscription;
  late StreamSubscription _connectionSubscription;
  late StreamSubscription _networkStatusSubscription;

  final bool _useLSLStreams = false;
  AppSettings _appSettings = const AppSettings();
  NetworkStreamStatus _networkStatus = NetworkStreamStatus.disabled();
  bool _settingsLoaded = false;

  // Add this field to store the selected directory
  String? _selectedDirectory; // "/storage/emulated/0/DATA/EEG"

  // Add these new state variables
  List<String> _foundDevices = [];
  String _connectedDeviceName = '';

  // EEG data history for table display
  final List<Map<String, dynamic>> _eegRecords = [];
  // Throttle redraws
  DateTime _lastUiUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _uiUpdateInterval = Duration(milliseconds: 200); // 5 Hz

  @override
  void initState() {
	super.initState();
	WidgetsBinding.instance.addObserver(this);
	_initializeBluetooth();
	_setupStreamListeners();
	_loadAppSettings();
  }

  void _setupStreamListeners() {
	// Add this listener for found devices
	// Always listen for connection changes
	_connectionSubscription = _bleManager.connectionStream.listen((connected) {
	  setState(() {
		_isConnected = connected;
	  });
	});

	// Always listen for found devices
	_bleManager.foundDevicesStream.listen((devices) {
	  setState(() {
		_foundDevices = devices;
	  });
	});

	_eegSubscription = _bleManager.eegDataStream.listen((data) {
	  final now = DateTime.now();
	  if (now.difference(_lastUiUpdate) >= _uiUpdateInterval) {
		_lastUiUpdate = now;
		if (mounted) {
		  setState(() {
			_latestEEGData = data;
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
			_latestMotionData = data;
		  });
		}
	  }
	});

	_statusSubscription = _bleManager.statusStream.listen((status) {
	  setState(() {
		_statusMessage = status;
	  });
	});
	_networkStatusSubscription = _bleManager.networkStatusStream.listen((
	  status,
	) {
	  if (mounted) {
		setState(() {
		  _networkStatus = status;
		});
	  }
	});
  }

  Future<void> _loadAppSettings() async {
	final loaded = await _settingsRepository.load();
	if (!mounted) return;
	String resolvedDirectory;
	if (loaded.saveDirectory != null) {
	  resolvedDirectory = loaded.saveDirectory!;
	} else {
	  final docsDir = await getApplicationDocumentsDirectory();
	  resolvedDirectory = docsDir.path;
	}
	setState(() {
	  _appSettings = loaded;
	  _settingsLoaded = true;
	  _selectedDirectory = resolvedDirectory;
	});
	_bleManager.setCustomSaveDirectory(resolvedDirectory);
	await _bleManager.updateAppSettings(loaded);
  }

  Future<void> _initializeBluetooth() async {
	// Request permissions
	await _requestPermissions();

	// Check if Bluetooth is available
	if (await FlutterBluePlus.isAvailable == false) {
	  setState(() {
		_statusMessage = "Bluetooth not available";
	  });
	  return;
	}

	// Check Bluetooth state
	FlutterBluePlus.adapterState.listen((state) {
	  if (state == BluetoothAdapterState.on) {
		setState(() {
		  _statusMessage = "Bluetooth ready";
		});
	  } else {
		setState(() {
		  _statusMessage = "Please enable Bluetooth";
		});
	  }
	});
  }

  Future<void> _requestPermissions() async {
	if (Platform.isAndroid || Platform.isIOS) {
	  // MissingPluginException (MissingPluginException(No implementation found for method requestPermissions on channel flutter.baseflow.com/permissions/methods))
	  Map<Permission, PermissionStatus> permissions = await [
		Permission.bluetoothScan,
		Permission.bluetoothConnect,
		Permission.bluetoothAdvertise,
		Permission.location,
		Permission.manageExternalStorage,
		Permission.storage,
	  ].request();

	  bool allGranted = permissions.values.every((status) => status.isGranted);
	  if (!allGranted) {
		setState(() {
		  _statusMessage = "Bluetooth permissions required";
		});
	  }
	}
  }

  Future<void> _startScanning() async {
	await _bleManager.startScanning();
  }

  Future<void> _stopScanning() async {
	await _bleManager.stopScanning();
  }

  Future<void> _disconnect() async {
	await _bleManager.disconnect();
  }

  Future<void> _toggleScanning() async {
	if (_bleManager.isScanning) {
	  await _stopScanning();
	} else {
	  await _startScanning();
	}
  }

  // Add this method to your _EmotivHomePageState class
  Future<void> _connectToDeviceByName(String deviceName) async {
	try {
	  await _bleManager.connectToDeviceByName(deviceName);

	  // Update connected device name on successful connection
	  setState(() {
		_connectedDeviceName = deviceName;
	  });
	} catch (e) {
	  ScaffoldMessenger.of(context).showSnackBar(
		SnackBar(
		  content: Text('Failed to connect to $deviceName: $e'),
		  backgroundColor: Colors.red,
		),
	  );
	}
  }

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
	_statusSubscription.cancel();
	_connectionSubscription.cancel();
	_networkStatusSubscription.cancel();
	_bleManager.dispose();
	super.dispose();
  }

  // Add EEG record to history (keep last 5)
  void _addEegRecord(List<double> eegData) {
	if (eegData.length >= 14) {
	  // Ensure we have all 14 channels
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

  // Add this method to navigate to settings
  Future<void> _openFileSettings() async {
	final result = await Navigator.push<SettingsResult>(
	  context,
	  MaterialPageRoute(
		builder: (context) => FileSettingsScreen(
		  initialDirectory: _selectedDirectory,
		  initialSettings: _appSettings,
		),
	  ),
	);

	if (result == null) {
	  return;
	}

	final appliedDirectory = result.selectedDirectory;
	final appliedSettings = result.settings;

	if (appliedDirectory != null) {
	  setState(() {
		print("File settings return context result: $appliedDirectory");
		_selectedDirectory = appliedDirectory;
	  });

	  // Apply the new directory to your BLE manager
	  _bleManager.setCustomSaveDirectory(_selectedDirectory);

	  // Show confirmation
	  ScaffoldMessenger.of(context).showSnackBar(
		SnackBar(content: Text('Save directory updated: $_selectedDirectory')),
	  );
	}

	await _settingsRepository.save(appliedSettings);
	await _bleManager.updateAppSettings(appliedSettings);

	setState(() {
	  _appSettings = appliedSettings;
	});

	final statusLabel = appliedSettings.useNetworkStream
		? 'Network streaming enabled (${appliedSettings.networkProtocol.name.toUpperCase()} ${appliedSettings.networkHost}:${appliedSettings.networkPort})'
		: 'Network streaming disabled';
	ScaffoldMessenger.of(
	  context,
	).showSnackBar(SnackBar(content: Text(statusLabel)));
  }

  @override
  Widget build(BuildContext context) {
	return Scaffold(
	  appBar: AppBar(
		title: const Text('Emotiv BLE LSL Logger'),
		backgroundColor: Theme.of(context).colorScheme.inversePrimary,
		actions: [
		  // Add settings button to app bar
		  IconButton(
			icon: const Icon(Icons.settings),
			onPressed: _settingsLoaded ? () => _openFileSettings() : null,
		  ),
		],
	  ),
	  body: Padding(
		padding: const EdgeInsets.all(16.0),
		child: Column(
		  crossAxisAlignment: CrossAxisAlignment.stretch,
		  children: [
			// Status Card
			Card(
			  child: Padding(
				padding: const EdgeInsets.all(16.0),
				child: Column(
				  crossAxisAlignment: CrossAxisAlignment.start,
				  children: [
					Text(
					  'Device Status',
					  style: Theme.of(context).textTheme.titleMedium,
					),
					const SizedBox(height: 8),
					Row(
					  children: [
						Icon(
						  _isConnected
							  ? Icons.bluetooth_connected
							  : Icons.bluetooth_disabled,
						  color: _isConnected ? Colors.green : Colors.red,
						),
						const SizedBox(width: 8),
						Expanded(
						  child: Text(
							_statusMessage,
							style: TextStyle(
							  color: _isConnected
								  ? Colors.green
								  : Colors.black87,
							),
						  ),
						),
					  ],
					),
				  ],
				),
			  ),
			),

			const SizedBox(height: 16),

			NetworkStatusCard(
			  status: _networkStatus,
			  enabled: _appSettings.useNetworkStream,
			),

			const SizedBox(height: 16),

			// Replace your existing control buttons with this:
			BluetoothControlWidget(
			  isConnected: _isConnected,
			  isScanning: _bleManager.isScanning,
			  connectedDeviceName: _connectedDeviceName,
			  foundDevices: _foundDevices,
			  onToggleScan: _toggleScanning,
			  onDisconnect: _disconnect,
			  onConnectToDevice: _connectToDeviceByName,
			),

			const SizedBox(height: 16),

			// EEG Data Table (replaces the old stream display)
			Expanded(
			  flex: 2,
			  child: Card(
				child: Padding(
				  padding: const EdgeInsets.all(16.0),
				  child: Column(
					crossAxisAlignment: CrossAxisAlignment.start,
					children: [
					  Text(
						'EEG Data History (Last 5 Records)',
						style: Theme.of(context).textTheme.titleMedium,
					  ),
					  const SizedBox(height: 8),
					  if (_eegRecords.isEmpty)
						const Expanded(
						  child: Center(
							child: Text(
							  'No EEG data recorded yet...\nConnect to Emotiv device to see data history',
							  textAlign: TextAlign.center,
							  style: TextStyle(color: Colors.grey),
							),
						  ),
						)
					  else
						Expanded(
						  child: SingleChildScrollView(
							scrollDirection: Axis.horizontal,
							child: SingleChildScrollView(
							  child: DataTable(
								dataRowHeight: 30.0,
								columnSpacing: 8.0,
								horizontalMargin: 12.0,
								columns: const [
								  DataColumn(
									label: Text(
									  'Time',
									  style: TextStyle(
										fontWeight: FontWeight.bold,
									  ),
									),
								  ),
								  DataColumn(
									label: Text(
									  'AF3',
									  style: TextStyle(
										fontWeight: FontWeight.bold,
									  ),
									),
								  ),
								  DataColumn(
									label: Text(
									  'F7',
									  style: TextStyle(
										fontWeight: FontWeight.bold,
									  ),
									),
								  ),
								  DataColumn(
									label: Text(
									  'F3',
									  style: TextStyle(
										fontWeight: FontWeight.bold,
									  ),
									),
								  ),
								  DataColumn(
									label: Text(
									  'FC5',
									  style: TextStyle(
										fontWeight: FontWeight.bold,
									  ),
									),
								  ),
								  DataColumn(
									label: Text(
									  'T7',
									  style: TextStyle(
										fontWeight: FontWeight.bold,
									  ),
									),
								  ),
								  DataColumn(
									label: Text(
									  'P7',
									  style: TextStyle(
										fontWeight: FontWeight.bold,
									  ),
									),
								  ),
								  DataColumn(
									label: Text(
									  'O1',
									  style: TextStyle(
										fontWeight: FontWeight.bold,
									  ),
									),
								  ),
								  DataColumn(
									label: Text(
									  'O2',
									  style: TextStyle(
										fontWeight: FontWeight.bold,
									  ),
									),
								  ),
								  DataColumn(
									label: Text(
									  'P8',
									  style: TextStyle(
										fontWeight: FontWeight.bold,
									  ),
									),
								  ),
								  DataColumn(
									label: Text(
									  'T8',
									  style: TextStyle(
										fontWeight: FontWeight.bold,
									  ),
									),
								  ),
								  DataColumn(
									label: Text(
									  'FC6',
									  style: TextStyle(
										fontWeight: FontWeight.bold,
									  ),
									),
								  ),
								  DataColumn(
									label: Text(
									  'F4',
									  style: TextStyle(
										fontWeight: FontWeight.bold,
									  ),
									),
								  ),
								  DataColumn(
									label: Text(
									  'F8',
									  style: TextStyle(
										fontWeight: FontWeight.bold,
									  ),
									),
								  ),
								  DataColumn(
									label: Text(
									  'AF4',
									  style: TextStyle(
										fontWeight: FontWeight.bold,
									  ),
									),
								  ),
								],
								rows: _eegRecords.reversed.map((record) {
								  return DataRow(
									cells: [
									  DataCell(
										Text(
										  DateTime.fromMillisecondsSinceEpoch(
											record['timestamp'],
										  ).toString().substring(
											11,
											23,
										  ), // Show time only
										  style: const TextStyle(
											fontSize: 10,
											fontFamily: 'monospace',
										  ),
										),
									  ),
									  DataCell(
										Text(
										  record['AF3'].toStringAsFixed(3),
										  style: const TextStyle(
											fontSize: 10,
											fontFamily: 'monospace',
										  ),
										),
									  ),
									  DataCell(
										Text(
										  record['F7'].toStringAsFixed(3),
										  style: const TextStyle(
											fontSize: 10,
											fontFamily: 'monospace',
										  ),
										),
									  ),
									  DataCell(
										Text(
										  record['F3'].toStringAsFixed(3),
										  style: const TextStyle(
											fontSize: 10,
											fontFamily: 'monospace',
										  ),
										),
									  ),
									  DataCell(
										Text(
										  record['FC5'].toStringAsFixed(3),
										  style: const TextStyle(
											fontSize: 10,
											fontFamily: 'monospace',
										  ),
										),
									  ),
									  DataCell(
										Text(
										  record['T7'].toStringAsFixed(3),
										  style: const TextStyle(
											fontSize: 10,
											fontFamily: 'monospace',
										  ),
										),
									  ),
									  DataCell(
										Text(
										  record['P7'].toStringAsFixed(3),
										  style: const TextStyle(
											fontSize: 10,
											fontFamily: 'monospace',
										  ),
										),
									  ),
									  DataCell(
										Text(
										  record['O1'].toStringAsFixed(3),
										  style: const TextStyle(
											fontSize: 10,
											fontFamily: 'monospace',
										  ),
										),
									  ),
									  DataCell(
										Text(
										  record['O2'].toStringAsFixed(3),
										  style: const TextStyle(
											fontSize: 10,
											fontFamily: 'monospace',
										  ),
										),
									  ),
									  DataCell(
										Text(
										  record['P8'].toStringAsFixed(3),
										  style: const TextStyle(
											fontSize: 10,
											fontFamily: 'monospace',
										  ),
										),
									  ),
									  DataCell(
										Text(
										  record['T8'].toStringAsFixed(3),
										  style: const TextStyle(
											fontSize: 10,
											fontFamily: 'monospace',
										  ),
										),
									  ),
									  DataCell(
										Text(
										  record['FC6'].toStringAsFixed(3),
										  style: const TextStyle(
											fontSize: 10,
											fontFamily: 'monospace',
										  ),
										),
									  ),
									  DataCell(
										Text(
										  record['F4'].toStringAsFixed(3),
										  style: const TextStyle(
											fontSize: 10,
											fontFamily: 'monospace',
										  ),
										),
									  ),
									  DataCell(
										Text(
										  record['F8'].toStringAsFixed(3),
										  style: const TextStyle(
											fontSize: 10,
											fontFamily: 'monospace',
										  ),
										),
									  ),
									  DataCell(
										Text(
										  record['AF4'].toStringAsFixed(3),
										  style: const TextStyle(
											fontSize: 10,
											fontFamily: 'monospace',
										  ),
										),
									  ),
									],
								  );
								}).toList(),
							  ),
							),
						  ),
						),
					],
				  ),
				),
			  ),
			),

			const SizedBox(height: 16),

			// EEG Live Data Display
			Expanded(
			  flex: 1,
			  child: Card(
				child: Padding(
				  padding: const EdgeInsets.all(16.0),
				  child: Column(
					crossAxisAlignment: CrossAxisAlignment.start,
					children: [
					  Text(
						'EEG Data Stream',
						style: Theme.of(context).textTheme.titleMedium,
					  ),
					  const SizedBox(height: 8),
					  if (_latestEEGData.isEmpty)
						const Expanded(
						  child: Center(
							child: Text(
							  'No EEG data received yet...',
							  textAlign: TextAlign.center,
							  style: TextStyle(color: Colors.grey),
							),
						  ),
						)
					  else
						Expanded(
						  child: SingleChildScrollView(
							child: Column(
							  crossAxisAlignment: CrossAxisAlignment.start,
							  children: [
								const Text(
								  'Latest EEG Sample (14 channels):',
								  style: TextStyle(fontWeight: FontWeight.bold),
								),
								const SizedBox(height: 8),
								// First 7 EEG channels
								Text(
								  'Channels AF3, F7, F3, FC5, T7, P7, O1:',
								  style: TextStyle(
									fontWeight: FontWeight.w600,
									color: Colors.blue[700],
								  ),
								),
								...List.generate(7, (index) {
								  final labels = [
									'AF3',
									'F7',
									'F3',
									'FC5',
									'T7',
									'P7',
									'O1',
								  ];
								  return Padding(
									padding: const EdgeInsets.symmetric(
									  vertical: 1.0,
									),
									child: Row(
									  children: [
										SizedBox(
										  width: 60,
										  child: Text(
											'${labels[index]}:',
											style: const TextStyle(
											  fontWeight: FontWeight.w500,
											),
										  ),
										),
										Expanded(
										  child: Container(
											padding: const EdgeInsets.symmetric(
											  horizontal: 8,
											  vertical: 2,
											),
											decoration: BoxDecoration(
											  color: Colors.blue[50],
											  borderRadius:
												  BorderRadius.circular(4),
											),
											child: Text(
											  _latestEEGData.length > index
												  ? _latestEEGData[index]
														.toStringAsFixed(3)
												  : '-',
											  style: const TextStyle(
												fontFamily: 'monospace',
												fontSize: 12,
											  ),
											),
										  ),
										),
									  ],
									),
								  );
								}),
								const SizedBox(height: 8),
								// Next 7 EEG channels
								Text(
								  'Channels O2, P8, T8, FC6, F4, F8, AF4:',
								  style: TextStyle(
									fontWeight: FontWeight.w600,
									color: Colors.green[700],
								  ),
								),
								...List.generate(7, (index) {
								  final labels = [
									'O2',
									'P8',
									'T8',
									'FC6',
									'F4',
									'F8',
									'AF4',
								  ];
								  return Padding(
									padding: const EdgeInsets.symmetric(
									  vertical: 1.0,
									),
									child: Row(
									  children: [
										SizedBox(
										  width: 60,
										  child: Text(
											'${labels[index]}:',
											style: const TextStyle(
											  fontWeight: FontWeight.w500,
											),
										  ),
										),
										Expanded(
										  child: Container(
											padding: const EdgeInsets.symmetric(
											  horizontal: 8,
											  vertical: 2,
											),
											decoration: BoxDecoration(
											  color: Colors.green[50],
											  borderRadius:
												  BorderRadius.circular(4),
											),
											child: Text(
											  _latestEEGData.length >
													  (index + 7)
												  ? _latestEEGData[index + 7]
														.toStringAsFixed(3)
												  : '-',
											  style: const TextStyle(
												fontFamily: 'monospace',
												fontSize: 12,
											  ),
											),
										  ),
										),
									  ],
									),
								  );
								}),
							  ],
							),
						  ),
						),
					],
				  ),
				),
			  ),
			),
		  ],
		),
	  ),
	);
  }
}

class NetworkStatusCard extends StatelessWidget {
  final NetworkStreamStatus status;
  final bool enabled;

  const NetworkStatusCard({
	super.key,
	required this.status,
	required this.enabled,
  });

  @override
  Widget build(BuildContext context) {
	final iconData = !enabled
		? Icons.cloud_off
		: status.connected
		? Icons.cloud_done
		: Icons.cloud_upload;
	final color = !enabled
		? Colors.grey
		: status.connected
		? Colors.green
		: Colors.orange;
	final subtitle = !enabled
		? 'Network streaming disabled in settings'
		: (status.message ?? 'Preparing network stream...');

	return Card(
	  child: ListTile(
		leading: Icon(iconData, color: color),
		title: const Text('Network Stream'),
		subtitle: Text(subtitle),
		trailing: enabled
			? Text(
				status.protocol.name.toUpperCase(),
				style: TextStyle(color: color, fontWeight: FontWeight.bold),
			  )
			: null,
	  ),
	);
  }
}

///////////////////////////////////////////////////////////////////////////
// EEG Connections Widget
class ScannerWidget extends StatelessWidget {
  // Displays the result of scanning for bluetooth devices and discovered devices
  final bool isScanning;
  final VoidCallback onToggleScan;
  final List<String> foundDevices;
  final void Function(String deviceName) onConnectToDevice; // Add this

  const ScannerWidget({
	super.key,
	required this.isScanning,
	required this.onToggleScan,
	required this.foundDevices,
	required this.onConnectToDevice, // Add this
  });

  @override
  Widget build(BuildContext context) {
	return Column(
	  crossAxisAlignment: CrossAxisAlignment.start,
	  children: [
		// Scanning row
		Row(
		  children: [
			const Text('Scanning:'),
			const Spacer(),
			ElevatedButton(
			  onPressed: onToggleScan,
			  child: Text(isScanning ? 'Stop' : 'Start'),
			),
		  ],
		),

		const SizedBox(height: 16),

		// Found headsets
		const Text('Found headsets:'),

		const SizedBox(height: 8),

		// Device list with connect buttons
		...foundDevices.map(
		  (device) => Padding(
			padding: const EdgeInsets.symmetric(vertical: 4.0),
			child: Row(
			  children: [
				Expanded(child: Text('• $device')),
				ElevatedButton(
				  onPressed: () => onConnectToDevice(device),
				  child: const Text('Connect'),
				),
			  ],
			),
		  ),
		),
	  ],
	);
  }
}

class ConnectionWidget extends StatelessWidget {
  // Displays the name of the connected device and a disconnect button
  final String deviceName;
  final VoidCallback onDisconnect;

  const ConnectionWidget({
	super.key,
	required this.deviceName,
	required this.onDisconnect,
  });

  @override
  Widget build(BuildContext context) {
	return Column(
	  crossAxisAlignment: CrossAxisAlignment.start,
	  children: [
		// Connected row
		Row(
		  children: [
			const Text('Connected:'),
			const Spacer(),
			ElevatedButton(
			  onPressed: onDisconnect,
			  child: const Text('Disconnect'),
			),
		  ],
		),

		const SizedBox(height: 8),

		// Device name
		Text(deviceName),
	  ],
	);
  }
}

class BluetoothControlWidget extends StatelessWidget {
  // Wraps the scanner and connection widgets based on scanning state and displays them based on the connection state
  final bool isConnected;
  final bool isScanning;
  final String connectedDeviceName;
  final List<String> foundDevices;
  final VoidCallback onToggleScan;
  final VoidCallback onDisconnect;
  final void Function(String deviceName) onConnectToDevice;

  const BluetoothControlWidget({
	super.key,
	required this.isConnected,
	required this.isScanning,
	required this.connectedDeviceName,
	required this.foundDevices,
	required this.onToggleScan,
	required this.onDisconnect,
	required this.onConnectToDevice,
  });

  @override
  Widget build(BuildContext context) {
	return isConnected
		? ConnectionWidget(
			deviceName: connectedDeviceName,
			onDisconnect: onDisconnect,
		  )
		: ScannerWidget(
			isScanning: isScanning,
			onToggleScan: onToggleScan,
			foundDevices: foundDevices,
			onConnectToDevice: onConnectToDevice,
		  );
  }
}

///////////////////////////////////////////////////////////////////////////
// Settings Screen
class SettingsResult {
  const SettingsResult({this.selectedDirectory, required this.settings});

  final String? selectedDirectory;
  final AppSettings settings;
}

class FileSettingsScreen extends StatefulWidget {
  const FileSettingsScreen({
	super.key,
	required this.initialDirectory,
	required this.initialSettings,
  });

  final String? initialDirectory;
  final AppSettings initialSettings;

  @override
  State<FileSettingsScreen> createState() => _FileSettingsScreenState();
}

class _FileSettingsScreenState extends State<FileSettingsScreen> {
  late String? _selectedDirectory;
  late bool _useNetworkStream;
  late TextEditingController _hostController;
  late TextEditingController _portController;
  late NetworkProtocol _protocol;

  @override
  void initState() {
	super.initState();
	_selectedDirectory = widget.initialDirectory;
	_useNetworkStream = widget.initialSettings.useNetworkStream;
	_hostController = TextEditingController(
	  text: widget.initialSettings.networkHost,
	);
	_portController = TextEditingController(
	  text: widget.initialSettings.networkPort.toString(),
	);
	_protocol = widget.initialSettings.networkProtocol;
  }

  @override
  void dispose() {
	_hostController.dispose();
	_portController.dispose();
	super.dispose();
  }

  @override
  Widget build(BuildContext context) {
	return Scaffold(
	  appBar: AppBar(title: const Text('Settings')),
	  body: ListView(
		padding: const EdgeInsets.all(16),
		children: [
		  Card(
			child: ListTile(
			  title: const Text('Save Directory'),
			  subtitle: Text(_selectedDirectory ?? 'Default (App Documents)'),
			  trailing: const Icon(Icons.folder),
			  onTap: () => _selectDirectory(context),
			),
		  ),
		  const SizedBox(height: 16),
		  SwitchListTile(
			value: _useNetworkStream,
			title: const Text('Enable Network Streaming'),
			subtitle: const Text(
			  'Send EEG and motion samples to a remote server with timestamps.',
			),
			onChanged: (value) {
			  setState(() {
				_useNetworkStream = value;
			  });
			},
		  ),
		  const SizedBox(height: 8),
		  TextField(
			controller: _hostController,
			enabled: _useNetworkStream,
			decoration: const InputDecoration(
			  labelText: 'Server Host',
			  hintText: 'apogee.tailc8d2c6.ts.net',
			  border: OutlineInputBorder(),
			),
		  ),
		  const SizedBox(height: 8),
		  TextField(
			controller: _portController,
			enabled: _useNetworkStream,
			decoration: const InputDecoration(
			  labelText: 'Server Port',
			  border: OutlineInputBorder(),
			),
			keyboardType: TextInputType.number,
		  ),
		  const SizedBox(height: 8),
		  DropdownButtonFormField<NetworkProtocol>(
			initialValue: _protocol,
			decoration: const InputDecoration(
			  labelText: 'Protocol',
			  border: OutlineInputBorder(),
			),
			items: NetworkProtocol.values
				.map(
				  (protocol) => DropdownMenuItem(
					value: protocol,
					child: Text(protocol.name.toUpperCase()),
				  ),
				)
				.toList(),
			onChanged: _useNetworkStream
				? (value) {
					if (value != null) {
					  setState(() {
						_protocol = value;
					  });
					}
				  }
				: null,
		  ),
		  const SizedBox(height: 24),
		  ElevatedButton(
			onPressed: () => _applySettings(context),
			child: const Text('Apply Settings'),
		  ),
		],
	  ),
	);
  }

  Future<void> _selectDirectory(BuildContext context) async {
	try {
	  // First check if we already have permission
	  final hasPermission = await DirectoryHelper.hasStoragePermission();

	  if (!hasPermission) {
		// Show dialog explaining why we need permission
		final shouldRequest = await showDialog<bool>(
		  context: context,
		  builder: (context) => AlertDialog(
			title: const Text('Storage Permission Required'),
			content: const Text(
			  'This app needs storage permission to save EEG data files to your chosen directory. '
			  'Please grant storage permission in the next dialog.',
			),
			actions: [
			  TextButton(
				onPressed: () => Navigator.pop(context, false),
				child: const Text('Cancel'),
			  ),
			  TextButton(
				onPressed: () => Navigator.pop(context, true),
				child: const Text('Grant Permission'),
			  ),
			],
		  ),
		);

		if (shouldRequest != true) return;

		// Request permission
		final granted = await DirectoryHelper.requestStoragePermission();
		if (!granted) {
		  ScaffoldMessenger.of(context).showSnackBar(
			const SnackBar(
			  content: Text(
				'Storage permission is required to select save directory',
			  ),
			  action: SnackBarAction(
				label: 'Settings',
				onPressed: openAppSettings,
			  ),
			),
		  );
		  return;
		}
	  }

	  // Permission granted, now select directory
	  final selectedDir = await DirectoryHelper.selectDirectory();
	  if (selectedDir != null) {
		setState(() {
		  _selectedDirectory = selectedDir;
		});

		ScaffoldMessenger.of(context).showSnackBar(
		  SnackBar(
			content: Text('Directory selected: ${selectedDir.split('/').last}'),
		  ),
		);
	  }
	} catch (e) {
	  print("Error in _selectDirectory: $e");
	  ScaffoldMessenger.of(
		context,
	  ).showSnackBar(SnackBar(content: Text('Error selecting directory: $e')));
	}
  }

  Future<void> _applySettings(BuildContext context) async {
	final trimmedHost = _hostController.text.trim();
	final trimmedPort = _portController.text.trim();
	final parsedPort = int.tryParse(trimmedPort);

	if (_useNetworkStream) {
	  if (trimmedHost.isEmpty) {
		ScaffoldMessenger.of(context).showSnackBar(
		  const SnackBar(content: Text('Please provide a server host')),
		);
		return;
	  }
	  if (parsedPort == null || parsedPort <= 0 || parsedPort > 65535) {
		ScaffoldMessenger.of(context).showSnackBar(
		  const SnackBar(content: Text('Please enter a valid port (1-65535)')),
		);
		return;
	  }
	}

	final updatedSettings = widget.initialSettings.copyWith(useNetworkStream: _useNetworkStream, networkHost: trimmedHost.isEmpty ? AppSettings.defaultHost : trimmedHost, networkPort: parsedPort ?? AppSettings.defaultPort, networkProtocol: _protocol, saveDirectory: _selectedDirectory);

	Navigator.pop(
	  context,
	  SettingsResult(
		selectedDirectory: _selectedDirectory,
		settings: updatedSettings,
	  ),
	);
  }
}

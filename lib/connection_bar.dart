import 'dart:async';
import 'package:flutter/material.dart';
import 'emotiv_ble_manager.dart';

class ConnectionBar extends StatefulWidget implements PreferredSizeWidget {
  final EmotivBLEManager bleManager;
  final bool isConnected;
  final String connectedDeviceName;

  const ConnectionBar({
    super.key,
    required this.bleManager,
    required this.isConnected,
    required this.connectedDeviceName,
  });

  @override
  Size get preferredSize => const Size.fromHeight(56);

  @override
  State<ConnectionBar> createState() => _ConnectionBarState();
}

class _ConnectionBarState extends State<ConnectionBar> {
  bool _scanning = false;
  StreamSubscription<List<String>>? _foundSub;
  List<String> _found = const [];

  Future<void> _openScanSheet() async {
    setState(() => _scanning = true);
    await widget.bleManager.startScanning();
    _foundSub?.cancel();
    _foundSub = widget.bleManager.foundDevicesStream.listen((devices) {
      setState(() => _found = devices);
    });

    if (!mounted) return;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(Icons.bluetooth_searching),
                    const SizedBox(width: 8),
                    const Text('Scan & Connect', style: TextStyle(fontWeight: FontWeight.bold)),
                    const Spacer(),
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Close'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                StreamBuilder<List<String>>(
                  stream: widget.bleManager.foundDevicesStream,
                  initialData: _found,
                  builder: (context, snapshot) {
                    final devices = snapshot.data ?? const [];
                    if (devices.isEmpty) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24.0),
                        child: Center(child: Text('Scanning... No devices yet')),
                      );
                    }
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: devices
                          .map((name) => ListTile(
                                leading: const Icon(Icons.headset),
                                title: Text(name),
                                trailing: ElevatedButton(
                                  onPressed: () async {
                                    try {
                                      await widget.bleManager.connectToDeviceByName(name);
                                      if (ctx.mounted) Navigator.pop(ctx);
                                    } catch (_) {}
                                  },
                                  child: const Text('Connect'),
                                ),
                              ))
                          .toList(),
                    );
                  },
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () async {
                      await widget.bleManager.stopScanning();
                      await widget.bleManager.startScanning();
                    },
                    icon: const Icon(Icons.refresh),
                    label: const Text('Rescan'),
                  ),
                )
              ],
            ),
          ),
        );
      },
    );

    // Cleanup after sheet closes
    await widget.bleManager.stopScanning();
    await _foundSub?.cancel();
    if (mounted) {
      setState(() {
        _scanning = false;
        _found = const [];
      });
    }
  }

  @override
  void dispose() {
    _foundSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      elevation: 1,
      child: SizedBox(
        height: widget.preferredSize.height,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12.0),
          child: Row(
            children: [
              Icon(
                widget.isConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
                color: widget.isConnected ? Colors.green : Colors.red,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.isConnected
                      ? 'Connected: ${widget.connectedDeviceName.isNotEmpty ? widget.connectedDeviceName : 'Emotiv'}'
                      : (_scanning ? 'Scanning for Emotiv devices...' : 'Not connected'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              if (widget.isConnected)
                FilledButton.tonal(
                  onPressed: () => widget.bleManager.disconnect(),
                  child: const Text('Disconnect'),
                )
              else
                FilledButton(
                  onPressed: _openScanSheet,
                  child: const Text('Scan & Connect'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}



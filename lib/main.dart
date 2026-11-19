import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/root_shell.dart';
import 'sessions/dropbox_sync.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Required before runApp for TaskHandler ↔ UI communication on Android.
  FlutterForegroundTask.initCommunicationPort();
  await DropboxSync.initIfConfigured();
  runApp(const ProviderScope(child: EmotivAcquisitionApp()));
}

class EmotivAcquisitionApp extends StatelessWidget {
  const EmotivAcquisitionApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Emotiv Acquisition',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6B3A2E)),
        useMaterial3: true,
      ),
      home: const RootShell(),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'home_page.dart';
import 'providers.dart';
import 'sessions_page.dart';

/// Bottom-nav shell: Record (acquisition) | Sessions (library + transfer).
class RootShell extends ConsumerStatefulWidget {
  const RootShell({super.key});

  @override
  ConsumerState<RootShell> createState() => _RootShellState();
}

class _RootShellState extends ConsumerState<RootShell> {
  int _index = 0;

  void _select(int i) {
    setState(() => _index = i);
    if (i == 1) {
      ref.read(sessionListProvider.notifier).refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: const [
          HomePage(),
          SessionsPage(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: _select,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.bluetooth_searching_outlined),
            selectedIcon: Icon(Icons.bluetooth_searching),
            label: 'Record',
          ),
          NavigationDestination(
            icon: Icon(Icons.folder_outlined),
            selectedIcon: Icon(Icons.folder),
            label: 'Sessions',
          ),
        ],
      ),
    );
  }
}

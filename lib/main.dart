import 'dart:async';

import 'package:flutter/material.dart';

import 'app_state.dart';
import 'ui/diagnostics_page.dart';
import 'ui/lab_page.dart';
import 'ui/record_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const DemoApp());
}

class DemoApp extends StatefulWidget {
  const DemoApp({super.key});

  @override
  State<DemoApp> createState() => _DemoAppState();
}

class _DemoAppState extends State<DemoApp> {
  final AppState state = AppState();

  @override
  void initState() {
    super.initState();
    unawaited(state.init());
  }

  @override
  void dispose() {
    state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Picaku STT Demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFE1614A),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: HomeShell(state: state),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.state});

  final AppState state;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(
            title: Text(
              switch (_tab) {
                0 => 'Picaku STT Demo',
                1 => 'Lab',
                _ => 'Diagnostics',
              },
            ),
            actions: [
              if (widget.state.activeSpec != null)
                Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: Center(
                    child: Text(
                      widget.state.activeSpec!.displayName,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
                ),
            ],
          ),
          body: SafeArea(
            child: switch (_tab) {
              0 => RecordPage(state: widget.state),
              1 => LabPage(state: widget.state),
              _ => DiagnosticsPage(state: widget.state),
            },
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (index) => setState(() => _tab = index),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.mic_none),
                selectedIcon: Icon(Icons.mic),
                label: 'Record',
              ),
              NavigationDestination(
                icon: Icon(Icons.science_outlined),
                selectedIcon: Icon(Icons.science),
                label: 'Lab',
              ),
              NavigationDestination(
                icon: Icon(Icons.monitor_heart_outlined),
                selectedIcon: Icon(Icons.monitor_heart),
                label: 'Diagnostics',
              ),
            ],
          ),
        );
      },
    );
  }
}

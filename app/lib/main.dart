import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'config/profile_store.dart';
import 'state/hmi_controller.dart';
import 'ui/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  await WakelockPlus.enable().catchError((Object _) {});

  final store = ProfileStore();
  final controller = HmiController(await store.load())..start();
  runApp(TabletHmiApp(controller: controller, store: store));
}

class TabletHmiApp extends StatelessWidget {
  const TabletHmiApp({super.key, required this.controller, required this.store});

  final HmiController controller;
  final ProfileStore store;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Codroid Tablet HMI',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1565C0), brightness: Brightness.dark),
        useMaterial3: true,
        visualDensity: VisualDensity.comfortable,
      ),
      home: HomeScreen(controller: controller, store: store),
    );
  }
}

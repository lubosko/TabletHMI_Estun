import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tablet_hmi/config/profile_store.dart';
import 'package:tablet_hmi/config/robot_profile.dart';
import 'package:tablet_hmi/state/hmi_controller.dart';
import 'package:tablet_hmi/ui/home_screen.dart';

// The controller is built but never started, so no timers or sockets run.
void main() {
  testWidgets('home screen shows programs and blocks START without a link', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    final controller = HmiController(RobotProfile.defaults());
    addTearDown(controller.dispose);

    await tester.pumpWidget(MaterialApp(
      home: HomeScreen(controller: controller, store: ProfileStore()),
    ));

    expect(find.text('Programs'), findsOneWidget);
    expect(find.text('Palletizing'), findsOneWidget);
    expect(find.text('START'), findsOneWidget);
    expect(find.text('STOP'), findsOneWidget);
    expect(find.text('NO DATA'), findsOneWidget, reason: 'no robot data yet');

    // Every command is interlocked while the robot is unreachable.
    final il = controller.interlocks;
    expect(il.canStart, isFalse);
    expect(il.canStop, isFalse);
    expect(il.startBlockedReason, 'No connection to robot');
    expect(find.textContaining('START blocked: No connection'), findsOneWidget);

    // Selecting a program works offline so the operator can pre-select.
    await tester.tap(find.text('Screwing'));
    await tester.pump();
    expect(controller.selectedNumber, 2);
    expect(find.text('Selected: Screwing'), findsOneWidget);
  });
}

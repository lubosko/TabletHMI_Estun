// Integration test of the real Modbus/WebSocket clients against the simulator.
//
//   python ../tools/robot_sim.py --host 127.0.0.1 --modbus-port 1502 --ws-port 19000
//   (PowerShell)  $env:SIM_HOST="127.0.0.1"; flutter test test/sim_integration_test.dart
//
// Skipped when SIM_HOST is not set.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tablet_hmi/comm/codroid_ws_client.dart';
import 'package:tablet_hmi/comm/modbus_tcp_client.dart';

void main() {
  final host = Platform.environment['SIM_HOST'];
  final skip = host == null ? 'SIM_HOST not set (start tools/robot_sim.py first)' : null;

  test('start, heartbeat, watchdog trip, stop', () async {
    final mb = ModbusTcpClient(host: host!, port: 1502);
    final ws = CodroidWsClient(host: host, port: 19000);
    await mb.connect();
    await ws.connect();
    await ws.call('sim', 'cmd', 'di on');

    var counter = 0;
    var beating = true;
    final hb = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (beating) mb.writeDInt(49000, ++counter, highWordFirst: true);
    });

    await mb.writeRegister(42000, 1);
    await mb.writeCoil(9902, true);
    await mb.pulseCoil(1000, const Duration(milliseconds: 100));
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(await ws.getProjectState(), 'RUNNING');
    expect((await mb.readCoils(2000, 14))[0], isTrue);
    final e1 = await mb.readDInt(49002, highWordFirst: true);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(await mb.readDInt(49002, highWordFirst: true), isNot(e1));

    beating = false;
    await Future<void>.delayed(const Duration(milliseconds: 2000));
    expect(await ws.getProjectState(), 'IDLE');
    expect((await mb.readCoils(9901, 1))[0], isTrue, reason: 'HMI_WD_TRIPPED');

    beating = true;
    await ws.runProject('Screwing');
    expect(await ws.getProjectState(), 'RUNNING');
    await mb.pulseCoil(1001, const Duration(milliseconds: 100));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(await ws.getProjectState(), 'IDLE');

    hb.cancel();
    mb.close();
    ws.close();
  }, skip: skip, timeout: const Timeout(Duration(seconds: 20)));
}

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tablet_hmi/comm/codroid_ws_client.dart';
import 'package:tablet_hmi/config/robot_profile.dart';

void main() {
  group('Codroid WebSocket messages', () {
    test('request encoding matches CodroidApi examples', () {
      final m = jsonDecode(CodroidWsClient.encodeRequest(
          7, 'projexecute', 'run', {'projectName': 'PPP', 'taskName': 'main1'})) as Map<String, dynamic>;
      expect(m, {
        'id': 7,
        'type': 'projexecute',
        'action': 'run',
        'data': {'projectName': 'PPP', 'taskName': 'main1'},
      });
      final empty = jsonDecode(CodroidWsClient.encodeRequest(1, 'projexecute', 'stop', null)) as Map;
      expect(empty['data'], <String, dynamic>{});
    });

    test('successful response', () {
      final r = CodroidResult.fromResponse({
        'id': 1,
        'type': 'projexecute',
        'action': 'getProjectState',
        'time': 1751610427211,
        'code': 200,
        'msg': '',
        'data': {'msg': '', 'code': 0, 'data': 'IDLE'},
      });
      expect(r.ok, isTrue);
      expect(r.data, 'IDLE');
    });

    test('inner error code', () {
      final r = CodroidResult.fromResponse({
        'code': 200,
        'data': {'msg': 'Remote mode not enabled.', 'code': 10074},
      });
      expect(r.ok, isFalse);
      expect(r.code, 10074);
      expect(r.msg, contains('Remote'));
    });

    test('outer error code', () {
      final r = CodroidResult.fromResponse({'code': 500, 'msg': 'server error'});
      expect(r.ok, isFalse);
      expect(r.code, 500);
    });

    test('robot states', () {
      final s = CodroidRobotStates.fromData({'robotMode': 'AutoRunning', 'safetyMode': 1, 'statusFlag': 10});
      expect(s.estop, isFalse);
      expect(s.fault, isFalse);
      final e = CodroidRobotStates.fromData({'robotMode': 'Idle', 'safetyMode': 2, 'statusFlag': 1});
      expect(e.estop, isTrue);
      expect(CodroidRobotStates.fromData({'robotMode': 'Fault', 'safetyMode': 1}).fault, isTrue);
    });
  });

  group('RobotProfile', () {
    test('JSON round trip', () {
      final p = RobotProfile.defaults(ControllerGen.gen1);
      final back = RobotProfile.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
      expect(back.toJson(), p.toJson());
      expect(back.generation, ControllerGen.gen1);
    });

    test('missing keys fall back to defaults', () {
      final p = RobotProfile.fromJson({'host': '10.0.0.5', 'generation': 'gen2'});
      expect(p.host, '10.0.0.5');
      expect(p.modbusPort, 502);
      expect(p.regStartProjectNumber, 42000);
      expect(p.programs, isNotEmpty);
    });

    test('defaults are valid', () {
      expect(RobotProfile.defaults().validate(), isEmpty);
    });

    test('validation', () {
      final j = RobotProfile.defaults().toJson()
        ..['robotTimeoutMs'] = 500
        ..['programs'] = [
          {'number': 1, 'name': 'A'},
          {'number': 1, 'name': 'B'},
        ];
      final errors = RobotProfile.fromJson(j).validate();
      expect(errors, contains('Duplicate program numbers'));
      expect(errors.any((e) => e.contains('timeout')), isTrue);
    });
  });
}

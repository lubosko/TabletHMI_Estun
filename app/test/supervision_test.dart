import 'package:flutter_test/flutter_test.dart';
import 'package:tablet_hmi/state/supervision.dart';

InterlockInput _ok({
  bool controlLinkUp = true,
  bool anyLinkUp = true,
  bool? hmiEnabled = true,
  bool estop = false,
  bool robotError = false,
  bool manualMode = false,
  ProgramState program = ProgramState.idle,
  bool commLostLatched = false,
  bool programSelected = true,
  bool busy = false,
  bool alarmPending = false,
}) =>
    InterlockInput(
      controlLinkUp: controlLinkUp,
      anyLinkUp: anyLinkUp,
      hmiEnabled: hmiEnabled,
      estop: estop,
      robotError: robotError,
      manualMode: manualMode,
      program: program,
      commLostLatched: commLostLatched,
      programSelected: programSelected,
      busy: busy,
      alarmPending: alarmPending,
    );

void main() {
  group('LinkMonitor', () {
    test('connected -> degraded -> lost and latches', () {
      final m = LinkMonitor(degradedAfterMs: 600, lostAfterMs: 1500);
      expect(m.state(0), LinkState.disconnected);
      m.onSuccess(1000);
      expect(m.state(1500), LinkState.connected);
      expect(m.state(1800), LinkState.degraded);
      expect(m.lostLatched, isFalse);
      expect(m.state(2600), LinkState.lost);
      expect(m.lostLatched, isTrue);
    });

    test('latch survives reconnect until acknowledged', () {
      final m = LinkMonitor(degradedAfterMs: 600, lostAfterMs: 1500);
      m.onSuccess(0);
      m.onDisconnected(100);
      expect(m.state(100), LinkState.lost);
      expect(m.acknowledge(200), isFalse, reason: 'cannot acknowledge while down');
      m.onSuccess(300);
      expect(m.lostLatched, isTrue);
      expect(m.acknowledge(300), isTrue);
      expect(m.lostLatched, isFalse);
    });

    test('never connected is not a latched loss', () {
      final m = LinkMonitor(degradedAfterMs: 600, lostAfterMs: 1500);
      m.onDisconnected(0);
      expect(m.state(0), LinkState.disconnected);
      expect(m.lostLatched, isFalse);
    });
  });

  group('EchoMonitor', () {
    test('alive when echo keeps changing', () {
      final e = EchoMonitor(staleMs: 1000)..update(5, 0);
      e.arm(0);
      expect(e.check(100), EchoVerdict.waitingFirstEcho);
      e.update(6, 200);
      expect(e.check(300), EchoVerdict.alive);
      e.update(7, 400);
      expect(e.check(1300), EchoVerdict.alive);
    });

    test('missing watchdog when no echo after arming', () {
      final e = EchoMonitor(staleMs: 1000)..update(5, 0);
      e.arm(0);
      e.update(5, 500);
      expect(e.check(1001), EchoVerdict.missingWatchdog);
    });

    test('stale when echo stops', () {
      final e = EchoMonitor(staleMs: 1000)..update(1, 0);
      e.arm(0);
      e.update(2, 100);
      expect(e.check(1000), EchoVerdict.alive);
      expect(e.check(1101), EchoVerdict.stale);
    });

    test('echo change before arming does not count', () {
      final e = EchoMonitor(staleMs: 1000)..update(1, 0);
      e.update(2, 100);
      e.arm(200);
      expect(e.check(1201), EchoVerdict.missingWatchdog);
    });

    test('not armed', () {
      expect(EchoMonitor(staleMs: 1000).check(0), EchoVerdict.notArmed);
    });
  });

  group('Interlocks', () {
    test('all conditions ok -> start enabled', () {
      final il = Interlocks.evaluate(_ok());
      expect(il.canStart, isTrue);
      expect(il.startBlockedReason, isNull);
      expect(il.canStop, isTrue);
    });

    test('start blocked reasons', () {
      expect(Interlocks.evaluate(_ok(controlLinkUp: false)).canStart, isFalse);
      expect(Interlocks.evaluate(_ok(commLostLatched: true)).canStart, isFalse);
      expect(Interlocks.evaluate(_ok(hmiEnabled: false)).startBlockedReason, contains('OFF'));
      expect(Interlocks.evaluate(_ok(hmiEnabled: null)).canStart, isFalse);
      expect(Interlocks.evaluate(_ok(estop: true)).startBlockedReason, 'E-stop pressed');
      expect(Interlocks.evaluate(_ok(robotError: true)).canStart, isFalse);
      expect(Interlocks.evaluate(_ok(manualMode: true)).canStart, isFalse);
      expect(Interlocks.evaluate(_ok(program: ProgramState.running)).canStart, isFalse);
      expect(Interlocks.evaluate(_ok(programSelected: false)).startBlockedReason, 'Select a program');
      expect(Interlocks.evaluate(_ok(busy: true)).canStart, isFalse);
    });

    test('STOP available whenever any link is up, even if HMI OFF or busy', () {
      final il = Interlocks.evaluate(_ok(hmiEnabled: false, busy: true, controlLinkUp: false));
      expect(il.canStop, isTrue);
      expect(Interlocks.evaluate(_ok(anyLinkUp: false)).canStop, isFalse);
    });

    test('pause / resume', () {
      expect(Interlocks.evaluate(_ok(program: ProgramState.running)).canPause, isTrue);
      expect(Interlocks.evaluate(_ok(program: ProgramState.idle)).canPause, isFalse);
      expect(Interlocks.evaluate(_ok(program: ProgramState.paused)).canResume, isTrue);
      expect(Interlocks.evaluate(_ok(program: ProgramState.paused, commLostLatched: true)).canResume, isFalse);
      expect(Interlocks.evaluate(_ok(program: ProgramState.paused, hmiEnabled: false)).canResume, isFalse);
    });

    test('clear only with something to clear', () {
      expect(Interlocks.evaluate(_ok()).canClear, isFalse);
      expect(Interlocks.evaluate(_ok(alarmPending: true)).canClear, isTrue);
      expect(Interlocks.evaluate(_ok(robotError: true)).canClear, isTrue);
    });
  });

  test('Codroid project state mapping', () {
    expect(programStateFromCodroid('RUNNING'), ProgramState.running);
    expect(programStateFromCodroid('PAUSE'), ProgramState.paused);
    expect(programStateFromCodroid('IDLE'), ProgramState.idle);
    expect(programStateFromCodroid('LOADING'), ProgramState.loading);
    expect(programStateFromCodroid('ERROR'), ProgramState.error);
    expect(programStateFromCodroid('???'), ProgramState.unknown);
  });
}

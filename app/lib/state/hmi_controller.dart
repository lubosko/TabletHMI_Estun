import 'dart:async';

import 'package:flutter/foundation.dart';

import '../comm/codroid_ws_client.dart';
import '../comm/modbus_tcp_client.dart';
import '../config/robot_profile.dart';
import 'supervision.dart';

class LogEntry {
  LogEntry(this.text, {this.alarm = false}) : time = DateTime.now();
  final DateTime time;
  final String text;
  final bool alarm;
}

/// Status coil offsets from statusCoilBase (Communication Manual V2.3, 10.3.2).
abstract final class StatusCoil {
  static const running = 0, stopped = 1, paused = 2, switchOn = 3, switchOff = 4, manual = 5;
  static const dragging = 6, moving = 7, collision = 8, safetyPos = 9, warning = 10;
  static const simulation = 11, estop = 12, rescue = 13;
  static const count = 14;
}

/// Owns both robot connections, the heartbeat, polling, supervision and all
/// operator commands. The UI only reads getters and calls command methods.
class HmiController extends ChangeNotifier {
  HmiController(RobotProfile profile) : _profile = profile {
    _build();
  }

  RobotProfile _profile;
  RobotProfile get profile => _profile;

  late ModbusTcpClient _mb;
  late CodroidWsClient _ws;
  late LinkMonitor _mbLink;
  late LinkMonitor _wsLink;
  late EchoMonitor _echo;

  Timer? _hbTimer;
  Timer? _pollTimer;
  bool _polling = false;
  bool _mbConnecting = false;
  bool _wsConnecting = false;
  int _mbRetryAt = 0;
  int _wsRetryAt = 0;
  int _hbCounter = 0;
  bool _hbSuspended = false;
  bool _disposed = false;

  // ---- observed robot state ---------------------------------------------
  List<bool> _status = List<bool>.filled(StatusCoil.count, false);
  bool _statusValid = false;
  String? _wsProjectState;
  CodroidRobotStates? _robotStates;
  bool? _diFromWs;
  bool? _enabledCoil;
  bool _wdTripped = false;
  bool _wdTrippedSeen = false;
  ProgramState _program = ProgramState.unknown;
  LinkState _lastMbState = LinkState.disconnected;
  LinkState _lastWsState = LinkState.disconnected;
  bool _lastLatched = false;
  String? _lastMbError;

  // ---- tablet-side state ------------------------------------------------
  int? _selectedNumber;
  int? _activeNumber;
  bool _startedByTablet = false;
  int? _startRequestedAt;
  bool _busy = false;
  String? _alarm;
  bool _watchdogTestActive = false;
  String? _watchdogTestResult;
  final List<LogEntry> _log = [];

  static int _now() => DateTime.now().millisecondsSinceEpoch;

  void _build() {
    final p = _profile;
    _mb = ModbusTcpClient(host: p.host, port: p.modbusPort, unitId: p.unitId);
    _ws = CodroidWsClient(host: p.host, port: p.wsPort);
    // Control link is "lost" at the same time the robot watchdog trips.
    _mbLink = LinkMonitor(degradedAfterMs: p.heartbeatPeriodMs * 3, lostAfterMs: p.robotTimeoutMs);
    _wsLink = LinkMonitor(degradedAfterMs: p.pollPeriodMs * 4, lostAfterMs: p.robotTimeoutMs * 2);
    _echo = EchoMonitor(staleMs: p.echoTimeoutMs);
  }

  // ---- lifecycle ----------------------------------------------------------
  void start() {
    final p = _profile;
    _hbTimer = Timer.periodic(Duration(milliseconds: p.heartbeatPeriodMs), (_) => _heartbeat());
    _pollTimer = Timer.periodic(Duration(milliseconds: p.pollPeriodMs), (_) => _poll());
    _log.add(LogEntry('HMI started - robot ${p.host} (${p.generation.name})'));
    _poll();
  }

  void _stopTimers() {
    _hbTimer?.cancel();
    _pollTimer?.cancel();
    _hbTimer = null;
    _pollTimer = null;
  }

  Future<void> applyProfile(RobotProfile p) async {
    _stopTimers();
    _mb.close();
    _ws.close();
    _profile = p;
    _build();
    _statusValid = false;
    _wsProjectState = null;
    _robotStates = null;
    _diFromWs = null;
    _enabledCoil = null;
    _program = ProgramState.unknown;
    _selectedNumber = null;
    _mbRetryAt = 0;
    _wsRetryAt = 0;
    _logEvent('Settings applied');
    start();
  }

  @override
  void dispose() {
    _disposed = true;
    _stopTimers();
    _mb.close();
    _ws.close();
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  // ---- getters for the UI -------------------------------------------------
  LinkState get modbusState => _mbLink.state(_now());
  LinkState get wsState => _wsLink.state(_now());
  bool get commLostLatched => _mbLink.lostLatched;
  ProgramState get program => _program;
  bool? get hmiEnabled => _hmiEnabled();
  bool get estop => (_statusValid && _status[StatusCoil.estop]) || (_robotStates?.estop ?? false);
  bool get robotError => _wsProjectState == 'ERROR' || (_robotStates?.fault ?? false);
  bool get manualMode => _statusValid && _status[StatusCoil.manual];
  bool get warning => _statusValid && _status[StatusCoil.warning];
  bool get wdTripped => _wdTripped;
  String? get robotMode => _robotStates?.robotMode;
  EchoVerdict get watchdogVerdict => _echo.check(_now());
  bool get busy => _busy;
  String? get alarm => _alarm;
  int? get selectedNumber => _selectedNumber;
  ProgramEntry? get activeProgram => _entry(_activeNumber);
  ProgramEntry? get selectedProgram => _entry(_selectedNumber);
  bool get watchdogTestActive => _watchdogTestActive;
  String? get watchdogTestResult => _watchdogTestResult;
  List<LogEntry> get log => List.unmodifiable(_log.reversed);

  ProgramEntry? _entry(int? n) {
    if (n == null) return null;
    for (final e in _profile.programs) {
      if (e.number == n) return e;
    }
    return null;
  }

  Interlocks get interlocks {
    final now = _now();
    return Interlocks.evaluate(InterlockInput(
      controlLinkUp: _mbLink.isUp(now) && _mb.isConnected,
      anyLinkUp: (_mbLink.isUp(now) && _mb.isConnected) || (_wsLink.isUp(now) && _ws.isConnected),
      hmiEnabled: _hmiEnabled(),
      estop: estop,
      robotError: robotError,
      manualMode: manualMode,
      program: _program,
      commLostLatched: commLostLatched,
      programSelected: _selectedNumber != null,
      busy: _busy,
      alarmPending: warning || _wdTripped || _alarm != null,
    ));
  }

  bool? _hmiEnabled() {
    final now = _now();
    if (_wsLink.isUp(now) && _diFromWs != null) return _diFromWs;
    // The watchdog mirrors the DI only while a program runs.
    if (_mbLink.isUp(now) && _program == ProgramState.running) return _enabledCoil;
    return null;
  }

  // ---- heartbeat ----------------------------------------------------------
  Future<void> _heartbeat() async {
    if (_hbSuspended || !_mb.isConnected) return;
    final p = _profile;
    _hbCounter = (_hbCounter + 1) & 0x7FFF;
    try {
      await _mb.writeDInt(p.regHeartbeat, _hbCounter, highWordFirst: p.dintHighWordFirst);
      final hbm = p.regHeartBeatFromMaster;
      if (hbm != null) await _mb.writeRegister(hbm, _hbCounter);
      _mbLink.onSuccess(_now());
    } on Object catch (e) {
      _onModbusError(e);
    }
  }

  // ---- polling ------------------------------------------------------------
  Future<void> _poll() async {
    if (_polling || _disposed) return;
    _polling = true;
    try {
      _ensureConnections();
      await Future.wait([_pollModbus(), _pollWs()]);
      _evaluate();
    } finally {
      _polling = false;
      _notify();
    }
  }

  void _ensureConnections() {
    final now = _now();
    if (!_mb.isConnected && !_mbConnecting && now >= _mbRetryAt) {
      _mbConnecting = true;
      unawaited(_mb.connect().then((_) {
        _mbLink.onSuccess(_now());
      }, onError: (Object e) {
        _mbLink.onDisconnected(_now());
        _mbRetryAt = _now() + 1000;
      }).whenComplete(() => _mbConnecting = false));
    }
    if (!_ws.isConnected && !_wsConnecting && now >= _wsRetryAt) {
      _wsConnecting = true;
      unawaited(_ws.connect().then((_) {
        _wsLink.onSuccess(_now());
      }, onError: (Object e) {
        _wsLink.onDisconnected(_now());
        _wsRetryAt = _now() + 1000;
      }).whenComplete(() => _wsConnecting = false));
    }
  }

  Future<void> _pollModbus() async {
    if (!_mb.isConnected) return;
    final p = _profile;
    try {
      final status = await _mb.readCoils(p.statusCoilBase, StatusCoil.count);
      bool enabled;
      bool tripped;
      if (p.coilWdTripped == p.coilEnabled + 1) {
        final f = await _mb.readCoils(p.coilEnabled, 2);
        enabled = f[0];
        tripped = f[1];
      } else {
        enabled = (await _mb.readCoils(p.coilEnabled, 1))[0];
        tripped = (await _mb.readCoils(p.coilWdTripped, 1))[0];
      }
      final echo = await _mb.readDInt(p.regHeartbeatEcho, highWordFirst: p.dintHighWordFirst);
      final now = _now();
      _status = status;
      _statusValid = true;
      _enabledCoil = enabled;
      _wdTripped = tripped;
      _echo.update(echo, now);
      _mbLink.onSuccess(now);
      _lastMbError = null;
    } on Object catch (e) {
      _onModbusError(e);
    }
  }

  void _onModbusError(Object e) {
    final text = e.toString();
    if (text != _lastMbError) {
      _lastMbError = text;
      _logEvent('Modbus error: $text', alarm: true);
    }
    if (!_mb.isConnected) {
      _mbLink.onDisconnected(_now());
      _statusValid = false;
      _mbRetryAt = _now() + 500;
    }
  }

  Future<void> _pollWs() async {
    if (!_ws.isConnected) return;
    try {
      final state = await _ws.getProjectState();
      final robot = await _ws.getRobotStates();
      _wsProjectState = state;
      _robotStates = robot;
      _wsLink.onSuccess(_now());
      try {
        _diFromWs = await _ws.getDI(_profile.enableDiPort);
      } on CodroidApiException {
        _diFromWs = null; // getDI not supported: fall back to HMI_ENABLED register
      }
    } on Object {
      if (!_ws.isConnected) {
        _wsLink.onDisconnected(_now());
        _wsProjectState = null;
        _robotStates = null;
        _diFromWs = null;
      }
    }
  }

  // ---- supervision --------------------------------------------------------
  void _evaluate() {
    final now = _now();
    final p = _profile;
    final mbUp = _mbLink.isUp(now) && _mb.isConnected;
    final wsUp = _wsLink.isUp(now) && _ws.isConnected;

    // Link transitions -> event log
    final mbState = _mbLink.state(now);
    if (mbState != _lastMbState) {
      _logEvent('Modbus link: ${mbState.name}', alarm: mbState == LinkState.lost);
      _lastMbState = mbState;
    }
    final wsState = _wsLink.state(now);
    if (wsState != _lastWsState) {
      _logEvent('WebSocket link: ${wsState.name}', alarm: wsState == LinkState.lost);
      _lastWsState = wsState;
    }
    if (commLostLatched && !_lastLatched) {
      _logEvent('COMMUNICATION LOST - robot watchdog stops the program', alarm: true);
    }
    _lastLatched = commLostLatched;

    // Program state: WebSocket text is richer; Modbus status coils as fallback.
    final previous = _program;
    if (wsUp && _wsProjectState != null) {
      _program = programStateFromCodroid(_wsProjectState!);
    } else if (mbUp && _statusValid) {
      _program = _status[StatusCoil.running]
          ? ProgramState.running
          : _status[StatusCoil.paused]
              ? ProgramState.paused
              : ProgramState.idle;
    } else {
      _program = ProgramState.unknown;
    }
    if (_program != previous) _logEvent('Program state: ${_program.name}');

    // START confirmation
    final requested = _startRequestedAt;
    if (requested != null) {
      if (_program == ProgramState.running) {
        _startRequestedAt = null;
      } else if (now - requested > p.startConfirmMs) {
        _startRequestedAt = null;
        _startedByTablet = false;
        _raise('Start not confirmed by robot within ${p.startConfirmMs} ms '
            '(check mode Auto/Remote, Project Mapping, robot alarms)');
        if (_mb.isConnected) unawaited(_mb.writeCoil(p.coilTabletStart, false).catchError((Object _) {}));
      }
    }
    if (_startRequestedAt == null &&
        (_program == ProgramState.idle || _program == ProgramState.error) &&
        _startedByTablet) {
      _startedByTablet = false;
    }

    // Robot watchdog tripped (rising edge)
    if (_wdTripped && !_wdTrippedSeen && !_watchdogTestActive) {
      _raise('Robot watchdog stopped the program (tablet heartbeat lost or HMI switched OFF)');
    }
    _wdTrippedSeen = _wdTripped;

    // Echo supervision: is the watchdog thread alive in the running program?
    final supervised = _hmiEnabled() == true || _startedByTablet;
    if (mbUp && _program == ProgramState.running && supervised && !_watchdogTestActive) {
      if (!_echo.armed) _echo.arm(now);
      switch (_echo.check(now)) {
        case EchoVerdict.missingWatchdog:
          _echo.disarm();
          _raise('Program has no HMI watchdog thread - stopped for safety');
          unawaited(stopProgram(reason: 'Auto STOP: no watchdog echo'));
        case EchoVerdict.stale:
          _echo.disarm();
          _raise('Robot watchdog stopped responding - program stopped');
          unawaited(stopProgram(reason: 'Auto STOP: watchdog echo stale'));
        default:
          break;
      }
    } else if (_program != ProgramState.running) {
      _echo.disarm();
    }
  }

  // ---- commands -----------------------------------------------------------
  void selectProgram(int number) {
    if (_program == ProgramState.running || _program == ProgramState.paused) return;
    _selectedNumber = number;
    _notify();
  }

  Future<void> startSelected() async {
    final entry = selectedProgram;
    if (entry == null || !interlocks.canStart) return;
    final p = _profile;
    await _command('START #${entry.number} ${entry.name}', () async {
      await _mb.writeRegister(p.regStartProjectNumber, entry.number);
      await _mb.writeCoil(p.coilTabletStart, true);
      await _mb.pulseCoil(p.coilStartProject, Duration(milliseconds: p.pulseMs));
      _startedByTablet = true;
      _activeNumber = entry.number;
      _startRequestedAt = _now();
      _alarm = null;
    });
  }

  /// Sent on every available channel; never blocked by [busy].
  Future<void> stopProgram({String reason = 'STOP'}) async {
    final p = _profile;
    _logEvent(reason);
    _startRequestedAt = null;
    final attempts = <Future<bool>>[
      if (_mb.isConnected)
        _mb.pulseCoil(p.coilStopProject, Duration(milliseconds: p.pulseMs)).then((_) => true, onError: (Object _) => false),
      if (_ws.isConnected)
        _ws.stopProject().then((_) => _ws.stopMove()).then((_) => true, onError: (Object _) => false),
    ];
    final ok = attempts.isNotEmpty && (await Future.wait(attempts)).any((x) => x);
    if (!ok) _raise('STOP could not be sent to the robot - use the E-stop!');
    _notify();
  }

  Future<void> pause() => _command('PAUSE', () async {
        if (_mb.isConnected) {
          await _mb.pulseCoil(_profile.coilPauseProject, Duration(milliseconds: _profile.pulseMs));
        } else {
          await _ws.pauseProject();
        }
      });

  Future<void> resume() => _command('RESUME', () async {
        if (_profile.resumeViaStartCoil && _mb.isConnected) {
          await _mb.pulseCoil(_profile.coilStartProject, Duration(milliseconds: _profile.pulseMs));
        } else {
          await _ws.resumeProject();
        }
      });

  Future<void> clearAlarm() => _command('CLEAR ALARM', () async {
        if (_mb.isConnected) {
          await _mb.pulseCoil(_profile.coilClearWarning, Duration(milliseconds: _profile.pulseMs));
        }
        if (_ws.isConnected) {
          await _ws.sendCommand(501).catchError((Object _) {}); // ClearWarning
          if (robotError) await _ws.sendCommand(100); // ClearError
        }
        _alarm = null;
      });

  void acknowledgeCommLost() {
    if (_mbLink.acknowledge(_now())) {
      _logEvent('COMMUNICATION LOST acknowledged');
      _notify();
    }
  }

  /// Commissioning: stop sending heartbeats and verify the robot stops.
  Future<void> runWatchdogTest() async {
    if (_watchdogTestActive) return;
    if (_program != ProgramState.running) {
      _watchdogTestResult = 'Start a program from the tablet first';
      _notify();
      return;
    }
    final p = _profile;
    _watchdogTestActive = true;
    _echo.disarm();
    _hbSuspended = true;
    _watchdogTestResult = 'Running - heartbeat paused...';
    _logEvent('Watchdog test started');
    _notify();
    final t0 = _now();
    final limit = p.robotTimeoutMs + 2000;
    while (_now() - t0 < limit && _program == ProgramState.running) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    final dt = _now() - t0;
    _hbSuspended = false;
    final failed = _program == ProgramState.running;
    if (failed) {
      _watchdogTestResult = 'FAIL: program still running after $dt ms - stopping it. '
          'Add the watchdog thread to this project.';
      await stopProgram(reason: 'Watchdog test FAILED');
    } else {
      _watchdogTestResult = 'PASS: robot stopped after $dt ms (timeout ${p.robotTimeoutMs} ms)';
    }
    _logEvent('Watchdog test: $_watchdogTestResult', alarm: failed);
    _watchdogTestActive = false;
    _notify();
  }

  Future<void> _command(String label, Future<void> Function() action) async {
    if (_busy) return;
    _busy = true;
    _logEvent(label);
    _notify();
    try {
      await action();
    } on Object catch (e) {
      _raise('$label failed: $e');
    } finally {
      _busy = false;
      _notify();
    }
  }

  void _raise(String text) {
    _alarm = text;
    _logEvent(text, alarm: true);
  }

  void _logEvent(String text, {bool alarm = false}) {
    _log.add(LogEntry(text, alarm: alarm));
    if (_log.length > 500) _log.removeRange(0, _log.length - 500);
    if (kDebugMode) debugPrint('[HMI] $text');
  }
}

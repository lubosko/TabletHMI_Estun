/// Pure, time-injected supervision logic (unit tested without sockets).
library;

enum LinkState { disconnected, connected, degraded, lost }

/// Tracks one communication channel from the time of its last successful
/// exchange and latches COMMUNICATION LOST until the operator acknowledges.
class LinkMonitor {
  LinkMonitor({required this.degradedAfterMs, required this.lostAfterMs});

  final int degradedAfterMs;
  final int lostAfterMs;

  int? _lastOkMs;
  bool _wasConnected = false;
  bool _latched = false;

  bool get lostLatched => _latched;

  void onSuccess(int nowMs) {
    _lastOkMs = nowMs;
    _wasConnected = true;
  }

  /// Socket closed / connect failed: the link is lost immediately.
  void onDisconnected(int nowMs) {
    if (_wasConnected) _latched = true;
    _lastOkMs = null;
  }

  LinkState state(int nowMs) {
    final last = _lastOkMs;
    if (last == null) return _wasConnected ? LinkState.lost : LinkState.disconnected;
    final age = nowMs - last;
    if (age <= degradedAfterMs) return LinkState.connected;
    if (age <= lostAfterMs) return LinkState.degraded;
    _latched = true;
    return LinkState.lost;
  }

  bool isUp(int nowMs) {
    final s = state(nowMs);
    return s == LinkState.connected || s == LinkState.degraded;
  }

  /// Clears the latch; only possible while the link is up again.
  bool acknowledge(int nowMs) {
    if (!isUp(nowMs)) return false;
    _latched = false;
    return true;
  }
}

enum EchoVerdict { notArmed, waitingFirstEcho, alive, missingWatchdog, stale }

/// Checks that the robot-side watchdog thread echoes the heartbeat counter.
///
/// Armed while a supervised program runs. If no echo change is seen within
/// [staleMs] after arming, the program has no watchdog thread; if echoes stop
/// later, the watchdog thread died.
class EchoMonitor {
  EchoMonitor({required this.staleMs});

  final int staleMs;

  int? _lastEcho;
  int _lastChangeMs = 0;
  int? _armedAtMs;
  bool _sawChange = false;

  bool get armed => _armedAtMs != null;

  void arm(int nowMs) {
    _armedAtMs = nowMs;
    _lastChangeMs = nowMs;
    _sawChange = false;
  }

  void disarm() => _armedAtMs = null;

  void update(int echo, int nowMs) {
    if (_lastEcho != null && echo != _lastEcho) {
      _lastChangeMs = nowMs;
      if (armed) _sawChange = true;
    }
    _lastEcho = echo;
  }

  EchoVerdict check(int nowMs) {
    final armedAt = _armedAtMs;
    if (armedAt == null) return EchoVerdict.notArmed;
    if (!_sawChange) {
      return nowMs - armedAt > staleMs ? EchoVerdict.missingWatchdog : EchoVerdict.waitingFirstEcho;
    }
    return nowMs - _lastChangeMs > staleMs ? EchoVerdict.stale : EchoVerdict.alive;
  }
}

enum ProgramState { unknown, idle, loading, running, paused, error }

ProgramState programStateFromCodroid(String s) => switch (s.toUpperCase()) {
      'IDLE' => ProgramState.idle,
      'LOADING' => ProgramState.loading,
      'RUNNING' => ProgramState.running,
      'PAUSE' || 'PAUSED' => ProgramState.paused,
      'ERROR' => ProgramState.error,
      _ => ProgramState.unknown,
    };

class InterlockInput {
  const InterlockInput({
    required this.controlLinkUp,
    required this.anyLinkUp,
    required this.hmiEnabled,
    required this.estop,
    required this.robotError,
    required this.manualMode,
    required this.program,
    required this.commLostLatched,
    required this.programSelected,
    required this.busy,
    required this.alarmPending,
  });

  /// Modbus (control channel) is up.
  final bool controlLinkUp;

  /// Modbus or WebSocket is up (enough to send STOP).
  final bool anyLinkUp;

  /// Enable DI state; null = unknown.
  final bool? hmiEnabled;
  final bool estop;
  final bool robotError;
  final bool manualMode;
  final ProgramState program;
  final bool commLostLatched;
  final bool programSelected;
  final bool busy;
  final bool alarmPending;
}

class Interlocks {
  const Interlocks({
    required this.canStart,
    required this.canStop,
    required this.canPause,
    required this.canResume,
    required this.canClear,
    this.startBlockedReason,
  });

  final bool canStart;
  final bool canStop;
  final bool canPause;
  final bool canResume;
  final bool canClear;
  final String? startBlockedReason;

  static Interlocks evaluate(InterlockInput i) {
    String? reason;
    if (!i.controlLinkUp) {
      reason = 'No connection to robot';
    } else if (i.commLostLatched) {
      reason = 'Acknowledge COMMUNICATION LOST first';
    } else if (i.hmiEnabled != true) {
      reason = i.hmiEnabled == null ? 'HMI enable state unknown' : 'Tablet HMI is switched OFF on the robot';
    } else if (i.estop) {
      reason = 'E-stop pressed';
    } else if (i.robotError) {
      reason = 'Robot in error - clear alarm first';
    } else if (i.manualMode) {
      reason = 'Robot is in manual mode';
    } else if (i.program != ProgramState.idle) {
      reason = 'A program is already active';
    } else if (!i.programSelected) {
      reason = 'Select a program';
    } else if (i.busy) {
      reason = 'Command in progress';
    }

    final supervisedOk = i.controlLinkUp && i.hmiEnabled == true && !i.busy;
    return Interlocks(
      canStart: reason == null,
      canStop: i.anyLinkUp,
      canPause: supervisedOk && i.program == ProgramState.running,
      canResume: supervisedOk &&
          i.program == ProgramState.paused &&
          !i.commLostLatched &&
          !i.estop &&
          !i.robotError,
      canClear: i.anyLinkUp && !i.busy && (i.robotError || i.alarmPending),
      startBlockedReason: reason,
    );
  }
}

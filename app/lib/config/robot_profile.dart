/// Controller profile: connection, register addresses, timing and program
/// table for one robot. Stored as JSON and editable in Settings.
///
/// Register defaults follow the ESTUN Codroid+ Communication Manual V2.3
/// (section 10.3) and robot/TabletHMI_watchdog.lua. Confirm them on each
/// controller (PRD Phase 0) - the manual states the table is for SW V2.3.
library;

enum ControllerGen { gen1, gen2 }

class ProgramEntry {
  const ProgramEntry({required this.number, required this.name});

  /// Codroid "Project Mapping" index used with startProjectNumber (42000).
  final int number;

  /// Display name; also used as projectName for WebSocket fallbacks.
  final String name;

  Map<String, dynamic> toJson() => {'number': number, 'name': name};

  factory ProgramEntry.fromJson(Map<String, dynamic> j) =>
      ProgramEntry(number: (j['number'] as num).toInt(), name: j['name'] as String);
}

class RobotProfile {
  const RobotProfile({
    required this.robotName,
    required this.generation,
    required this.host,
    required this.modbusPort,
    required this.wsPort,
    required this.unitId,
    required this.enableDiPort,
    required this.regHeartbeat,
    required this.regHeartbeatEcho,
    required this.coilEnabled,
    required this.coilWdTripped,
    required this.coilTabletStart,
    required this.regHeartBeatFromMaster,
    required this.regStartProjectNumber,
    required this.coilStartProject,
    required this.coilStopProject,
    required this.coilPauseProject,
    required this.coilClearWarning,
    required this.statusCoilBase,
    required this.dintHighWordFirst,
    required this.resumeViaStartCoil,
    required this.heartbeatPeriodMs,
    required this.pollPeriodMs,
    required this.robotTimeoutMs,
    required this.echoTimeoutMs,
    required this.startConfirmMs,
    required this.pulseMs,
    required this.settingsPin,
    required this.programs,
  });

  final String robotName;
  final ControllerGen generation;

  // Connection
  final String host;
  final int modbusPort;
  final int wsPort;
  final int unitId;

  /// DI port of the robot-side "Tablet HMI ON/OFF" key switch or forced DI.
  final int enableDiPort;

  // User registers shared with the watchdog script
  final int regHeartbeat; // DInt rw, tablet -> robot
  final int regHeartbeatEcho; // DInt, robot -> tablet
  final int coilEnabled; // Bool, robot -> tablet (mirror of enable DI)
  final int coilWdTripped; // Bool, robot -> tablet
  final int coilTabletStart; // Bool rw, tablet -> robot (ownership flag)

  /// Native heartBeatFromMaster register (strict mode). null = do not write.
  final int? regHeartBeatFromMaster;

  // System registers (Communication Manual V2.3, 10.3)
  final int regStartProjectNumber; // 42000
  final int coilStartProject; // 1000
  final int coilStopProject; // 1001
  final int coilPauseProject; // 1002
  final int coilClearWarning; // 1005
  final int statusCoilBase; // 2000 (2000..2013)

  /// DInt word order on the Modbus slave (confirm in Phase 0).
  final bool dintHighWordFirst;

  /// true: resume by pulsing startProject while paused; false: WebSocket resume.
  final bool resumeViaStartCoil;

  // Timing (ms)
  final int heartbeatPeriodMs;
  final int pollPeriodMs;

  /// Must equal TIMEOUT_MS in TabletHMI_watchdog.lua.
  final int robotTimeoutMs;

  /// Max time without watchdog echo change while supervised before the tablet stops the program.
  final int echoTimeoutMs;

  /// Max time from START until the program must report running.
  final int startConfirmMs;
  final int pulseMs;

  final String settingsPin;
  final List<ProgramEntry> programs;

  /// Build-time overrides for bench testing against tools/robot_sim.py, e.g.
  /// `flutter run --dart-define=HMI_HOST=10.0.2.2 --dart-define=HMI_MODBUS_PORT=1502`.
  /// They only seed the defaults; Settings still wins once saved.
  static const _defaultHost = String.fromEnvironment('HMI_HOST', defaultValue: '192.168.101.100');
  static const _defaultModbusPort = int.fromEnvironment('HMI_MODBUS_PORT', defaultValue: 502);
  static const _defaultWsPort = int.fromEnvironment('HMI_WS_PORT', defaultValue: 9000);

  factory RobotProfile.defaults([ControllerGen gen = ControllerGen.gen2]) => RobotProfile(
        robotName: gen == ControllerGen.gen1 ? 'Codroid Gen1' : 'Codroid Gen2',
        generation: gen,
        host: _defaultHost,
        modbusPort: _defaultModbusPort,
        wsPort: _defaultWsPort,
        unitId: 1,
        enableDiPort: 15,
        regHeartbeat: 49000,
        regHeartbeatEcho: 49002,
        coilEnabled: 9900,
        coilWdTripped: 9901,
        coilTabletStart: 9902,
        regHeartBeatFromMaster: null,
        regStartProjectNumber: 42000,
        coilStartProject: 1000,
        coilStopProject: 1001,
        coilPauseProject: 1002,
        coilClearWarning: 1005,
        statusCoilBase: 2000,
        dintHighWordFirst: true,
        resumeViaStartCoil: false,
        heartbeatPeriodMs: 200,
        pollPeriodMs: 200,
        robotTimeoutMs: 1500,
        echoTimeoutMs: 1000,
        startConfirmMs: 3000,
        pulseMs: 200,
        settingsPin: '1234',
        programs: const [
          ProgramEntry(number: 1, name: 'Palletizing'),
          ProgramEntry(number: 2, name: 'Screwing'),
          ProgramEntry(number: 3, name: 'Pick_and_Place'),
        ],
      );

  Map<String, dynamic> toJson() => {
        'robotName': robotName,
        'generation': generation.name,
        'host': host,
        'modbusPort': modbusPort,
        'wsPort': wsPort,
        'unitId': unitId,
        'enableDiPort': enableDiPort,
        'regHeartbeat': regHeartbeat,
        'regHeartbeatEcho': regHeartbeatEcho,
        'coilEnabled': coilEnabled,
        'coilWdTripped': coilWdTripped,
        'coilTabletStart': coilTabletStart,
        'regHeartBeatFromMaster': regHeartBeatFromMaster,
        'regStartProjectNumber': regStartProjectNumber,
        'coilStartProject': coilStartProject,
        'coilStopProject': coilStopProject,
        'coilPauseProject': coilPauseProject,
        'coilClearWarning': coilClearWarning,
        'statusCoilBase': statusCoilBase,
        'dintHighWordFirst': dintHighWordFirst,
        'resumeViaStartCoil': resumeViaStartCoil,
        'heartbeatPeriodMs': heartbeatPeriodMs,
        'pollPeriodMs': pollPeriodMs,
        'robotTimeoutMs': robotTimeoutMs,
        'echoTimeoutMs': echoTimeoutMs,
        'startConfirmMs': startConfirmMs,
        'pulseMs': pulseMs,
        'settingsPin': settingsPin,
        'programs': programs.map((p) => p.toJson()).toList(),
      };

  /// Missing keys fall back to the defaults so older saved profiles still load.
  factory RobotProfile.fromJson(Map<String, dynamic> j) {
    final gen = ControllerGen.values.firstWhere(
      (g) => g.name == j['generation'],
      orElse: () => ControllerGen.gen2,
    );
    final d = RobotProfile.defaults(gen);
    int i(String k, int def) => (j[k] as num?)?.toInt() ?? def;
    bool b(String k, bool def) => j[k] as bool? ?? def;
    final hbm = j.containsKey('regHeartBeatFromMaster')
        ? (j['regHeartBeatFromMaster'] as num?)?.toInt()
        : d.regHeartBeatFromMaster;
    return RobotProfile(
      robotName: j['robotName'] as String? ?? d.robotName,
      generation: gen,
      host: j['host'] as String? ?? d.host,
      modbusPort: i('modbusPort', d.modbusPort),
      wsPort: i('wsPort', d.wsPort),
      unitId: i('unitId', d.unitId),
      enableDiPort: i('enableDiPort', d.enableDiPort),
      regHeartbeat: i('regHeartbeat', d.regHeartbeat),
      regHeartbeatEcho: i('regHeartbeatEcho', d.regHeartbeatEcho),
      coilEnabled: i('coilEnabled', d.coilEnabled),
      coilWdTripped: i('coilWdTripped', d.coilWdTripped),
      coilTabletStart: i('coilTabletStart', d.coilTabletStart),
      regHeartBeatFromMaster: hbm,
      regStartProjectNumber: i('regStartProjectNumber', d.regStartProjectNumber),
      coilStartProject: i('coilStartProject', d.coilStartProject),
      coilStopProject: i('coilStopProject', d.coilStopProject),
      coilPauseProject: i('coilPauseProject', d.coilPauseProject),
      coilClearWarning: i('coilClearWarning', d.coilClearWarning),
      statusCoilBase: i('statusCoilBase', d.statusCoilBase),
      dintHighWordFirst: b('dintHighWordFirst', d.dintHighWordFirst),
      resumeViaStartCoil: b('resumeViaStartCoil', d.resumeViaStartCoil),
      heartbeatPeriodMs: i('heartbeatPeriodMs', d.heartbeatPeriodMs),
      pollPeriodMs: i('pollPeriodMs', d.pollPeriodMs),
      robotTimeoutMs: i('robotTimeoutMs', d.robotTimeoutMs),
      echoTimeoutMs: i('echoTimeoutMs', d.echoTimeoutMs),
      startConfirmMs: i('startConfirmMs', d.startConfirmMs),
      pulseMs: i('pulseMs', d.pulseMs),
      settingsPin: j['settingsPin'] as String? ?? d.settingsPin,
      programs: (j['programs'] as List<dynamic>?)
              ?.map((e) => ProgramEntry.fromJson(e as Map<String, dynamic>))
              .toList() ??
          d.programs,
    );
  }

  /// Returns human-readable problems; empty when the profile is usable.
  List<String> validate() {
    final errors = <String>[];
    if (host.trim().isEmpty) errors.add('Robot IP is empty');
    if (heartbeatPeriodMs * 3 > robotTimeoutMs) {
      errors.add('Heartbeat period must be at most 1/3 of the robot timeout');
    }
    if (robotTimeoutMs < 1000 || robotTimeoutMs > 3000) {
      errors.add('Robot timeout must be 1000..3000 ms');
    }
    final numbers = programs.map((p) => p.number).toList();
    if (numbers.toSet().length != numbers.length) errors.add('Duplicate program numbers');
    if (programs.any((p) => p.number < 1 || p.number > 65535)) {
      errors.add('Program numbers must be 1..65535');
    }
    return errors;
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Result of a Codroid WebSocket API call.
///
/// Response shape (CodroidApi_EN.pdf):
/// `{"id":1,"type":"common","action":"...","time":..,"code":200,"msg":"",
///   "data":{"msg":"","code":0,"data":<payload>}}`
class CodroidResult {
  const CodroidResult({required this.code, required this.msg, this.data});

  /// 0 = success. Outer HTTP-like errors are mapped to their outer code.
  final int code;
  final String msg;
  final Object? data;

  bool get ok => code == 0;

  factory CodroidResult.fromResponse(Map<String, dynamic> json) {
    final outer = (json['code'] as num?)?.toInt() ?? 200;
    final inner = json['data'];
    if (outer != 200) {
      return CodroidResult(code: outer == 0 ? -1 : outer, msg: json['msg']?.toString() ?? '');
    }
    if (inner is Map<String, dynamic>) {
      return CodroidResult(
        code: (inner['code'] as num?)?.toInt() ?? 0,
        msg: inner['msg']?.toString() ?? '',
        data: inner['data'],
      );
    }
    return CodroidResult(code: 0, msg: '', data: inner);
  }

  @override
  String toString() => ok ? 'OK $data' : 'Error $code: $msg';
}

class CodroidApiException implements Exception {
  CodroidApiException(this.action, this.result);
  final String action;
  final CodroidResult result;
  @override
  String toString() => '$action failed (${result.code}): ${result.msg}';
}

/// Robot state from `getRobotStates`.
class CodroidRobotStates {
  const CodroidRobotStates({required this.robotMode, required this.safetyMode, required this.statusFlag});

  /// PowerOff, Idle, Jogging, Dragging, ToPoint, AutoReady, AutoRunning, Rescue, Fault, other
  final String robotMode;

  /// 1 normal, 2 E-stop pressed, 3 rescue, 4 reduced, 0 error
  final int safetyMode;
  final int statusFlag;

  bool get estop => safetyMode == 2 || (statusFlag & 0x01) != 0;
  bool get fault => robotMode == 'Fault' || safetyMode == 0;

  factory CodroidRobotStates.fromData(Object? data) {
    final m = data is Map<String, dynamic> ? data : const <String, dynamic>{};
    return CodroidRobotStates(
      robotMode: m['robotMode']?.toString() ?? 'other',
      safetyMode: (m['safetyMode'] as num?)?.toInt() ?? -1,
      statusFlag: (m['statusFlag'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Codroid WebSocket API client (ws://ROBOT_IP:9000). Requests are matched
/// to responses by "id".
class CodroidWsClient {
  CodroidWsClient({
    required this.host,
    required this.port,
    this.timeout = const Duration(milliseconds: 1500),
  });

  final String host;
  final int port;
  final Duration timeout;

  WebSocket? _ws;
  int _nextId = 1;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};

  bool get isConnected => _ws != null;

  static String encodeRequest(int id, String type, String action, Object? data) =>
      jsonEncode({'id': id, 'type': type, 'action': action, 'data': data ?? const <String, dynamic>{}});

  Future<void> connect() async {
    close();
    final ws = await WebSocket.connect('ws://$host:$port').timeout(const Duration(seconds: 2));
    ws.pingInterval = const Duration(seconds: 2);
    _ws = ws;
    ws.listen(
      _onMessage,
      onError: (Object _) {
        if (identical(_ws, ws)) _closed();
      },
      onDone: () {
        if (identical(_ws, ws)) _closed();
      },
      cancelOnError: true,
    );
  }

  void close() {
    final ws = _ws;
    _closed();
    ws?.close();
  }

  Future<CodroidResult> call(String type, String action, [Object? data]) async {
    final ws = _ws;
    if (ws == null) throw const SocketException('WebSocket not connected');
    final id = _nextId++;
    final c = Completer<Map<String, dynamic>>();
    _pending[id] = c;
    ws.add(encodeRequest(id, type, action, data));
    try {
      return CodroidResult.fromResponse(await c.future.timeout(timeout));
    } finally {
      _pending.remove(id);
    }
  }

  Future<CodroidResult> _checked(String type, String action, [Object? data]) async {
    final r = await call(type, action, data);
    if (!r.ok) throw CodroidApiException(action, r);
    return r;
  }

  // ---- projexecute -------------------------------------------------------
  Future<void> runProject(String projectName, {String taskName = 'main1'}) =>
      _checked('projexecute', 'run', {'projectName': projectName, 'taskName': taskName});
  Future<void> stopProject() => _checked('projexecute', 'stop');
  Future<void> pauseProject() => _checked('projexecute', 'pause');
  Future<void> resumeProject() => _checked('projexecute', 'resume');

  /// IDLE, LOADING, RUNNING, PAUSE or ERROR.
  Future<String> getProjectState() async =>
      (await _checked('projexecute', 'getProjectState')).data?.toString() ?? '';

  // ---- common ------------------------------------------------------------
  Future<CodroidRobotStates> getRobotStates() async =>
      CodroidRobotStates.fromData((await _checked('common', 'getRobotStates', const <Object>[])).data);

  Future<bool> getDI(int port) async =>
      ((await _checked('common', 'getDI', {'port': port})).data as num?)?.toInt() == 1;

  Future<void> stopMove() => _checked('common', 'stopMov', const <Object>[]);

  /// Robot/Control/command: 100 ClearError, 501 ClearWarning, 1000 ResumeFaulty.
  Future<void> sendCommand(int value) => _checked('common', 'setparam', [
        {'path': 'Robot/Control/command', 'value': value},
      ]);

  // ---- internals ---------------------------------------------------------
  void _onMessage(dynamic message) {
    if (message is! String) return;
    Map<String, dynamic> json;
    try {
      json = jsonDecode(message) as Map<String, dynamic>;
    } on Object {
      return;
    }
    final id = (json['id'] as num?)?.toInt();
    final c = id == null ? null : _pending[id];
    if (c != null && !c.isCompleted) c.complete(json);
  }

  void _closed() {
    _ws = null;
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(const SocketException('WebSocket closed'));
    }
    _pending.clear();
  }
}

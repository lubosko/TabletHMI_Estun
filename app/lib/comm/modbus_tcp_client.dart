import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'modbus_frames.dart';

/// Minimal Modbus TCP master (FC01/03/05/06/16) on dart:io.
///
/// Requests are serialized (one outstanding transaction). A timeout closes the
/// socket so the next request starts from a clean stream; the HMI controller
/// reconnects.
class ModbusTcpClient {
  ModbusTcpClient({
    required this.host,
    required this.port,
    this.unitId = 1,
    this.timeout = const Duration(milliseconds: 800),
  });

  final String host;
  final int port;
  final int unitId;
  final Duration timeout;

  Socket? _socket;
  final List<int> _rx = [];
  int _tid = 0;
  int _pendingTid = -1;
  Completer<Uint8List>? _pending;
  Future<void> _queue = Future.value();

  bool get isConnected => _socket != null;

  Future<void> connect() async {
    close();
    final s = await Socket.connect(host, port, timeout: const Duration(seconds: 2));
    s.setOption(SocketOption.tcpNoDelay, true);
    _socket = s;
    _rx.clear();
    s.listen(
      _onData,
      // Ignore events from a socket that has already been replaced.
      onError: (Object e) {
        if (identical(_socket, s)) _fail(e);
      },
      onDone: () {
        if (identical(_socket, s)) _fail(const SocketException('Modbus connection closed by robot'));
      },
      cancelOnError: true,
    );
  }

  void close() => _fail(const SocketException('Modbus connection closed'));

  // ---- public API --------------------------------------------------------
  Future<List<bool>> readCoils(int address, int quantity) async =>
      ModbusPdu.parseCoils(await _request(ModbusPdu.readCoils(address, quantity)), quantity);

  Future<List<int>> readHoldingRegisters(int address, int quantity) async =>
      ModbusPdu.parseRegisters(await _request(ModbusPdu.readHoldingRegisters(address, quantity)));

  Future<void> writeCoil(int address, bool value) async =>
      ModbusPdu.checkException(await _request(ModbusPdu.writeSingleCoil(address, value)));

  Future<void> writeRegister(int address, int value) async =>
      ModbusPdu.checkException(await _request(ModbusPdu.writeSingleRegister(address, value)));

  Future<void> writeRegisters(int address, List<int> values) async =>
      ModbusPdu.checkException(await _request(ModbusPdu.writeMultipleRegisters(address, values)));

  Future<int> readDInt(int address, {required bool highWordFirst}) async =>
      DInt.fromWords(await readHoldingRegisters(address, 2), highWordFirst: highWordFirst);

  Future<void> writeDInt(int address, int value, {required bool highWordFirst}) =>
      writeRegisters(address, DInt.toWords(value, highWordFirst: highWordFirst));

  /// Rising edge on a system-input coil: 0 -> 1, hold [width], -> 0.
  Future<void> pulseCoil(int address, Duration width) async {
    await writeCoil(address, false);
    await writeCoil(address, true);
    await Future<void>.delayed(width);
    await writeCoil(address, false);
  }

  // ---- transport ---------------------------------------------------------
  Future<Uint8List> _request(Uint8List pdu) {
    final result = Completer<Uint8List>();
    _queue = _queue.then((_) async {
      try {
        result.complete(await _transact(pdu));
      } catch (e, st) {
        result.completeError(e, st);
      }
    });
    return result.future;
  }

  Future<Uint8List> _transact(Uint8List pdu) async {
    final s = _socket;
    if (s == null) throw const SocketException('Modbus not connected');
    _tid = (_tid + 1) & 0xFFFF;
    final pending = Completer<Uint8List>();
    _pending = pending;
    _pendingTid = _tid;
    s.add(ModbusAdu.build(_tid, unitId, pdu));
    try {
      return await pending.future.timeout(timeout);
    } on TimeoutException {
      close();
      rethrow;
    } finally {
      if (identical(_pending, pending)) _pending = null;
    }
  }

  void _onData(Uint8List data) {
    _rx.addAll(data);
    while (true) {
      final len = ModbusAdu.frameLength(_rx);
      if (len == null || _rx.length < len) return;
      final frame = _rx.sublist(0, len);
      _rx.removeRange(0, len);
      final p = _pending;
      if (p != null && !p.isCompleted && ModbusAdu.transactionId(frame) == _pendingTid) {
        p.complete(ModbusAdu.pdu(frame));
      }
    }
  }

  void _fail(Object error) {
    final p = _pending;
    if (p != null && !p.isCompleted) p.completeError(error);
    _pending = null;
    final s = _socket;
    _socket = null;
    s?.destroy();
  }
}

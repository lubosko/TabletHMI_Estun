/// Pure Modbus TCP frame encoding/decoding (no I/O) so it can be unit tested.
library;

import 'dart:typed_data';

class ModbusException implements Exception {
  ModbusException(this.functionCode, this.exceptionCode);
  final int functionCode;
  final int exceptionCode;

  static const _names = {
    1: 'illegal function',
    2: 'illegal data address',
    3: 'illegal data value',
    4: 'slave device failure',
    6: 'slave device busy',
  };

  @override
  String toString() =>
      'Modbus exception FC$functionCode: ${_names[exceptionCode] ?? 'code $exceptionCode'}';
}

abstract final class ModbusPdu {
  static const fcReadCoils = 0x01;
  static const fcReadHolding = 0x03;
  static const fcWriteCoil = 0x05;
  static const fcWriteRegister = 0x06;
  static const fcWriteRegisters = 0x10;

  static Uint8List readCoils(int address, int quantity) =>
      _addrQty(fcReadCoils, address, quantity);

  static Uint8List readHoldingRegisters(int address, int quantity) =>
      _addrQty(fcReadHolding, address, quantity);

  static Uint8List writeSingleCoil(int address, bool value) =>
      _addrQty(fcWriteCoil, address, value ? 0xFF00 : 0x0000);

  static Uint8List writeSingleRegister(int address, int value) =>
      _addrQty(fcWriteRegister, address, value & 0xFFFF);

  static Uint8List writeMultipleRegisters(int address, List<int> values) {
    final b = ByteData(6 + values.length * 2);
    b.setUint8(0, fcWriteRegisters);
    b.setUint16(1, _checkAddr(address));
    b.setUint16(3, values.length);
    b.setUint8(5, values.length * 2);
    for (var i = 0; i < values.length; i++) {
      b.setUint16(6 + i * 2, values[i] & 0xFFFF);
    }
    return b.buffer.asUint8List();
  }

  static Uint8List _addrQty(int fc, int address, int value) {
    final b = ByteData(5);
    b.setUint8(0, fc);
    b.setUint16(1, _checkAddr(address));
    b.setUint16(3, value);
    return b.buffer.asUint8List();
  }

  static int _checkAddr(int address) {
    if (address < 0 || address > 0xFFFF) {
      throw ArgumentError.value(address, 'address', 'must be 0..65535');
    }
    return address;
  }

  /// Throws [ModbusException] if the response PDU is an exception response.
  static void checkException(Uint8List pdu) {
    if (pdu.isEmpty) throw const FormatException('empty Modbus response');
    if (pdu[0] & 0x80 != 0) {
      throw ModbusException(pdu[0] & 0x7F, pdu.length > 1 ? pdu[1] : 0);
    }
  }

  static List<bool> parseCoils(Uint8List pdu, int quantity) {
    checkException(pdu);
    final byteCount = pdu[1];
    if (pdu.length < 2 + byteCount || byteCount * 8 < quantity) {
      throw const FormatException('short coil response');
    }
    return List<bool>.generate(quantity, (i) => (pdu[2 + i ~/ 8] >> (i % 8)) & 1 == 1);
  }

  static List<int> parseRegisters(Uint8List pdu) {
    checkException(pdu);
    final byteCount = pdu[1];
    if (pdu.length < 2 + byteCount) throw const FormatException('short register response');
    final b = ByteData.sublistView(pdu, 2, 2 + byteCount);
    return List<int>.generate(byteCount ~/ 2, (i) => b.getUint16(i * 2));
  }
}

abstract final class ModbusAdu {
  static const headerLength = 7;

  /// MBAP header + PDU.
  static Uint8List build(int transactionId, int unitId, Uint8List pdu) {
    final b = ByteData(headerLength + pdu.length);
    b.setUint16(0, transactionId & 0xFFFF);
    b.setUint16(2, 0); // protocol id
    b.setUint16(4, pdu.length + 1);
    b.setUint8(6, unitId);
    final out = b.buffer.asUint8List();
    out.setRange(headerLength, out.length, pdu);
    return out;
  }

  /// Total frame length if [buffer] holds at least a full header, else null.
  static int? frameLength(List<int> buffer) {
    if (buffer.length < headerLength) return null;
    return 6 + ((buffer[4] << 8) | buffer[5]);
  }

  static int transactionId(List<int> frame) => (frame[0] << 8) | frame[1];

  static Uint8List pdu(List<int> frame) => Uint8List.fromList(frame.sublist(headerLength));
}

/// 32-bit (DInt) helpers for Codroid Int registers that span two words.
abstract final class DInt {
  static List<int> toWords(int value, {required bool highWordFirst}) {
    final v = value & 0xFFFFFFFF;
    final hi = (v >> 16) & 0xFFFF;
    final lo = v & 0xFFFF;
    return highWordFirst ? [hi, lo] : [lo, hi];
  }

  static int fromWords(List<int> words, {required bool highWordFirst}) {
    final hi = highWordFirst ? words[0] : words[1];
    final lo = highWordFirst ? words[1] : words[0];
    final v = ((hi & 0xFFFF) << 16) | (lo & 0xFFFF);
    return v >= 0x80000000 ? v - 0x100000000 : v;
  }
}

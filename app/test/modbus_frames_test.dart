import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tablet_hmi/comm/modbus_frames.dart';

void main() {
  group('PDU encoding', () {
    test('read coils 2000 x14', () {
      expect(ModbusPdu.readCoils(2000, 14), [0x01, 0x07, 0xD0, 0x00, 0x0E]);
    });

    test('write single coil ON/OFF', () {
      expect(ModbusPdu.writeSingleCoil(1000, true), [0x05, 0x03, 0xE8, 0xFF, 0x00]);
      expect(ModbusPdu.writeSingleCoil(1000, false), [0x05, 0x03, 0xE8, 0x00, 0x00]);
    });

    test('write single register 42000 = 3', () {
      expect(ModbusPdu.writeSingleRegister(42000, 3), [0x06, 0xA4, 0x10, 0x00, 0x03]);
    });

    test('write multiple registers', () {
      expect(ModbusPdu.writeMultipleRegisters(49000, [0x0001, 0xABCD]),
          [0x10, 0xBF, 0x68, 0x00, 0x02, 0x04, 0x00, 0x01, 0xAB, 0xCD]);
    });

    test('address out of range throws', () {
      expect(() => ModbusPdu.readCoils(70000, 1), throwsArgumentError);
    });
  });

  group('ADU framing', () {
    test('MBAP header', () {
      final adu = ModbusAdu.build(0x1234, 1, Uint8List.fromList([0x01, 0x07, 0xD0, 0x00, 0x0E]));
      expect(adu, [0x12, 0x34, 0x00, 0x00, 0x00, 0x06, 0x01, 0x01, 0x07, 0xD0, 0x00, 0x0E]);
      expect(ModbusAdu.frameLength(adu), adu.length);
      expect(ModbusAdu.transactionId(adu), 0x1234);
      expect(ModbusAdu.pdu(adu), [0x01, 0x07, 0xD0, 0x00, 0x0E]);
    });

    test('incomplete header gives null length', () {
      expect(ModbusAdu.frameLength([0, 1, 0, 0]), isNull);
    });
  });

  group('response parsing', () {
    test('coils LSB first', () {
      final pdu = Uint8List.fromList([0x01, 0x02, 0x05, 0x10]); // bits 0,2 and 12
      final bits = ModbusPdu.parseCoils(pdu, 14);
      expect(bits[0], isTrue);
      expect(bits[1], isFalse);
      expect(bits[2], isTrue);
      expect(bits[12], isTrue);
      expect(bits.where((b) => b).length, 3);
    });

    test('registers', () {
      final pdu = Uint8List.fromList([0x03, 0x04, 0x00, 0x01, 0xFF, 0xFE]);
      expect(ModbusPdu.parseRegisters(pdu), [1, 0xFFFE]);
    });

    test('exception response throws ModbusException', () {
      final pdu = Uint8List.fromList([0x85, 0x02]);
      expect(
        () => ModbusPdu.checkException(pdu),
        throwsA(isA<ModbusException>()
            .having((e) => e.functionCode, 'fc', 5)
            .having((e) => e.exceptionCode, 'code', 2)),
      );
    });
  });

  group('DInt', () {
    test('round trip both word orders', () {
      for (final v in [0, 1, 32767, 65536, -1, -123456, 0x7FFFFFFF]) {
        for (final hi in [true, false]) {
          expect(DInt.fromWords(DInt.toWords(v, highWordFirst: hi), highWordFirst: hi), v);
        }
      }
    });

    test('high word first layout', () {
      expect(DInt.toWords(0x00010002, highWordFirst: true), [1, 2]);
      expect(DInt.toWords(0x00010002, highWordFirst: false), [2, 1]);
    });
  });
}

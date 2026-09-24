#!/usr/bin/env python3
"""End-to-end smoke test: acts as the tablet against tools/robot_sim.py.

Starts the simulator on test ports, then runs the PRD acceptance scenarios
using the same Modbus/WebSocket sequences as the Flutter app.
Usage:  python tools/sim_smoke_test.py
"""
import base64
import json
import os
import socket
import struct
import subprocess
import sys
import threading
import time

HOST, MB_PORT, WS_PORT = "127.0.0.1", 1502, 19000
TIMEOUT_MS = 1500


class Modbus:
    def __init__(self):
        self.sock = socket.create_connection((HOST, MB_PORT), timeout=2)
        self.tid = 0
        self.lock = threading.Lock()

    def _req(self, pdu: bytes) -> bytes:
        with self.lock:
            self.tid = (self.tid + 1) & 0xFFFF
            self.sock.sendall(struct.pack(">HHHB", self.tid, 0, len(pdu) + 1, 1) + pdu)
            head = self._recv(7)
            tid, _, length, _ = struct.unpack(">HHHB", head)
            body = self._recv(length - 1)
            assert tid == self.tid, "transaction id mismatch"
            assert body[0] & 0x80 == 0, f"modbus exception {body[1]}"
            return body

    def _recv(self, n):
        buf = b""
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise ConnectionError("closed")
            buf += chunk
        return buf

    def read_coils(self, addr, qty):
        body = self._req(struct.pack(">BHH", 1, addr, qty))
        return [bool(body[2 + i // 8] >> (i % 8) & 1) for i in range(qty)]

    def write_coil(self, addr, val):
        self._req(struct.pack(">BHH", 5, addr, 0xFF00 if val else 0))

    def write_reg(self, addr, val):
        self._req(struct.pack(">BHH", 6, addr, val & 0xFFFF))

    def write_dint(self, addr, val):
        v = val & 0xFFFFFFFF
        self._req(struct.pack(">BHHBHH", 16, addr, 2, 4, v >> 16, v & 0xFFFF))

    def read_dint(self, addr):
        body = self._req(struct.pack(">BHH", 3, addr, 2))
        hi, lo = struct.unpack(">HH", body[2:6])
        return (hi << 16) | lo

    def pulse(self, addr):
        self.write_coil(addr, False)
        self.write_coil(addr, True)
        time.sleep(0.1)
        self.write_coil(addr, False)


class Ws:
    def __init__(self):
        self.sock = socket.create_connection((HOST, WS_PORT), timeout=2)
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall((f"GET / HTTP/1.1\r\nHost: {HOST}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                           f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
        resp = b""
        while b"\r\n\r\n" not in resp:
            resp += self.sock.recv(1024)
        assert b" 101 " in resp, resp
        self.id = 0

    def call(self, typ, action, data):
        self.id += 1
        payload = json.dumps({"id": self.id, "type": typ, "action": action, "data": data}).encode()
        mask = os.urandom(4)
        n = len(payload)
        head = struct.pack(">BB", 0x81, 0x80 | n) if n < 126 else struct.pack(">BBH", 0x81, 0x80 | 126, n)
        self.sock.sendall(head + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))
        b0, b1 = self._recv(2)
        n = b1 & 0x7F
        if n == 126:
            n = struct.unpack(">H", self._recv(2))[0]
        msg = json.loads(self._recv(n))
        assert msg["id"] == self.id
        return msg["data"]

    def _recv(self, n):
        buf = b""
        while len(buf) < n:
            buf += self.sock.recv(n - len(buf))
        return buf

    def sim(self, cmd):
        return self.call("sim", "cmd", cmd)

    def state(self):
        return self.call("projexecute", "getProjectState", {})["data"]


class Heartbeat(threading.Thread):
    def __init__(self, mb):
        super().__init__(daemon=True)
        self.mb, self.counter, self.enabled, self.alive = mb, 0, True, True

    def run(self):
        while self.alive:
            if self.enabled:
                self.counter = (self.counter + 1) % 32768
                self.mb.write_dint(49000, self.counter)
            time.sleep(0.2)


def tablet_start(mb, number):
    mb.write_reg(42000, number)
    mb.write_coil(9902, True)          # HMI_TABLET_START -> watchdog marks owner = tablet
    mb.pulse(1000)                     # startProject rising edge


results = []


def check(name, cond, detail=""):
    results.append(cond)
    print(f"  [{'PASS' if cond else 'FAIL'}] {name} {detail}")


def wait_state(ws, want, seconds):
    end = time.time() + seconds
    while time.time() < end:
        if ws.state() == want:
            return True
        time.sleep(0.05)
    return False


def main():
    sim = subprocess.Popen([sys.executable, os.path.join(os.path.dirname(__file__), "robot_sim.py"),
                            "--host", HOST, "--modbus-port", str(MB_PORT), "--ws-port", str(WS_PORT),
                            "--no-console", "--timeout", str(TIMEOUT_MS)],
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        time.sleep(1.0)
        mb, ws = Modbus(), Ws()
        hb = Heartbeat(mb)
        hb.start()

        print("1. Tablet start + run with heartbeat")
        ws.sim("di on")
        tablet_start(mb, 2)
        check("program RUNNING", wait_state(ws, "RUNNING", 1.0))
        e1 = mb.read_dint(49002)
        time.sleep(0.6)
        e2 = mb.read_dint(49002)
        check("watchdog echo changes", e2 != e1, f"({e1} -> {e2})")
        check("status coil 2000 isProjectRunning", mb.read_coils(2000, 1)[0])
        time.sleep(1.5)
        check("no nuisance trip with heartbeat", ws.state() == "RUNNING")

        print("2. Heartbeat lost -> watchdog stops project")
        hb.enabled = False
        t0 = time.time()
        stopped = wait_state(ws, "IDLE", 3.0)
        dt = (time.time() - t0) * 1000
        check("stopped after heartbeat loss", stopped, f"({dt:.0f} ms, timeout {TIMEOUT_MS} ms)")
        check("stop within timeout + 300 ms", stopped and dt <= TIMEOUT_MS + 300)
        check("HMI_WD_TRIPPED set", mb.read_coils(9901, 1)[0])
        hb.enabled = True

        print("3. Enable DI switched OFF while tablet owns program -> stop")
        tablet_start(mb, 1)
        check("program RUNNING", wait_state(ws, "RUNNING", 1.0))
        check("tripped flag cleared on start", not mb.read_coils(9901, 1)[0])
        ws.sim("di off")
        check("stopped after DI OFF", wait_state(ws, "IDLE", 0.5))

        print("4. Pendant start with DI OFF, no heartbeat -> runs unsupervised")
        hb.enabled = False
        r = ws.call("projexecute", "run", {"projectName": "Screwing", "taskName": "main1"})
        check("WS run accepted", r["code"] == 0, str(r))
        time.sleep(TIMEOUT_MS / 1000 + 1.0)
        check("still RUNNING", ws.state() == "RUNNING")
        mb.pulse(1001)
        check("Modbus stopProject coil stops it", wait_state(ws, "IDLE", 0.5))
        hb.enabled = True

        print("5. Pause via Modbus, resume via WebSocket")
        ws.sim("di on")
        tablet_start(mb, 3)
        check("program RUNNING", wait_state(ws, "RUNNING", 1.0))
        mb.pulse(1002)
        check("PAUSE", wait_state(ws, "PAUSE", 0.5))
        check("status coil 2002 isProjectPaused", mb.read_coils(2002, 1)[0])
        r = ws.call("projexecute", "resume", {})
        check("resume RUNNING", r["code"] == 0 and wait_state(ws, "RUNNING", 0.5))
        time.sleep(0.5)
        check("no trip after resume", ws.state() == "RUNNING")
        mb.pulse(1001)
        wait_state(ws, "IDLE", 0.5)

        print("6. Project without watchdog thread -> echo frozen (tablet must stop it)")
        ws.sim("nowd")
        e1 = mb.read_dint(49002)
        tablet_start(mb, 4)
        wait_state(ws, "RUNNING", 1.0)
        time.sleep(1.0)
        e2 = mb.read_dint(49002)
        check("echo frozen", e1 == e2, f"({e1} == {e2})")
        mb.pulse(1001)
        check("tablet stop works", wait_state(ws, "IDLE", 0.5))

        print("7. E-stop")
        tablet_start(mb, 1)
        wait_state(ws, "RUNNING", 1.0)
        ws.sim("estop on")
        check("E-stop stops program", wait_state(ws, "IDLE", 0.5))
        check("status coil 2012 isESButtonPressed", mb.read_coils(2012, 1)[0])
        states = ws.call("common", "getRobotStates", [])["data"]
        check("getRobotStates safetyMode=2", states["safetyMode"] == 2, str(states))
        ws.sim("estop off")

        hb.alive = False
    finally:
        sim.terminate()
        try:
            out, _ = sim.communicate(timeout=3)
        except subprocess.TimeoutExpired:
            sim.kill()
            out, _ = sim.communicate()
        print("\n--- simulator log ---")
        print(out)

    passed = sum(results)
    print(f"{passed}/{len(results)} checks passed")
    sys.exit(0 if passed == len(results) else 1)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Codroid robot simulator for Tablet HMI bench testing (Python 3.9+, stdlib only).

Emulates the parts of a Codroid controller that the Tablet HMI uses:
  * Modbus TCP slave  (default port 502, use --modbus-port 1502 if 502 is blocked)
      coils 1000-1013 system inputs, 2000-2013 status, user Bool registers,
      holding 42000 startProjectNumber, user Int (DInt) registers.
  * WebSocket API     (default port 9000)  "projexecute" and "common" actions.
  * The TabletHMI watchdog thread (same rules as robot/TabletHMI_watchdog.lua).
  * Native heartBeatFromMaster detection ("strict mode", error 10057).

Console commands (stdin):  help, status, di on|off, estop on|off,
  mode auto|manual|remote, nowd, wd, fault, strict on|off, quit
Automated tests can send the same over WebSocket:
  {"id":1,"type":"sim","action":"cmd","data":"di on"}
"""
import argparse
import asyncio
import base64
import hashlib
import json
import struct
import sys
import threading
import time

# ---------------------------------------------------------------- addresses --
COIL_START, COIL_STOP, COIL_PAUSE, COIL_CLEAR_WARN = 1000, 1001, 1002, 1005
REG_START_NUMBER = 42000
ST_RUNNING, ST_STOPPED, ST_PAUSED, ST_ON, ST_OFF, ST_MANUAL = 2000, 2001, 2002, 2003, 2004, 2005
ST_WARNING, ST_ESTOP, ST_RESCUE = 2010, 2012, 2013

# user registers (must match robot/TabletHMI_watchdog.lua and the tablet profile)
REG_HB, REG_HB_ECHO = 49000, 49002
COIL_ENABLED, COIL_WD_TRIPPED, COIL_TABLET_START = 9900, 9901, 9902

PROJECTS = {1: "Palletizing", 2: "Screwing", 3: "Pick_and_Place", 4: "Test_Cycle"}


def now_ms() -> int:
    return int(time.time() * 1000)


def log(msg: str) -> None:
    print(time.strftime("%H:%M:%S") + f".{int(time.time() * 1000) % 1000:03d}  {msg}", flush=True)


# ------------------------------------------------------------------- robot --
class Robot:
    def __init__(self, args):
        self.coils = {}
        self.regs = {}
        self.enable_di = False
        self.enable_di_port = args.enable_di
        self.estop = False
        self.mode = args.mode            # auto | manual | remote
        self.require_remote = args.require_remote
        self.fault = False
        self.warning = False
        self.project_state = "IDLE"      # IDLE LOADING RUNNING PAUSE ERROR
        self.project_name = ""
        self.next_has_watchdog = True
        self.has_watchdog = False
        self.timeout_ms = args.timeout
        self.strict = args.strict
        self.hbm_addr = args.hbm_addr
        # watchdog thread state
        self.wd_owner_tablet = False
        self.wd_last_hb = 0
        self.wd_last_change = 0
        # native heartbeat
        self.hbm_last = None
        self.hbm_last_change = now_ms()
        self.last_error = ""

    # --- register helpers
    def dint(self, addr: int) -> int:
        v = ((self.regs.get(addr, 0) & 0xFFFF) << 16) | (self.regs.get(addr + 1, 0) & 0xFFFF)
        return v - (1 << 32) if v & 0x80000000 else v

    def set_dint(self, addr: int, value: int) -> None:
        value &= 0xFFFFFFFF
        self.regs[addr] = value >> 16
        self.regs[addr + 1] = value & 0xFFFF

    # --- system input edges
    def on_coil_write(self, addr: int, value: bool) -> None:
        old = self.coils.get(addr, False)
        self.coils[addr] = value
        if value and not old:
            if addr == COIL_START:
                if self.project_state == "PAUSE":
                    self.resume("modbus")
                else:
                    self.start(PROJECTS.get(self.regs.get(REG_START_NUMBER, 0)), "modbus")
            elif addr == COIL_STOP:
                self.stop("modbus")
            elif addr == COIL_PAUSE:
                self.pause("modbus")
            elif addr == COIL_CLEAR_WARN:
                self.warning = False
                log("clearWarning")

    # --- project control; returns (code, msg) like the controller
    def can_run(self):
        if self.estop:
            return 1, "E-stop pressed"
        if self.fault:
            return 1, "Robot in error"
        if self.mode == "manual":
            return 1, "Robot in manual mode"
        if self.require_remote and self.mode != "remote":
            return 10074, "Remote mode not enabled."
        if self.strict and now_ms() - self.hbm_last_change > self.timeout_ms:
            return 10057, "Register communication master heartbeat lost."
        return 0, ""

    def start(self, name, src):
        if name is None:
            log(f"[{src}] start rejected: no project mapped to number {self.regs.get(REG_START_NUMBER, 0)}")
            return 1, "No project mapped"
        if self.project_state not in ("IDLE", "ERROR"):
            return 10069, "Invalid command."
        code, msg = self.can_run()
        if code:
            log(f"[{src}] start '{name}' rejected: {msg}")
            self.warning = True
            return code, msg
        self.project_name = name
        self.project_state = "RUNNING"
        self.has_watchdog = self.next_has_watchdog
        self.next_has_watchdog = True
        # watchdog thread start (mirrors the Lua script)
        self.wd_owner_tablet = bool(self.coils.get(COIL_TABLET_START, False))
        self.coils[COIL_TABLET_START] = False
        self.coils[COIL_WD_TRIPPED] = False
        self.wd_last_hb = self.dint(REG_HB)
        self.wd_last_change = now_ms()
        owner = "tablet" if self.wd_owner_tablet else "pendant"
        log(f"[{src}] project '{name}' RUNNING (owner={owner}, watchdog={'yes' if self.has_watchdog else 'NO'})")
        return 0, ""

    def stop(self, src, reason=""):
        if self.project_state in ("RUNNING", "PAUSE", "LOADING"):
            log(f"[{src}] project '{self.project_name}' STOPPED {reason}".rstrip())
        self.project_state = "IDLE"
        return 0, ""

    def pause(self, src):
        if self.project_state != "RUNNING":
            return 10068, "Project is not in running state."
        self.project_state = "PAUSE"
        log(f"[{src}] project '{self.project_name}' PAUSED")
        return 0, ""

    def resume(self, src):
        if self.project_state != "PAUSE":
            return 10067, "Project is not in paused state."
        code, msg = self.can_run()
        if code:
            return code, msg
        self.project_state = "RUNNING"
        log(f"[{src}] project '{self.project_name}' RESUMED")
        return 0, ""

    # --- 50 ms cycle: watchdog thread, native heartbeat, status coils
    def tick(self):
        t = now_ms()
        # native heartbeat detection
        if self.hbm_addr is not None:
            v = self.regs.get(self.hbm_addr, 0)
            if v != self.hbm_last:
                self.hbm_last, self.hbm_last_change = v, t
            if self.strict and self.project_state in ("RUNNING", "PAUSE") and t - self.hbm_last_change > self.timeout_ms:
                self.last_error = "10057 Register communication master heartbeat lost."
                self.fault = True
                self.stop("controller", "(error 10057 heartbeat lost)")
        # E-stop / fault stop everything
        if (self.estop or self.fault) and self.project_state in ("RUNNING", "PAUSE"):
            self.stop("controller", "(E-stop)" if self.estop else "(fault)")
        # watchdog thread (only while the project runs and only if the project has it)
        if self.project_state == "RUNNING" and self.has_watchdog:
            self.coils[COIL_ENABLED] = self.enable_di
            hb = self.dint(REG_HB)
            if hb != self.wd_last_hb:
                self.wd_last_hb, self.wd_last_change = hb, t
                self.set_dint(REG_HB_ECHO, hb)
            reason = None
            if self.wd_owner_tablet and not self.enable_di:
                reason = "Tablet HMI switched OFF on robot while tablet owns the program"
            elif (self.enable_di or self.wd_owner_tablet) and t - self.wd_last_change > self.timeout_ms:
                reason = f"tablet heartbeat lost for {t - self.wd_last_change} ms"
            if reason:
                self.coils[COIL_WD_TRIPPED] = True
                log(f"WATCHDOG TRIP: {reason}")
                self.stop("watchdog", "-> stopProject()")
        # status coils 2000-2013
        running, paused = self.project_state == "RUNNING", self.project_state == "PAUSE"
        self.coils.update({
            ST_RUNNING: running, ST_STOPPED: not running and not paused, ST_PAUSED: paused,
            ST_ON: not self.estop, ST_OFF: self.estop, ST_MANUAL: self.mode == "manual",
            2006: False, 2007: running, 2008: False, 2009: False,
            ST_WARNING: self.warning, 2011: False, ST_ESTOP: self.estop, ST_RESCUE: False,
        })

    # --- WebSocket view of the robot
    def robot_states(self):
        if self.fault or self.estop:
            mode = "Fault" if self.fault else "Idle"
        elif self.project_state == "RUNNING":
            mode = "AutoRunning"
        elif self.mode == "manual":
            mode = "Idle"
        else:
            mode = "AutoReady"
        safety = 2 if self.estop else (0 if self.fault else 1)
        flag = (1 if self.estop else 0) | (0 if self.estop else 2) | (8 if self.project_state == "RUNNING" else 0)
        return {"robotMode": mode, "safetyMode": safety, "statusFlag": flag}

    def control_state(self):
        if self.fault:
            return 6
        return {"manual": 2, "auto": 4, "remote": 4}[self.mode]

    def console(self, line: str) -> str:
        p = line.lstrip("﻿").strip().split()  # tolerate a BOM from piped input
        if not p:
            return ""
        c = p[0].lower()
        arg = p[1].lower() if len(p) > 1 else ""
        if c == "di":
            self.enable_di = arg == "on"
            return f"enable DI{self.enable_di_port} = {'ON' if self.enable_di else 'OFF'}"
        if c == "estop":
            self.estop = arg == "on"
            return f"E-stop {'PRESSED' if self.estop else 'released'}"
        if c == "mode" and arg in ("auto", "manual", "remote"):
            self.mode = arg
            return f"mode = {arg}"
        if c == "nowd":
            self.next_has_watchdog = False
            return "next started project has NO watchdog thread"
        if c == "wd":
            self.next_has_watchdog = True
            return "next started project has a watchdog thread"
        if c == "fault":
            self.fault = True
            self.last_error = "Simulated fault"
            return "robot fault set"
        if c == "strict":
            self.strict = arg == "on"
            return f"strict mode {'ON' if self.strict else 'OFF'} (hbm addr {self.hbm_addr})"
        if c == "status":
            return json.dumps(self.snapshot())
        if c == "help":
            return __doc__
        return f"unknown command: {line.strip()}"

    def snapshot(self):
        return {
            "project": self.project_name, "state": self.project_state, "enableDI": self.enable_di,
            "estop": self.estop, "fault": self.fault, "mode": self.mode, "hb": self.dint(REG_HB),
            "echo": self.dint(REG_HB_ECHO), "tripped": bool(self.coils.get(COIL_WD_TRIPPED)),
            "ownerTablet": self.wd_owner_tablet, "strict": self.strict,
        }


# ------------------------------------------------------------------ modbus --
class ModbusServer:
    def __init__(self, robot: Robot):
        self.robot = robot

    async def handle(self, reader, writer):
        peer = writer.get_extra_info("peername")
        log(f"Modbus client connected {peer}")
        try:
            while True:
                header = await reader.readexactly(7)
                tid, pid, length, unit = struct.unpack(">HHHB", header)
                pdu = await reader.readexactly(length - 1)
                resp = self.process(pdu)
                writer.write(struct.pack(">HHHB", tid, pid, len(resp) + 1, unit) + resp)
                await writer.drain()
        except (asyncio.IncompleteReadError, ConnectionError, OSError):
            pass
        finally:
            log(f"Modbus client disconnected {peer}")
            writer.close()

    def process(self, pdu: bytes) -> bytes:
        r = self.robot
        fc = pdu[0]
        try:
            if fc in (1, 2):
                addr, qty = struct.unpack(">HH", pdu[1:5])
                bits = [bool(r.coils.get(addr + i, False)) for i in range(qty)]
                data = bytearray((qty + 7) // 8)
                for i, b in enumerate(bits):
                    if b:
                        data[i // 8] |= 1 << (i % 8)
                return bytes([fc, len(data)]) + bytes(data)
            if fc in (3, 4):
                addr, qty = struct.unpack(">HH", pdu[1:5])
                vals = [r.regs.get(addr + i, 0) & 0xFFFF for i in range(qty)]
                return bytes([fc, 2 * qty]) + struct.pack(f">{qty}H", *vals)
            if fc == 5:
                addr, val = struct.unpack(">HH", pdu[1:5])
                r.on_coil_write(addr, val == 0xFF00)
                return pdu[:5]
            if fc == 6:
                addr, val = struct.unpack(">HH", pdu[1:5])
                r.regs[addr] = val
                return pdu[:5]
            if fc == 15:
                addr, qty, _n = struct.unpack(">HHB", pdu[1:6])
                for i in range(qty):
                    r.on_coil_write(addr + i, bool(pdu[6 + i // 8] >> (i % 8) & 1))
                return pdu[:5]
            if fc == 16:
                addr, qty, _n = struct.unpack(">HHB", pdu[1:6])
                vals = struct.unpack(f">{qty}H", pdu[6:6 + 2 * qty])
                for i, v in enumerate(vals):
                    r.regs[addr + i] = v
                return pdu[:5]
            return bytes([fc | 0x80, 1])       # illegal function
        except struct.error:
            return bytes([fc | 0x80, 3])       # illegal data value


# --------------------------------------------------------------- websocket --
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


class WsServer:
    def __init__(self, robot: Robot):
        self.robot = robot

    async def handle(self, reader, writer):
        peer = writer.get_extra_info("peername")
        try:
            request = await reader.readuntil(b"\r\n\r\n")
            headers = {}
            for line in request.decode("latin-1").split("\r\n")[1:]:
                if ":" in line:
                    k, v = line.split(":", 1)
                    headers[k.strip().lower()] = v.strip()
            key = headers.get("sec-websocket-key")
            if not key:
                writer.close()
                return
            accept = base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode()
            writer.write(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                          f"Connection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n").encode())
            await writer.drain()
            log(f"WebSocket client connected {peer}")
            while True:
                opcode, payload = await self.read_frame(reader)
                if opcode == 8:
                    break
                if opcode == 9:
                    self.send_frame(writer, 10, payload)
                elif opcode == 1:
                    reply = self.process(payload.decode("utf-8"))
                    if reply is not None:
                        self.send_frame(writer, 1, json.dumps(reply).encode())
                await writer.drain()
        except (asyncio.IncompleteReadError, asyncio.LimitOverrunError, ConnectionError, OSError):
            pass
        finally:
            log(f"WebSocket client disconnected {peer}")
            writer.close()

    @staticmethod
    async def read_frame(reader):
        b0, b1 = await reader.readexactly(2)
        opcode, masked, n = b0 & 0x0F, b1 & 0x80, b1 & 0x7F
        if n == 126:
            n = struct.unpack(">H", await reader.readexactly(2))[0]
        elif n == 127:
            n = struct.unpack(">Q", await reader.readexactly(8))[0]
        mask = await reader.readexactly(4) if masked else b"\0\0\0\0"
        data = bytearray(await reader.readexactly(n))
        for i in range(n):
            data[i] ^= mask[i % 4]
        return opcode, bytes(data)

    @staticmethod
    def send_frame(writer, opcode, payload: bytes):
        n = len(payload)
        if n < 126:
            head = struct.pack(">BB", 0x80 | opcode, n)
        elif n < 65536:
            head = struct.pack(">BBH", 0x80 | opcode, 126, n)
        else:
            head = struct.pack(">BBQ", 0x80 | opcode, 127, n)
        writer.write(head + payload)

    def process(self, text: str):
        r = self.robot
        try:
            req = json.loads(text)
        except json.JSONDecodeError:
            return {"code": 400, "msg": "bad json"}
        typ, action, data = req.get("type"), req.get("action"), req.get("data")
        code, msg, out = 0, "", None
        if typ == "projexecute":
            if action == "run":
                code, msg = r.start((data or {}).get("projectName"), "ws")
            elif action == "stop":
                code, msg = r.stop("ws")
            elif action == "pause":
                code, msg = r.pause("ws")
            elif action == "resume":
                code, msg = r.resume("ws")
            elif action == "getProjectState":
                out = r.project_state
            else:
                code, msg = 10069, "Invalid command."
        elif typ == "common":
            if action == "getRobotStates":
                out = r.robot_states()
            elif action == "getDI":
                port = (data or {}).get("port")
                out = 1 if (port == r.enable_di_port and r.enable_di) else 0
            elif action == "getparam":
                out = {p: r.control_state() for p in (data or []) if p == "Robot/Control/state"}
            elif action == "setparam":
                for item in data or []:
                    if item.get("path") in ("Robot/Control/command", "Robot/Control/state"):
                        if item.get("value") == 100:
                            r.fault, r.last_error = False, ""
                            log("ClearError")
                        elif item.get("value") == 501:
                            r.warning = False
            elif action == "stopMov":
                log("[ws] stopMov")
            else:
                code, msg = 10069, "Invalid command."
        elif typ == "sim" and action == "cmd":
            out = r.console(str(data))
            log(f"[sim] {out}")
        else:
            code, msg = 10069, "Invalid command."
        inner = {"msg": msg, "code": code}
        if out is not None:
            inner["data"] = out
        return {"id": req.get("id"), "type": typ, "action": action, "time": now_ms(),
                "code": 200, "msg": "", "data": inner}


# -------------------------------------------------------------------- main --
async def ticker(robot: Robot):
    while True:
        robot.tick()
        await asyncio.sleep(0.05)


def console_thread(robot: Robot, loop):
    for line in sys.stdin:
        if line.strip().lower() in ("quit", "exit"):
            loop.call_soon_threadsafe(loop.stop)
            return
        async def run_in_loop(cmd=line):
            return robot.console(cmd)

        out = asyncio.run_coroutine_threadsafe(run_in_loop(), loop).result()
        if out:
            print(out, flush=True)


async def main_async(args):
    robot = Robot(args)
    mb = await asyncio.start_server(ModbusServer(robot).handle, args.host, args.modbus_port)
    ws = await asyncio.start_server(WsServer(robot).handle, args.host, args.ws_port)
    log(f"Codroid simulator: Modbus TCP {args.host}:{args.modbus_port}, WebSocket ws://{args.host}:{args.ws_port}")
    log(f"Projects: {PROJECTS}  enable DI{args.enable_di}=OFF  mode={args.mode}  timeout={args.timeout} ms")
    if not args.no_console:
        threading.Thread(target=console_thread, args=(robot, asyncio.get_running_loop()), daemon=True).start()
        log("Type 'help' for console commands.")
    async with mb, ws:
        await ticker(robot)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--modbus-port", type=int, default=502)
    ap.add_argument("--ws-port", type=int, default=9000)
    ap.add_argument("--enable-di", type=int, default=15)
    ap.add_argument("--timeout", type=int, default=1500, help="watchdog timeout in ms")
    ap.add_argument("--mode", choices=["auto", "manual", "remote"], default="auto")
    ap.add_argument("--require-remote", action="store_true", help="Modbus/WS start needs remote mode")
    ap.add_argument("--strict", action="store_true", help="native heartBeatFromMaster detection ON")
    ap.add_argument("--hbm-addr", type=int, default=None, help="address of heartBeatFromMaster register")
    ap.add_argument("--no-console", action="store_true")
    args = ap.parse_args()
    try:
        asyncio.run(main_async(args))
    except (KeyboardInterrupt, RuntimeError):
        pass


if __name__ == "__main__":
    main()

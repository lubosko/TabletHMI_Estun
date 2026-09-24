# Robot-side setup: Tablet HMI (Codroid Gen1 + Gen2)

Do these steps once per robot. Menu paths are the same on Gen1 (S-Series SW manual V2.0) and Gen2 (manual v1.1) unless noted.

## 1. Network (Wi-Fi)
1. Connect an industrial Wi-Fi access point to controller **LAN1** with an Ethernet cable. The controller has no built-in Wi-Fi.
2. AP settings: 5 GHz, WPA2/WPA3, one AP only (no roaming), no bridge to the plant network.
3. Give the robot, AP and tablet static IPs in one subnet. Set the robot IP in Hamburger menu → Settings → Network. The default API address is `192.168.101.100`.

## 2. Register communication (Modbus TCP slave, port 502)
1. Configuration → Communication → Register (Gen2: Register Communication).
2. Protocol: **ModbusTCP** (the default). Only one of ModbusTCP / PN / EIP can be active.
3. **External Device Access: ON.**
4. **Heartbeat Detection:** leave it **OFF** for normal cells. Turn it ON (interval 1000 ms) only for "strict mode" cells that are always run from the tablet. In strict mode, the controller reports error 10057 and projects won't run whenever the tablet is off.
5. Save and restart the controller if the protocol was changed.

## 3. Phase 0: confirm addresses (write them down for the tablet profile)
On the Register page, note the Modbus addresses shown for:

| Tablet profile field | Default | Register type needed |
|---|---|---|
| `regHeartbeat` | 49000 | Int (DInt) **rw** |
| `regHeartbeatEcho` | 49002 | Int (DInt) |
| `coilEnabled` | 9900 | Bool |
| `coilWdTripped` | 9901 | Bool |
| `coilTabletStart` | 9902 | Bool **rw** |
| `regHeartBeatFromMaster` | (from UI) | system, only for strict mode |
| `regStartProjectNumber` | 42000 | system |
| `coilStartProject` / `coilStopProject` / `coilPauseProject` / `coilClearWarning` | 1000 / 1001 / 1002 / 1005 | system |
| status coils | 2000–2013 | system |

The addresses in `TabletHMI_watchdog.lua` and in the tablet's controller profile **must match**.

Also check these on the real robot and record the results:
- Do coils 1000–1002 need the mode selector in **Remote**, or do they work in **Auto**? (Error 10074 "Remote mode not enabled" means Remote is needed.)
- Does pulsing coil 1000 while paused **resume** the program? If not, the tablet resumes over WebSocket.
- Can a script write a register that the UI marks **ro**? If not, pick rw registers for the echo and flags.
- What word order does a DInt use (high word first?) Set `dintHighWordFirst` in the tablet profile.

## 4. Project Mapping
IO → **Project Mapping**: give each program that the tablet may start a number (1, 2, 3…). Use the same numbers and names in the tablet's program table.

## 5. HMI ON/OFF (enable DI)
Choose a spare DI (default **DI15**) and do one of the following:
- Wire a **key switch** (24 V) to it: ON means Tablet HMI enabled.
- Or leave it unwired and **force** it in the IO debug page (right drawer → IO → unlock → force DI15 ON/OFF).

Set the same port in `HMI_ENABLE_DI` in the script and in `enableDiPort` in the tablet profile.

## 6. Watchdog in every tablet program
1. Program → drawer → **Module** → create module `TabletHMI`, method `watchdog`. Paste the whole of `TabletHMI_watchdog.lua` as its body.
2. In each mapped project: Task list → **Thread** → add a thread (for example `hmi_watchdog`) with the body:
   ```lua
   callModule("TabletHMI", "watchdog")
   ```
   If module calls aren't allowed in threads on your firmware, paste the whole script into the thread instead.
3. Start the project once from the pendant with the enable DI OFF. It must run normally, and the log shows no watchdog message.

## 7. Commissioning test (tablet Settings → Watchdog test)
For every program in the tablet list:
1. Enable DI ON, then start the program from the tablet.
2. Press **Watchdog test**. The tablet stops sending heartbeats.
3. The program must stop within `TIMEOUT_MS` (1.5 s), and the tablet reports PASS.

A program that doesn't stop is missing the watchdog thread. Fix it before production.

> **Safety:** the watchdog is a functional stop, not a safety-rated (PL/SIL) function. The hardwired E-stop stays mandatory.

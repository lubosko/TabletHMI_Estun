# Real implementation plan: Codroid Tablet HMI on a production robot

## Context
The HMI is proven in simulation: `flutter test` 36/36, the Dart Modbus/WebSocket clients against `tools/robot_sim.py`, the smoke test 23/23, and the app on the tablet emulator — including a watchdog trip that stopped the program 2.5 s after the app was killed. Nothing has yet touched a real Codroid controller.

This plan takes it from simulation to one production cell: **consumer Android tablet, one robot as a pilot, internal use**, plus evaluation of a **hardware DO→DI stop loop** that does not depend on the script engine.

Two things make the real robot different from the simulator, and they drive the plan:
1. **The simulator's register map is an assumption.** Addresses, Remote-mode requirement, DInt word order and command rate limits come from the V2.3 manual, not from the machine.
2. **Android will suspend the app.** Screen off, a notification, a phone call, Doze — the heartbeat stops and the robot stops. That is fail-safe but unusable, so the app must stop the program *deliberately* when it leaves the foreground, and the tablet must be locked into kiosk mode.

## Decisions taken
- Pilot on one robot first; `RobotProfile` already carries a `generation` field, so the second generation is a second profile, not a second app.
- Consumer Android tablet with kiosk lockdown (device-owner lock task, fallback: screen pinning).
- Internal use: test protocol + operator sheet + a note for the cell risk assessment. No CE technical file.
- Evaluate the DO→DI immediate-stop loop during Phase 0 and keep it if it measures better than `stopProject()`.

---

## W0. Project hygiene (half a day)
- `git init`, commit the current tree, and add a tag per released APK. The folder is not under version control today, and per-robot register addresses are about to become production data.
- `.gitignore` is already correct. Remove the stray `tools/__pycache__`.

## W1. Phase 0 — measure the real controller (1 day on the robot)
The single highest-risk step. Build a probe tool first so the robot time is short and repeatable.

**New: `tools/phase0_probe.py`** (stdlib, same style as `sim_smoke_test.py`, reuses its `Modbus`/`Ws` classes)
- **Read-only pass by default:** connect Modbus :502 and WS :9000, read status coils `2000–2013`, `getProjectState`, `getRobotStates`, `getDI(enableDiPort)`, sweep candidate user-register addresses and report which respond.
- **`--write` pass, run with the robot powered but not enabled:** write the heartbeat DInt in both word orders and read it back (settles `dintHighWordFirst`), pulse `coilTabletStart`, and test whether a script can write an `ro` register.
- **`--rate-test`:** sustain 200 ms heartbeat writes plus 200 ms polls for 10 minutes; report latency p50/p95/max, errors, and any WS 10064 "request queue full".
- Output: a filled-in profile JSON for the app plus a `robot/PHASE0_<robot>.md` record.

**Checks that need a human at the pendant** (already listed in `robot/SETUP.md` §3, to be answered and recorded):
- Do coils `1000/1001/1002` work in **Auto**, or is **Remote** mode required (error 10074)?
- Does pulsing `1000` while paused resume, or is WS `resume` needed? → sets `resumeViaStartCoil`.
- Real addresses of the Int rw / Bool rw registers from Configuration → Communication → Register.
- **Stop reaction:** run a test program at 100 % speed, trip the watchdog, and measure time and distance from trip to standstill. This number sets `robotTimeoutMs` and goes in the operator sheet.
- Script-engine load: watchdog thread at 50 ms — check cycle jitter and raise to 100 ms if the controller strains.

**Gate:** no robot-side code is finalised until every Phase 0 answer is recorded.

## W2. Robot side hardening (1 day)
- Update `robot/TabletHMI_watchdog.lua` constants to the measured addresses, and add the measured `TIMEOUT_MS`.
- **DO→DI immediate-stop loop (evaluate, then keep or drop):** the watchdog sets a spare DO (`setDO`) on trip, wired back to a DI bound in IO configuration to **User Event – Stop Immediately** (system input, message 9009). Compare stop time against plain `stopProject()`. Keep it if it is faster or if it stops the robot when the script thread is blocked; the wiring is one pair plus one DO and one DI.
- Wire the **enable key switch** to the chosen DI (a forced DI is fine for the bench, not for production).
- **Before touching production programs:** export all projects via Plugin → Import/Export as a rollback point; add the `TabletHMI` module and the one-line thread to each mapped program; re-verify each program runs from the pendant with the HMI switched OFF.
- Fill in Project Mapping numbers and mirror them into the tablet's program table.

## W3. App production hardening (3–4 days)
Ordered by how much they matter in a real cell.

1. **Foreground/lifecycle stop (P1).** `HmiController` gains a `WidgetsBindingObserver`: on `AppLifecycleState.inactive/paused`, immediately `stopProgram(reason: 'HMI left foreground')` rather than waiting for the watchdog timeout. Screen off or app switched away = program stops, deliberately and with a log entry. Files: `app/lib/main.dart`, `app/lib/state/hmi_controller.dart`.
2. **Kiosk mode (P1).** Device-owner lock task via `adb shell dpm set-device-owner` on a factory-reset tablet, documented in a new `TABLET_SETUP.md`: disable auto-rotate lock conflicts, notifications, Doze for the app, auto-brightness, and set the app as home activity. Fallback: manual screen pinning.
3. **Wi-Fi stability (P1).** Hold a high-performance Wi-Fi lock so Android power-save cannot add latency spikes (small platform channel in `MainActivity.kt`, or a plugin). Then re-tune `robotTimeoutMs` from the measured jitter.
4. **Diagnostics screen (P1, commissioning aid).** Live latency p50/p95/max for the heartbeat write and the poll cycle, link uptime, trip counter. This is what tells you whether a nuisance trip was Wi-Fi or the robot. New `app/lib/ui/diagnostics_screen.dart`, counters in `HmiController`.
5. **Persistent event log (P2 → now P1 for a pilot).** The log is in memory only (`HmiController._log`); write it to a rotating file and add export. Without it, a trip at 03:00 leaves no evidence.
6. **Alarm text (P2).** Map the common Codroid codes (10057, 10074, 10063/10068, 13030, 13031, 3220) to plain text so the operator sees a cause, not a number.
7. **Config file export/import (P2).** Settings JSON currently moves through the clipboard; add save/load to a file so each robot's profile is backed up and restorable.
8. **Release build (P1).** Signing keystore, `applicationId` fixed, version from `pubspec.yaml`, `flutter build apk --release`, and the APK archived per git tag.

## W4. Network build-out (1 day, mostly yours)
- Industrial AP on controller **LAN1**: 5 GHz, WPA2/3, fixed channel chosen after a quick scan, no mesh/roaming, no bridge to the plant network, powered from the cell cabinet.
- Static IPs for robot, AP and tablet; record them in the profile and on a label in the cabinet.
- Survey RSSI at every position the operator stands in, including with the cell door closed and with the robot arm between tablet and AP.
- Acceptance: RSSI ≥ −65 dBm everywhere, and the `--rate-test` p95 latency inside the budget for a 1.5 s timeout.

## W5. Validation on the robot (1–2 days)
Run the acceptance list from the PRD, and record measured values rather than ticks:

| Test | Pass condition |
|---|---|
| Start/stop/pause/resume each mapped program | Behaves as from the pendant |
| Tablet Wi-Fi off while moving at 100 % | Robot stops, time and distance recorded |
| App killed / tablet powered off | Same |
| AP powered off | Same |
| Tablet screen off (lifecycle stop) | Program stops immediately, logged |
| Enable DI OFF | Tablet commands disabled, pendant unaffected, no trip |
| Enable DI OFF during a tablet-started program | Watchdog stops it |
| Program without the watchdog thread | Tablet detects a missing echo and stops it |
| Watchdog test button, every program | PASS |
| 8-hour soak in normal production | Zero nuisance trips |
| E-stop, alarm, clear alarm | Correct display and recovery |

**Gate to production use:** the 8-hour soak passes and the measured stop distance is acceptable for the cell layout.

## W6. Handover (half a day)
- `OPERATOR.md`: one page, with photos — what the buttons do, what COMMUNICATION LOST means, what the key switch does, and the explicit statement that **STOP is not an E-stop**.
- A physical label on the tablet saying the same.
- Add a line to the cell's risk assessment: a functional stop, not a safety function, with the measured reaction time.
- `MAINTENANCE.md`: how to update the APK, how to restore a robot profile, what to check if trips recur.

---

## Sequencing and gates
```
W0 hygiene ─┐
            ├─ W1 Phase 0 on robot ── gate: answers recorded
W4 network ─┘          │
                       ├─ W2 robot side (uses measured values)
                       └─ W3 app hardening (parallel, on the simulator)
                                   │
                                   └─ W5 validation ── gate: soak passes ── W6 handover
```
Roughly 7–9 working days of work, of which 2–3 days need the robot. W3 can proceed against the simulator while robot access is unavailable.

## Verification
- Unchanged fast loop: `flutter test` in `app/`, and `python tools/sim_smoke_test.py`; both must stay green while W3 lands.
- Extend `tools/robot_sim.py` with a lifecycle-stop scenario and a mode that rejects coils unless "Remote", so the new app behaviour is testable off-robot; add unit tests for the lifecycle stop and latency counters in `app/test/`.
- `tools/phase0_probe.py` is itself verified against the simulator before it is pointed at the robot.
- On the robot: `RUN_SIMULATION.md` stays the bench manual; W5's table is the acceptance record, stored as `robot/VALIDATION_<robot>_<date>.md`.

## Risks
| Risk | Mitigation |
|---|---|
| Register addresses or Remote-mode behaviour differ from the manual | Phase 0 probe before any robot-side code is finalised; everything is profile-driven, no hardcoding |
| Android suspends the app and the robot stops mid-cycle | Deliberate lifecycle stop, kiosk mode, Wi-Fi lock, keep-awake; operator sheet explains it |
| Adding the watchdog thread breaks an existing program | Export all projects first; re-verify each from the pendant; rollback is an import |
| Script engine stalls, so the watchdog cannot stop anything | The DO→DI loop in W2, evaluated with measurements |
| Wi-Fi jitter causes nuisance trips | Dedicated AP, RSSI survey, rate test, diagnostics screen, timeout tuned to measured p95 |
| Tablet treated as a safety device | Label, operator sheet, risk-assessment line; E-stop stays hardwired |

## Out of scope for the pilot
Multi-robot profile switching, MDM-based APK distribution, speed override (FR-16), and Gen1/Gen2 dual commissioning — all revisited after the pilot soak.

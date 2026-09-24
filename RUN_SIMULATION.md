# Running the Tablet HMI on this PC (simulation only, no robot)

Everything runs on the PC: the **robot simulator** (Python) plays the Codroid controller, and the **tablet app** runs on the Android emulator. No robot, no tablet, no network hardware.

```
Android emulator (tablet app)  --10.0.2.2:1502-->  robot_sim.py  (Modbus TCP slave)
                               --10.0.2.2:19000->                (Codroid WebSocket API)
```
The emulator always reaches the PC's own localhost as **10.0.2.2**. Ports 1502/19000 are used instead of the real 502/9000 so nothing needs administrator rights.

---

## 0. One-time check
Open a **new** PowerShell window (new, so it picks up the PATH) and verify:

```bash
flutter --version
```
```bash
adb version
```
```bash
python --version
```
If `flutter` is not found, see the dev environment section of [README.md](README.md).

---

## 1. Quick check without the app (30 seconds)
This runs the simulator and a script that imitates the tablet, covering all the acceptance scenarios:

```bash
python tools/sim_smoke_test.py
```
Expect `23/23 checks passed`. If that works, the robot-side logic is fine and you only need the app for the UI.

---

## 2. Start the simulator — terminal 1
```bash
python tools/robot_sim.py --host 127.0.0.1 --modbus-port 1502 --ws-port 19000
```
Leave it running. It prints every event (program start/stop, watchdog trips) and accepts commands you type:

| Command | Meaning |
|---|---|
| `di on` / `di off` | The robot-side Tablet-HMI enable DI (key switch) |
| `status` | Current state as JSON (program, heartbeat, echo, trip flag) |
| `estop on` / `estop off` | Emergency stop pressed/released |
| `mode auto` / `manual` / `remote` | Mode selector on the pendant |
| `nowd` | The **next** started program has **no** watchdog thread (to test that case) |
| `wd` | Back to normal (watchdog present) |
| `fault` | Put the robot into an error state |
| `strict on` / `off` | Native heartBeatFromMaster detection |
| `help`, `quit` | Help, exit |

---

## 3. Start the tablet emulator — terminal 2
```bash
emulator -avd codroid_tablet
```
First boot takes 1–3 minutes. Wait until the Android home screen appears.

Check it is ready:
```bash
adb devices
```
It must say `emulator-5554   device` (not `offline`).

---

## 4. Build and install the app — terminal 3
From the `app` folder. This bakes in the simulator address as the default:

```bash
flutter build apk --debug --dart-define=HMI_HOST=10.0.2.2 --dart-define=HMI_MODBUS_PORT=1502 --dart-define=HMI_WS_PORT=19000
```
```bash
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```
```bash
adb shell am start -n ai.codroid.tablet_hmi/.MainActivity
```

The first screen can sit on the Flutter logo for ~20 s on a freshly booted emulator. Then the HMI appears with **Control OK** and **Status OK** chips in the top-right corner, and the simulator terminal shows a Modbus and a WebSocket client connecting.

> `flutter run -d emulator-5554 --dart-define=...` is the normal developer loop with hot reload. Use it from a real terminal window; the build-and-install commands above are what has been verified in this project so far.

---

## 5. Walk through the scenarios

### 5.1 Normal start and stop
1. In terminal 1 (simulator), type `di on`. The app's status panel shows **Tablet HMI: ON (robot switch)**.
2. Tap a program in the list, for example **2 Screwing**.
3. Tap **START**. The app shows **RUNNING**, and **Robot watchdog: Active**.
   The simulator logs `project 'Screwing' RUNNING (owner=tablet, watchdog=yes)`.
4. Tap **STOP**. Both go back to IDLE.

### 5.2 Communication lost (the safety case)
With a program running, kill the app:
```bash
adb shell am force-stop ai.codroid.tablet_hmi
```
Within ~1.5 s the simulator logs `WATCHDOG TRIP: tablet heartbeat lost ... -> stopProject()`. Type `status` to see `"state": "IDLE", "tripped": true`.

Restart the app (step 4, last command). It shows a red latched **COMMUNICATION LOST** banner and refuses START until you tap **ACKNOWLEDGE**.

### 5.3 Robot-side ON/OFF switch
With a tablet-started program running, type `di off` in the simulator. The program stops immediately (the tablet owns it and the HMI was switched off), and the app greys out the commands and shows the grey "switched OFF on the robot" banner. `di on` re-enables them.

### 5.4 Program without the watchdog thread
1. Type `nowd` in the simulator, then start any program from the tablet.
2. Within ~1 s the app raises "Program has no HMI watchdog thread - stopped for safety" and stops it, because the watchdog echo never changes.
3. Type `wd` to return to normal.

### 5.5 Watchdog test button (commissioning)
1. Start a program from the tablet.
2. Tap the gear icon, enter PIN **1234**, scroll to **Commissioning: watchdog test**, tap **Run watchdog test**.
3. The app pauses the heartbeat and expects the robot to stop. Result should read `PASS: robot stopped after ~1500 ms`.

### 5.6 E-stop and alarms
Type `estop on` in the simulator: the app shows **E-STOP PRESSED** in red and any program stops. `estop off`, then **CLEAR ALARM** returns it to normal. `fault` sets an error state that **CLEAR ALARM** clears.

---

## 6. Shut down
- Terminal 1: type `quit` (or Ctrl+C).
- Emulator: close its window, or:
```bash
adb emu kill
```

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| App shows **Control LOST** / no data | The simulator isn't running, or it was started on different ports. It must be reachable at 127.0.0.1:1502 and :19000. |
| App connects to the wrong address | Saved Settings win over the `--dart-define` defaults. Either fix the address in Settings (PIN 1234) or wipe app data: `adb shell pm clear ai.codroid.tablet_hmi` |
| `adb devices` says `offline` | `adb kill-server`, then `adb start-server`, and wait for the emulator to finish booting. |
| App stays on the Flutter logo | Wait ~20 s on a cold emulator. If it stays, check `adb logcat -d -t 50`. |
| Port 502 permission denied | Ports below 1024 need administrator rights on Windows. Use 1502 as shown here. |
| Emulator very slow | Close other VMs, and make sure Windows Hypervisor Platform is enabled. |
| Gradle asks for an NDK | It is installed (28.2.13676358). Do not let Gradle auto-install it — that path calls the deprecated `sdkmanager.bat`, which crashes. Use `android sdk install "ndk;<version>"`. |

## What this does *not* test
The simulator imitates the controller's register map and watchdog behaviour, so it proves the app logic, timing and UI. It cannot confirm the real controller's register addresses, whether Remote mode is required, the DInt word order, or actual robot deceleration. Those are the Phase 0 checks in [robot/SETUP.md](robot/SETUP.md).

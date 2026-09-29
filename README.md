
<img width="1280" height="800" alt="01_idle" src="https://github.com/user-attachments/assets/0b1f4bb6-3979-4aea-aab6-fcacb5d4147a" />
# Codroid Tablet HMI

A Wi-Fi Android tablet HMI for ESTUN S-Series cobots with **Codroid Gen1 and Gen2** controllers. It lets an operator select a program, then START, PAUSE, RESUME or STOP it. A heartbeat watchdog stops the robot when the tablet link is lost.

- **Control and heartbeat:** Modbus TCP (port 502) over Wi-Fi.
- **Detailed status:** Codroid WebSocket API (port 9000).
- **Robot side:** a watchdog thread (`robot/TabletHMI_watchdog.lua`) in every tablet-startable project. It runs `stopProject()` when the heartbeat counter stops changing for 1.5 s. The Tablet HMI is switched ON/OFF on the robot with a DI (key switch or forced DI).

> The watchdog is a functional stop, not a safety-rated function. The hardwired E-stop stays mandatory.

## Layout
| Path | What |
|---|---|
| `docs/` | ESTUN manuals (API, communication, Gen1/Gen2 software) |
| `robot/TabletHMI_watchdog.lua` | Watchdog thread/module for the controller |
| `robot/SETUP.md` | Controller setup and commissioning (Gen1 + Gen2) |
| `app/` | Flutter tablet app (`lib/`, `test/`) |
| `tools/robot_sim.py` | Robot simulator: Modbus TCP + WebSocket + watchdog (Python stdlib) |
| `tools/sim_smoke_test.py` | End-to-end acceptance scenarios against the simulator |
| `RUN_SIMULATION.md` | **Step-by-step: run the whole thing on a PC with no robot** |

## Quick start

### 1. Simulator (no robot needed)
```bash
python tools/sim_smoke_test.py
```
This runs the PRD acceptance scenarios: start, heartbeat loss, HMI OFF, pendant start, pause/resume, missing watchdog, and E-stop.

Interactive simulator (console commands: `di on`, `estop on`, `nowd`, `status`, `help`):
```bash
python tools/robot_sim.py --host 0.0.0.0 --modbus-port 1502 --ws-port 9000
```
Port 502 may need admin rights on Windows. In that case use 1502 and set the Modbus port in the app settings.

### 2. Tablet app
Install the Flutter SDK (3.27 or newer) and Android Studio. Then, once:
```bash
cd app
flutter create --platforms=android,windows --project-name tablet_hmi .
flutter pub get
flutter test
```
`flutter create .` generates the `android/` and `windows/` folders and keeps the existing `lib/` and `test/`.

For Android, add to `android/app/src/main/AndroidManifest.xml` (outside `<application>`):
```xml
<uses-permission android:name="android.permission.INTERNET"/>
```
The robot uses plain `ws://`. If Android blocks cleartext traffic, add `android:usesCleartextTraffic="true"` to the `<application>` tag.

Run the app:
```bash
flutter run -d windows
```
```bash
flutter build apk --release
```
Settings (gear icon, default PIN `1234`) hold the robot IP, register addresses, timeouts and the program table. The table maps Project Mapping number to display name.

Integration test of the Dart clients against the simulator (after starting the simulator on 1502/19000):
```bash
python tools/robot_sim.py --host 127.0.0.1 --modbus-port 1502 --ws-port 19000
```
```bash
flutter test test/sim_integration_test.dart
```
(set the `SIM_HOST=127.0.0.1` environment variable first)

### 3. Robot
Follow [robot/SETUP.md](robot/SETUP.md). It covers the AP on LAN1, register communication, Phase 0 address checks, Project Mapping, the enable DI, adding the watchdog thread, and the watchdog test.

## Dev environment on this PC
`flutter`, `dart`, `adb`, `emulator` and `git` are on the user PATH, and `ANDROID_HOME` points at the SDK. The Flutter SDK sits in `C:\Users\Dusan\Downloads\flutter_windows_3.47.5-stable\flutter`; if you move it, update that PATH entry. The pre-change PATH is saved in `.path-backup.txt`.

Installed: Flutter 3.47.5 (Dart 3.13.4), Git 2.55, Android Studio 2026.1.4 with SDK platforms android-36/37, build-tools 36, cmdline-tools, NDK 28.2.13676358, emulator AVD **codroid_tablet** (10.1" tablet, Android 16).

Start the emulator and run the app against the simulator on this PC:
```powershell
& "$env:LOCALAPPDATA\Android\Sdk\emulator\emulator.exe" -avd codroid_tablet
```
```powershell
flutter run -d emulator-5554 --dart-define=HMI_HOST=10.0.2.2 --dart-define=HMI_MODBUS_PORT=1502 --dart-define=HMI_WS_PORT=19000
```
The emulator reaches the PC's localhost as `10.0.2.2`. The `--dart-define` values only seed the default profile; saved Settings win.

Gradle notes: `android/app/build.gradle.kts` no longer pins `ndkVersion` (the Flutter plugin sets it anyway), and the NDK had to be installed with `android sdk install "ndk;28.2.13676358"` because Gradle's auto-install path calls the deprecated `sdkmanager.bat`, which crashes.

## Status
- **Verified on this PC:** `flutter analyze` clean, `flutter test` 36/36 passing, Dart clients against the simulator passing, simulator smoke test 23/23, and the app running on the tablet emulator: it connected, started program #2 over Modbus (owner = tablet, watchdog echo live), latched COMMUNICATION LOST when the emulator slept, and blocked START until acknowledged. **Killing the app stopped the running program within 2.5 s** and set `HMI_WD_TRIPPED`.
- **Not yet done:** nothing has run on a real Codroid controller (Phase 0 questions in `robot/SETUP.md`), no release APK signing, no kiosk/lock-task setup, event log persistence (P2) and speed override (P3) are not implemented.

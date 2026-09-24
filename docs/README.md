# Reference documentation

ESTUN's manuals are **not** in this repository: they are vendor copyrighted material. Keep your own copies in this folder (they are git-ignored). Obtain them from ESTUN / CoDroid after-sales support.

| File expected here | Used for |
|---|---|
| `CodroidApi_EN.pdf` | The WebSocket API on `ws://ROBOT_IP:9000`: `projexecute` run/stop/pause/resume/getProjectState, `getRobotStates`, `getDI`, `setDO`, `setparam Robot/Control/command` |
| `ESTUN Codroid+ Communication User Manual V2.3.pdf` | Chapter 7 register communication and heartbeat detection; chapter 10 remote control — system input coils 1000–1013, `42000 startProjectNumber`, status coils 2000–2013 |
| `S-Series Software User Manual_v2.0.pdf` (Gen1) | Threads, modules, Project Mapping, IO configuration, script functions (Appendix C), error codes |
| `S Series Gen2 Software User Manual_v1.1 en-US.pdf` (Gen2) | Same topics for Gen2; register communication supports more slave protocols |

Two cautions taken from these manuals:

- The remote-control register table is documented **for software V2.3**. On any other firmware the addresses must be confirmed on the controller (Configuration → Communication → Register). That is the Phase 0 step in [../robot/SETUP.md](../robot/SETUP.md).
- The API document is inconsistent about `Robot/Control/state` versus `Robot/Control/command` in the `setparam` example. Confirm on the robot before relying on it.

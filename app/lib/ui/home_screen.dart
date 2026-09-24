import 'package:flutter/material.dart';

import '../config/profile_store.dart';
import '../state/hmi_controller.dart';
import '../state/supervision.dart';
import 'settings_screen.dart';
import 'widgets.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.controller, required this.store});

  final HmiController controller;
  final ProfileStore store;

  Future<void> _openSettings(BuildContext context) async {
    if (!await askPin(context, controller.profile.settingsPin)) return;
    if (!context.mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => SettingsScreen(controller: controller, store: store),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final c = controller;
        final il = c.interlocks;
        return Scaffold(
          appBar: AppBar(
            title: Text(c.profile.robotName, style: const TextStyle(fontWeight: FontWeight.bold)),
            actions: [
              LinkChip(label: 'Control', state: c.modbusState),
              LinkChip(label: 'Status', state: c.wsState),
              IconButton(
                iconSize: 32,
                tooltip: 'Settings',
                icon: const Icon(Icons.settings),
                onPressed: () => _openSettings(context),
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: Column(children: [
            if (c.commLostLatched)
              HmiBanner(
                color: kRed,
                icon: Icons.wifi_off,
                text: 'COMMUNICATION LOST - the robot watchdog stops the program. '
                    'Check Wi-Fi, then acknowledge.',
                action: FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: kRed),
                  onPressed: c.modbusState == LinkState.connected ? c.acknowledgeCommLost : null,
                  child: const Text('ACKNOWLEDGE'),
                ),
              ),
            if (c.alarm != null)
              HmiBanner(color: const Color(0xFFE65100), icon: Icons.warning_amber, text: c.alarm!),
            if (c.hmiEnabled == false)
              const HmiBanner(
                color: kGrey,
                icon: Icons.lock_outline,
                text: 'Tablet HMI is switched OFF on the robot (enable DI). Control is on the pendant.',
              ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  SizedBox(width: 380, child: _ProgramList(controller: c)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      _StatusPanel(controller: c),
                      const SizedBox(height: 12),
                      if (!il.canStart && il.startBlockedReason != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text('START blocked: ${il.startBlockedReason}',
                              style: const TextStyle(fontSize: 16, color: Colors.white60)),
                        ),
                      Row(children: [
                        Expanded(
                          child: BigButton(
                            label: 'START',
                            icon: Icons.play_arrow,
                            color: kGreen,
                            onPressed: il.canStart ? c.startSelected : null,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: c.program == ProgramState.paused
                              ? BigButton(
                                  label: 'RESUME',
                                  icon: Icons.play_circle_outline,
                                  color: kAmber,
                                  onPressed: il.canResume ? c.resume : null,
                                )
                              : BigButton(
                                  label: 'PAUSE',
                                  icon: Icons.pause,
                                  color: kAmber,
                                  onPressed: il.canPause ? c.pause : null,
                                ),
                        ),
                      ]),
                      const SizedBox(height: 12),
                      BigButton(
                        label: 'STOP',
                        icon: Icons.stop,
                        color: kRed,
                        height: 120,
                        onPressed: il.canStop ? () => c.stopProgram() : null,
                      ),
                      const SizedBox(height: 8),
                      Row(children: [
                        OutlinedButton.icon(
                          onPressed: il.canClear ? c.clearAlarm : null,
                          icon: const Icon(Icons.cleaning_services),
                          label: const Text('CLEAR ALARM'),
                        ),
                        const Spacer(),
                        const Text('STOP is not an E-stop', style: TextStyle(color: Colors.white54)),
                      ]),
                      const SizedBox(height: 8),
                      Expanded(child: _EventLog(controller: c)),
                    ]),
                  ),
                ]),
              ),
            ),
          ]),
        );
      },
    );
  }
}

class _ProgramList extends StatelessWidget {
  const _ProgramList({required this.controller});
  final HmiController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final active = c.program == ProgramState.running || c.program == ProgramState.paused;
    return Card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Padding(
          padding: EdgeInsets.all(12),
          child: Text('Programs', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
        ),
        Expanded(
          child: ListView(
            children: [
              for (final p in c.profile.programs)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: ListTile(
                    minTileHeight: 72,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    selected: c.selectedNumber == p.number,
                    selectedTileColor: Theme.of(context).colorScheme.primaryContainer,
                    enabled: !active,
                    leading: CircleAvatar(radius: 24, child: Text('${p.number}', style: const TextStyle(fontSize: 20))),
                    title: Text(p.name, style: const TextStyle(fontSize: 22)),
                    trailing: c.activeProgram?.number == p.number && active
                        ? const Icon(Icons.precision_manufacturing, color: kGreen, size: 32)
                        : null,
                    onTap: () => c.selectProgram(p.number),
                  ),
                ),
            ],
          ),
        ),
      ]),
    );
  }
}

class _StatusPanel extends StatelessWidget {
  const _StatusPanel({required this.controller});
  final HmiController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final (stateText, stateColor) = switch (c.program) {
      ProgramState.running => ('RUNNING', kGreen),
      ProgramState.paused => ('PAUSED', kAmber),
      ProgramState.idle => ('IDLE', Colors.white70),
      ProgramState.loading => ('LOADING', kAmber),
      ProgramState.error => ('ERROR', kRed),
      ProgramState.unknown => ('NO DATA', kGrey),
    };
    final wdText = switch (c.watchdogVerdict) {
      EchoVerdict.alive => ('Active', kGreen),
      EchoVerdict.waitingFirstEcho => ('Starting...', kAmber),
      EchoVerdict.missingWatchdog => ('MISSING', kRed),
      EchoVerdict.stale => ('NOT RESPONDING', kRed),
      EchoVerdict.notArmed => (c.wdTripped ? 'TRIPPED' : 'Idle', c.wdTripped ? kRed : Colors.white70),
    };
    final hmi = c.hmiEnabled;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(stateText, style: TextStyle(fontSize: 44, fontWeight: FontWeight.w900, color: stateColor)),
              Text(
                c.activeProgram != null &&
                        (c.program == ProgramState.running || c.program == ProgramState.paused)
                    ? '#${c.activeProgram!.number}  ${c.activeProgram!.name}'
                    : (c.selectedProgram != null ? 'Selected: ${c.selectedProgram!.name}' : 'No program selected'),
                style: const TextStyle(fontSize: 20),
              ),
            ]),
          ),
          Expanded(
            child: Column(children: [
              StatusRow(
                label: 'Robot',
                value: c.estop
                    ? 'E-STOP PRESSED'
                    : c.robotError
                        ? 'ERROR'
                        : '${c.robotMode ?? '-'}${c.manualMode ? ' (manual)' : ''}${c.warning ? ' - warning' : ''}',
                color: c.estop || c.robotError ? kRed : null,
              ),
              StatusRow(
                label: 'Tablet HMI',
                value: hmi == null ? 'unknown' : (hmi ? 'ON (robot switch)' : 'OFF (robot switch)'),
                color: hmi == true ? kGreen : (hmi == false ? kAmber : kGrey),
              ),
              StatusRow(label: 'Robot watchdog', value: wdText.$1, color: wdText.$2),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _EventLog extends StatelessWidget {
  const _EventLog({required this.controller});
  final HmiController controller;

  @override
  Widget build(BuildContext context) {
    final entries = controller.log;
    return Card(
      child: ListView.builder(
        padding: const EdgeInsets.all(8),
        itemCount: entries.length,
        itemBuilder: (_, i) {
          final e = entries[i];
          final t = e.time;
          final ts = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:'
              '${t.second.toString().padLeft(2, '0')}';
          return Text('$ts  ${e.text}',
              style: TextStyle(fontSize: 14, color: e.alarm ? const Color(0xFFFF8A65) : Colors.white70));
        },
      ),
    );
  }
}

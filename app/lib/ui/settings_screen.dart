import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/profile_store.dart';
import '../config/robot_profile.dart';
import '../state/hmi_controller.dart';
import 'widgets.dart';

enum _Kind { text, integer, optionalInt }

class _Field {
  const _Field(this.key, this.label, this.kind, [this.help]);
  final String key;
  final String label;
  final _Kind kind;
  final String? help;
}

const _connectionFields = [
  _Field('robotName', 'Robot name', _Kind.text),
  _Field('host', 'Robot IP', _Kind.text, 'Controller LAN1 address'),
  _Field('modbusPort', 'Modbus TCP port', _Kind.integer),
  _Field('wsPort', 'WebSocket port', _Kind.integer),
  _Field('unitId', 'Modbus unit id', _Kind.integer),
  _Field('enableDiPort', 'HMI enable DI port', _Kind.integer, 'Key switch / forced DI (HMI_ENABLE_DI)'),
];

const _registerFields = [
  _Field('regHeartbeat', 'HMI_HB (DInt rw)', _Kind.integer),
  _Field('regHeartbeatEcho', 'HMI_HB_ECHO (DInt)', _Kind.integer),
  _Field('coilEnabled', 'HMI_ENABLED (Bool)', _Kind.integer),
  _Field('coilWdTripped', 'HMI_WD_TRIPPED (Bool)', _Kind.integer),
  _Field('coilTabletStart', 'HMI_TABLET_START (Bool rw)', _Kind.integer),
  _Field('regHeartBeatFromMaster', 'heartBeatFromMaster (strict mode)', _Kind.optionalInt, 'Empty = not used'),
  _Field('regStartProjectNumber', 'startProjectNumber', _Kind.integer),
  _Field('coilStartProject', 'startProject coil', _Kind.integer),
  _Field('coilStopProject', 'stopProject coil', _Kind.integer),
  _Field('coilPauseProject', 'pauseProject coil', _Kind.integer),
  _Field('coilClearWarning', 'clearWarning coil', _Kind.integer),
  _Field('statusCoilBase', 'Status coils base', _Kind.integer),
];

const _timingFields = [
  _Field('heartbeatPeriodMs', 'Heartbeat period (ms)', _Kind.integer),
  _Field('pollPeriodMs', 'Status poll period (ms)', _Kind.integer),
  _Field('robotTimeoutMs', 'Robot watchdog timeout (ms)', _Kind.integer, 'Must equal TIMEOUT_MS in the robot script'),
  _Field('echoTimeoutMs', 'Watchdog echo timeout (ms)', _Kind.integer),
  _Field('startConfirmMs', 'Start confirmation (ms)', _Kind.integer),
  _Field('pulseMs', 'Command pulse width (ms)', _Kind.integer),
  _Field('settingsPin', 'Settings PIN', _Kind.text),
];

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.controller, required this.store});

  final HmiController controller;
  final ProfileStore store;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late Map<String, dynamic> _json;
  final Map<String, TextEditingController> _text = {};
  final List<(TextEditingController, TextEditingController)> _programs = [];

  @override
  void initState() {
    super.initState();
    _load(widget.controller.profile.toJson());
  }

  void _load(Map<String, dynamic> json) {
    _json = Map<String, dynamic>.from(json);
    for (final f in [..._connectionFields, ..._registerFields, ..._timingFields]) {
      final v = _json[f.key];
      (_text[f.key] ??= TextEditingController()).text = v?.toString() ?? '';
    }
    _programs.clear();
    for (final p in (_json['programs'] as List<dynamic>? ?? const [])) {
      final m = p as Map<String, dynamic>;
      _programs.add((
        TextEditingController(text: '${m['number']}'),
        TextEditingController(text: '${m['name']}'),
      ));
    }
  }

  @override
  void dispose() {
    for (final c in _text.values) {
      c.dispose();
    }
    for (final (a, b) in _programs) {
      a.dispose();
      b.dispose();
    }
    super.dispose();
  }

  /// Collects form values into a profile; returns null and shows errors if invalid.
  RobotProfile? _collect() {
    final json = Map<String, dynamic>.from(_json);
    final errors = <String>[];
    for (final f in [..._connectionFields, ..._registerFields, ..._timingFields]) {
      final s = _text[f.key]!.text.trim();
      switch (f.kind) {
        case _Kind.text:
          json[f.key] = s;
        case _Kind.integer:
          final v = int.tryParse(s);
          if (v == null) errors.add('${f.label}: not a number');
          json[f.key] = v;
        case _Kind.optionalInt:
          if (s.isEmpty) {
            json[f.key] = null;
          } else {
            final v = int.tryParse(s);
            if (v == null) errors.add('${f.label}: not a number');
            json[f.key] = v;
          }
      }
    }
    final programs = <Map<String, dynamic>>[];
    for (final (numberCtrl, nameCtrl) in _programs) {
      final n = int.tryParse(numberCtrl.text.trim());
      if (n == null || nameCtrl.text.trim().isEmpty) {
        errors.add('Program table: every row needs a number and a name');
        continue;
      }
      programs.add({'number': n, 'name': nameCtrl.text.trim()});
    }
    json['programs'] = programs;
    if (errors.isEmpty) {
      final profile = RobotProfile.fromJson(json);
      errors.addAll(profile.validate());
      if (errors.isEmpty) return profile;
    }
    _showErrors(errors);
    return null;
  }

  void _showErrors(List<String> errors) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Please fix'),
        content: Text(errors.join('\n')),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
      ),
    );
  }

  Future<void> _save() async {
    final profile = _collect();
    if (profile == null) return;
    await widget.store.save(profile);
    await widget.controller.applyProfile(profile);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved and applied')));
      Navigator.pop(context);
    }
  }

  Future<void> _editJson() async {
    final current = _collect();
    if (current == null) return;
    final ctrl = TextEditingController(text: const JsonEncoder.withIndent('  ').convert(current.toJson()));
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Profile JSON (import / export)'),
        content: SizedBox(
          width: 700,
          height: 500,
          child: TextField(
            controller: ctrl,
            maxLines: null,
            expands: true,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Clipboard.setData(ClipboardData(text: ctrl.text)),
            child: const Text('Copy'),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Apply to form')),
        ],
      ),
    );
    if (result == null) return;
    try {
      final parsed = RobotProfile.fromJson(jsonDecode(result) as Map<String, dynamic>);
      setState(() => _load(parsed.toJson()));
    } on Object catch (e) {
      _showErrors(['Invalid JSON: $e']);
    }
  }

  Widget _section(String title, List<_Field> fields) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Wrap(spacing: 16, runSpacing: 12, children: [
            for (final f in fields)
              SizedBox(
                width: 300,
                child: TextField(
                  controller: _text[f.key],
                  obscureText: f.key == 'settingsPin',
                  keyboardType: f.kind == _Kind.text ? TextInputType.text : TextInputType.number,
                  decoration: InputDecoration(labelText: f.label, helperText: f.help, border: const OutlineInputBorder()),
                ),
              ),
          ]),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: [
          TextButton.icon(onPressed: _editJson, icon: const Icon(Icons.data_object), label: const Text('JSON')),
          const SizedBox(width: 8),
          FilledButton.icon(onPressed: _save, icon: const Icon(Icons.save), label: const Text('Save & apply')),
          const SizedBox(width: 12),
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(spacing: 24, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              const Text('Controller', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              DropdownButton<String>(
                value: _json['generation'] as String? ?? 'gen2',
                items: const [
                  DropdownMenuItem(value: 'gen1', child: Text('Codroid Gen1')),
                  DropdownMenuItem(value: 'gen2', child: Text('Codroid Gen2')),
                ],
                onChanged: (v) => setState(() => _json['generation'] = v),
              ),
              _switch('DInt high word first', 'dintHighWordFirst'),
              _switch('Resume via startProject coil', 'resumeViaStartCoil'),
            ]),
          ),
        ),
        _section('Connection', _connectionFields),
        _programTable(),
        _section('Registers (confirm on Configuration > Communication > Register)', _registerFields),
        _section('Timing & security', _timingFields),
        _watchdogTest(c),
      ]),
    );
  }

  Widget _switch(String label, String key) => Row(mainAxisSize: MainAxisSize.min, children: [
        Text(label),
        Switch(value: _json[key] as bool? ?? false, onChanged: (v) => setState(() => _json[key] = v)),
      ]);

  Widget _programTable() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Text('Programs (Codroid Project Mapping)', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const Spacer(),
            TextButton.icon(
              onPressed: () => setState(() {
                final next = _programs.length + 1;
                _programs.add((TextEditingController(text: '$next'), TextEditingController()));
              }),
              icon: const Icon(Icons.add),
              label: const Text('Add'),
            ),
          ]),
          for (var i = 0; i < _programs.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                SizedBox(
                  width: 110,
                  child: TextField(
                    controller: _programs[i].$1,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Number', border: OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _programs[i].$2,
                    decoration: const InputDecoration(labelText: 'Name', border: OutlineInputBorder()),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => setState(() => _programs.removeAt(i)),
                ),
              ]),
            ),
        ]),
      ),
    );
  }

  Widget _watchdogTest(HmiController c) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Commissioning: watchdog test', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            const Text('Start a program from the tablet first. The test pauses the heartbeat; '
                'the robot must stop within the watchdog timeout. Run it for every program.'),
            const SizedBox(height: 12),
            Row(children: [
              FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: kAmber, foregroundColor: Colors.black),
                onPressed: c.watchdogTestActive ? null : c.runWatchdogTest,
                icon: const Icon(Icons.timer_off),
                label: const Text('Run watchdog test'),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  c.watchdogTestResult ?? '',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: (c.watchdogTestResult ?? '').startsWith('PASS')
                        ? kGreen
                        : (c.watchdogTestResult ?? '').startsWith('FAIL')
                            ? kRed
                            : null,
                  ),
                ),
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}

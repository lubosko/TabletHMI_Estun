import 'package:flutter/material.dart';

import '../state/supervision.dart';

const kGreen = Color(0xFF2E7D32);
const kAmber = Color(0xFFF9A825);
const kRed = Color(0xFFC62828);
const kGrey = Color(0xFF616161);

class LinkChip extends StatelessWidget {
  const LinkChip({super.key, required this.label, required this.state});

  final String label;
  final LinkState state;

  @override
  Widget build(BuildContext context) {
    final (color, text) = switch (state) {
      LinkState.connected => (kGreen, 'OK'),
      LinkState.degraded => (kAmber, 'SLOW'),
      LinkState.lost => (kRed, 'LOST'),
      LinkState.disconnected => (kGrey, 'OFF'),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Chip(
        avatar: CircleAvatar(backgroundColor: color, radius: 7),
        label: Text('$label $text', style: const TextStyle(fontWeight: FontWeight.w600)),
      ),
    );
  }
}

/// Large touch button used for START / STOP / PAUSE / RESUME.
class BigButton extends StatelessWidget {
  const BigButton({
    super.key,
    required this.label,
    required this.icon,
    required this.color,
    required this.onPressed,
    this.height = 96,
  });

  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback? onPressed;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: color,
          disabledBackgroundColor: color.withValues(alpha: 0.25),
          foregroundColor: Colors.white,
          disabledForegroundColor: Colors.white38,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          textStyle: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, letterSpacing: 1.5),
        ),
        onPressed: onPressed,
        icon: Icon(icon, size: 40),
        label: Text(label),
      ),
    );
  }
}

class HmiBanner extends StatelessWidget {
  const HmiBanner({super.key, required this.color, required this.icon, required this.text, this.action});

  final Color color;
  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(children: [
          Icon(icon, color: Colors.white, size: 32),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text,
                style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
          ),
          if (action != null) action!,
        ]),
      ),
    );
  }
}

class StatusRow extends StatelessWidget {
  const StatusRow({super.key, required this.label, required this.value, this.color});

  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        SizedBox(width: 150, child: Text(label, style: const TextStyle(fontSize: 16, color: Colors.white70))),
        Expanded(
          child: Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: color)),
        ),
      ]),
    );
  }
}

Future<bool> askPin(BuildContext context, String pin) async {
  final ctrl = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Settings PIN'),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        obscureText: true,
        keyboardType: TextInputType.number,
        onSubmitted: (_) => Navigator.pop(ctx, ctrl.text == pin),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text == pin), child: const Text('OK')),
      ],
    ),
  );
  return ok ?? false;
}

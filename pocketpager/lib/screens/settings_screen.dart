import 'package:flutter/material.dart';
import '../services/settings_service.dart';

class SettingsScreen extends StatelessWidget {
  final SettingsService    settings;
  final int                currentFreqHz;
  final void Function(int) onFreqSelected;

  const SettingsScreen({
    super.key,
    required this.settings,
    required this.currentFreqHz,
    required this.onFreqSelected,
  });

  @override
  Widget build(BuildContext ctx) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: settings,
        builder: (ctx, _) => ListView(children: [
          // ── Frequency Presets ───────────────────────────────────────
          const _SectionHeader('Frequency Presets'),
          ...settings.presets.asMap().entries.map((kv) {
            final i      = kv.key;
            final p      = kv.value;
            final active = p.freqHz == currentFreqHz;
            return ListTile(
              leading: Icon(Icons.radio,
                  color: active ? Colors.teal : Colors.grey),
              title: Text(p.label),
              subtitle:
                  Text('${(p.freqHz / 1e6).toStringAsFixed(4)} MHz'),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                if (active)
                  const Chip(
                      label: Text('Active',
                          style: TextStyle(fontSize: 11))),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 20),
                  onPressed: () => settings.removePreset(i),
                ),
              ]),
              onTap: () {
                onFreqSelected(p.freqHz);
                ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                    content: Text(
                        'Frequency set to ${(p.freqHz / 1e6).toStringAsFixed(4)} MHz'),
                    duration: const Duration(seconds: 1)));
              },
            );
          }),
          ListTile(
            leading: const Icon(Icons.add_circle_outline,
                color: Colors.teal),
            title: const Text('Add preset'),
            onTap: () => _addPresetDialog(ctx),
          ),
          const Divider(),

          // ── RTL-SDR Settings ────────────────────────────────────────
          const _SectionHeader('RTL-SDR'),
          SwitchListTile(
            secondary: const Icon(Icons.auto_mode),
            title: const Text('Automatic Gain Control'),
            subtitle: const Text(
                'Let the dongle decide gain (recommended)'),
            value: settings.agc,
            onChanged: settings.setAgc,
          ),
          if (!settings.agc) ...[
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
              child: Row(children: [
                const Icon(Icons.tune, size: 18, color: Colors.grey),
                const SizedBox(width: 8),
                const Text('Gain', style: TextStyle(fontSize: 14)),
                const Spacer(),
                Text('${settings.gain} dB',
                    style: const TextStyle(
                        fontSize: 14, color: Colors.teal)),
              ]),
            ),
            Slider(
              value: settings.gain.toDouble(),
              min: 0,
              max: 50,
              divisions: 50,
              label: '${settings.gain} dB',
              onChanged: (v) => settings.setGain(v.round()),
            ),
          ],
          const Divider(),

          // ── Messages ────────────────────────────────────────────────
          const _SectionHeader('Messages'),
          ListTile(
            leading: const Icon(Icons.storage),
            title: const Text('Message history limit'),
            subtitle:
                Text('Keep last ${settings.maxMessages} messages'),
            trailing: DropdownButton<int>(
              value: settings.maxMessages,
              underline: const SizedBox(),
              items: [100, 500, 1000, 5000]
                  .map((v) => DropdownMenuItem(
                      value: v, child: Text('$v')))
                  .toList(),
              onChanged: (v) {
                if (v != null) settings.setMaxMessages(v);
              },
            ),
          ),
          const Divider(),

          // ── About ───────────────────────────────────────────────────
          const _SectionHeader('About'),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('PocketPager'),
            subtitle: Text(
                'v1.0.0 · POCSAG/FLEX decoder via RTL-SDR OTG'),
          ),
          const ListTile(
            leading: Icon(Icons.code),
            title: Text('github.com/SarahRoseLives/PocketPager'),
            subtitle: Text('GPL-2.0 License'),
          ),
        ]),
      ),
    );
  }

  void _addPresetDialog(BuildContext ctx) {
    final labelCtrl = TextEditingController();
    final freqCtrl  = TextEditingController(
        text: (currentFreqHz / 1e6).toStringAsFixed(4));
    showDialog(
      context: ctx,
      builder: (_) => AlertDialog(
        title: const Text('Add Frequency Preset'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: labelCtrl,
              decoration: const InputDecoration(
                  labelText: 'Label (e.g. POCSAG 439.9875)'),
              autofocus: true),
          TextField(
              controller: freqCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: 'Frequency (MHz)', suffixText: 'MHz')),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final mhz = double.tryParse(freqCtrl.text.trim());
              if (mhz == null || labelCtrl.text.trim().isEmpty) return;
              settings.addPreset(FrequencyPreset(
                  label: labelCtrl.text.trim(),
                  freqHz: (mhz * 1e6).round()));
              Navigator.pop(ctx);
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String text;

  const _SectionHeader(this.text);

  @override
  Widget build(BuildContext ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
        child: Text(text,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Theme.of(ctx).colorScheme.primary,
                letterSpacing: 1.2)),
      );
}

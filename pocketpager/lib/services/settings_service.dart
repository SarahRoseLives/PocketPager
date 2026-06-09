import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FrequencyPreset {
  String label;
  int freqHz;

  FrequencyPreset({required this.label, required this.freqHz});

  Map<String, dynamic> toJson() => {'label': label, 'freqHz': freqHz};

  factory FrequencyPreset.fromJson(Map<String, dynamic> j) =>
      FrequencyPreset(label: j['label'] as String, freqHz: j['freqHz'] as int);
}

class SettingsService extends ChangeNotifier {
  static const _keyPresets     = 'pocketpager_presets';
  static const _keyGain        = 'pocketpager_gain';
  static const _keyAgc         = 'pocketpager_agc';
  static const _keyMaxMessages = 'pocketpager_maxmsg';

  List<FrequencyPreset> _presets = [
    FrequencyPreset(label: 'POCSAG 439.9875', freqHz: 439987500),
    FrequencyPreset(label: 'POCSAG 152.240',  freqHz: 152240000),
    FrequencyPreset(label: 'FLEX 931.8125',   freqHz: 931812500),
  ];
  int  _gain        = 30;
  bool _agc         = false;
  int  _maxMessages = 1000;

  List<FrequencyPreset> get presets     => List.unmodifiable(_presets);
  int                   get gain        => _gain;
  bool                  get agc         => _agc;
  int                   get maxMessages => _maxMessages;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _gain        = prefs.getInt(_keyGain) ?? 30;
    _agc         = prefs.getBool(_keyAgc) ?? false;
    _maxMessages = prefs.getInt(_keyMaxMessages) ?? 1000;
    final raw    = prefs.getStringList(_keyPresets);
    if (raw != null) {
      _presets = raw.map((s) {
        try {
          return FrequencyPreset.fromJson(
              Map<String, dynamic>.from(jsonDecode(s) as Map));
        } catch (_) {
          return null;
        }
      }).whereType<FrequencyPreset>().toList();
    }
    notifyListeners();
  }

  Future<void> setGain(int v) async {
    _gain = v;
    notifyListeners();
    (await SharedPreferences.getInstance()).setInt(_keyGain, v);
  }

  Future<void> setAgc(bool v) async {
    _agc = v;
    notifyListeners();
    (await SharedPreferences.getInstance()).setBool(_keyAgc, v);
  }

  Future<void> setMaxMessages(int v) async {
    _maxMessages = v;
    notifyListeners();
    (await SharedPreferences.getInstance()).setInt(_keyMaxMessages, v);
  }

  Future<void> addPreset(FrequencyPreset p) async {
    _presets.add(p);
    notifyListeners();
    await _savePresets();
  }

  Future<void> removePreset(int index) async {
    _presets.removeAt(index);
    notifyListeners();
    await _savePresets();
  }

  Future<void> _savePresets() async {
    (await SharedPreferences.getInstance()).setStringList(
        _keyPresets, _presets.map((p) => jsonEncode(p.toJson())).toList());
  }
}

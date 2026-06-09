import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/address_entry.dart';

class AddressBookService extends ChangeNotifier {
  static const _key = 'pocketpager_address_book';
  final List<AddressEntry> _entries = [];
  List<AddressEntry> get entries => List.unmodifiable(_entries);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _entries.clear();
    for (final s in prefs.getStringList(_key) ?? []) {
      try {
        _entries.add(AddressEntry.fromJson(
            Map<String, dynamic>.from(jsonDecode(s) as Map)));
      } catch (_) {}
    }
    notifyListeners();
  }

  AddressEntry? entryFor(int address) {
    for (final e in _entries) {
      if (e.address == address) return e;
    }
    return null;
  }

  Future<void> add(AddressEntry e) async {
    _entries.add(e);
    notifyListeners();
    await _persist();
  }

  Future<void> update(int address, String name, String notes) async {
    for (final e in _entries) {
      if (e.address == address) {
        e.name = name;
        e.notes = notes;
        break;
      }
    }
    notifyListeners();
    await _persist();
  }

  Future<void> remove(int address) async {
    _entries.removeWhere((e) => e.address == address);
    notifyListeners();
    await _persist();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        _key, _entries.map((e) => jsonEncode(e.toJson())).toList());
  }
}

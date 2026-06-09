import 'package:flutter/material.dart';
import '../services/address_book_service.dart';
import '../models/address_entry.dart';

class AddressesScreen extends StatelessWidget {
  final AddressBookService addressBook;

  const AddressesScreen({super.key, required this.addressBook});

  @override
  Widget build(BuildContext ctx) {
    return Scaffold(
      appBar: AppBar(title: const Text('Address Book')),
      floatingActionButton: FloatingActionButton(
        tooltip: 'Add address',
        onPressed: () => _showAddDialog(ctx),
        child: const Icon(Icons.add),
      ),
      body: ListenableBuilder(
        listenable: addressBook,
        builder: (ctx, _) {
          final entries = addressBook.entries;
          if (entries.isEmpty) {
            return const Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.contacts_outlined, size: 64, color: Colors.grey),
                SizedBox(height: 12),
                Text('No saved addresses',
                    style: TextStyle(color: Colors.grey)),
                SizedBox(height: 4),
                Text('Tap + or use "Save Address" from a message',
                    style: TextStyle(color: Colors.grey, fontSize: 12)),
              ]),
            );
          }
          return ListView.separated(
            itemCount: entries.length,
            separatorBuilder: (_, i) =>
                const Divider(height: 1, indent: 70),
            itemBuilder: (ctx, i) {
              final e = entries[i];
              return Dismissible(
                key: ValueKey(e.address),
                direction: DismissDirection.endToStart,
                background: Container(
                  alignment: Alignment.centerRight,
                  color: Colors.red,
                  padding: const EdgeInsets.only(right: 16),
                  child: const Icon(Icons.delete, color: Colors.white),
                ),
                onDismissed: (_) => addressBook.remove(e.address),
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: Colors.teal.shade800,
                    child: Text(
                        e.name.isNotEmpty
                            ? e.name[0].toUpperCase()
                            : '?',
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold)),
                  ),
                  title: Text(e.name,
                      style:
                          const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text(
                      '${e.address}${e.notes.isNotEmpty ? ' · ${e.notes}' : ''}',
                      style: const TextStyle(fontSize: 12)),
                  trailing: const Icon(Icons.chevron_right,
                      color: Colors.grey),
                  onTap: () => _showEditDialog(ctx, e),
                ),
              );
            },
          );
        },
      ),
    );
  }

  void _showAddDialog(BuildContext ctx) {
    final addrCtrl  = TextEditingController();
    final nameCtrl  = TextEditingController();
    final notesCtrl = TextEditingController();
    showDialog(
      context: ctx,
      builder: (_) => AlertDialog(
        title: const Text('Add Address'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: addrCtrl,
              keyboardType: TextInputType.number,
              decoration:
                  const InputDecoration(labelText: 'Address (number)'),
              autofocus: true),
          TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(labelText: 'Name')),
          TextField(
              controller: notesCtrl,
              decoration:
                  const InputDecoration(labelText: 'Notes (optional)')),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              final addr = int.tryParse(addrCtrl.text.trim());
              if (addr == null || nameCtrl.text.trim().isEmpty) return;
              addressBook.add(AddressEntry(
                  address: addr,
                  name: nameCtrl.text.trim(),
                  notes: notesCtrl.text.trim()));
              Navigator.pop(ctx);
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  void _showEditDialog(BuildContext ctx, AddressEntry entry) {
    final nameCtrl  = TextEditingController(text: entry.name);
    final notesCtrl = TextEditingController(text: entry.notes);
    showDialog(
      context: ctx,
      builder: (_) => AlertDialog(
        title: Text('Edit ${entry.address}'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(labelText: 'Name'),
              autofocus: true),
          TextField(
              controller: notesCtrl,
              decoration: const InputDecoration(labelText: 'Notes')),
        ]),
        actionsAlignment: MainAxisAlignment.spaceBetween,
        actions: [
          TextButton(
            onPressed: () {
              addressBook.remove(entry.address);
              Navigator.pop(ctx);
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
          Row(mainAxisSize: MainAxisSize.min, children: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: () {
                addressBook.update(entry.address, nameCtrl.text.trim(),
                    notesCtrl.text.trim());
                Navigator.pop(ctx);
              },
              child: const Text('Save'),
            ),
          ]),
        ],
      ),
    );
  }
}

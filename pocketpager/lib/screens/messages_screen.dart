import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../pager_ffi.dart';
import '../services/address_book_service.dart';
import '../models/address_entry.dart';

class MessagesScreen extends StatefulWidget {
  final List<PagerMessage> messages;
  final AddressBookService addressBook;
  final VoidCallback? onClear;

  const MessagesScreen({
    super.key,
    required this.messages,
    required this.addressBook,
    this.onClear,
  });

  @override
  State<MessagesScreen> createState() => _MessagesScreenState();
}

class _MessagesScreenState extends State<MessagesScreen> {
  static const _protocols = [
    'All',
    'POCSAG512',
    'POCSAG1200',
    'POCSAG2400',
    'FLEX',
    'FLEX_NEXT',
  ];

  String _selectedProtocol = 'All';
  String _searchQuery      = '';
  bool   _searchActive     = false;
  bool   _autoScroll       = true;

  final _searchCtrl = TextEditingController();
  final _scroll     = ScrollController();

  @override
  void dispose() {
    _searchCtrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Color _protoColor(String p) => switch (p) {
        'POCSAG512'  => Colors.orange,
        'POCSAG1200' => Colors.teal,
        'POCSAG2400' => Colors.cyan,
        'FLEX'       => Colors.purple,
        'FLEX_NEXT'  => Colors.deepPurple,
        _            => Colors.grey,
      };

  List<PagerMessage> get _filtered {
    return widget.messages.where((m) {
      if (_selectedProtocol != 'All' && m.protocol != _selectedProtocol) {
        return false;
      }
      if (_searchQuery.isNotEmpty) {
        final q = _searchQuery.toLowerCase();
        if (!m.message.toLowerCase().contains(q) &&
            !m.address.toString().contains(q)) {
          return false;
        }
      }
      return true;
    }).toList();
  }

  int _countFor(String proto) => proto == 'All'
      ? widget.messages.length
      : widget.messages.where((m) => m.protocol == proto).length;

  void _showDetail(BuildContext ctx, PagerMessage msg) {
    final entry = widget.addressBook.entryFor(msg.address);
    final fmt   = DateFormat('yyyy-MM-dd HH:mm:ss');
    showModalBottomSheet(
      context: ctx,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.5,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        builder: (_, ctrl) => Container(
          decoration: BoxDecoration(
            color: Theme.of(ctx).colorScheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: ListView(
            controller: ctrl,
            padding: const EdgeInsets.all(20),
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade600,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(children: [
                _ProtoBadge(proto: msg.protocol, color: _protoColor(msg.protocol)),
                const Spacer(),
                Text(
                  fmt.format(msg.timestamp.toLocal()),
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ]),
              const SizedBox(height: 16),
              if (entry != null) ...[
                _DetailRow(Icons.person, 'Contact', entry.name,
                    valueStyle: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.teal)),
                if (entry.notes.isNotEmpty)
                  _DetailRow(Icons.notes, 'Notes', entry.notes),
                const Divider(),
              ],
              _DetailRow(Icons.tag, 'Address', msg.address.toString()),
              _DetailRow(Icons.settings_input_component, 'Function',
                  msg.function.toString()),
              const SizedBox(height: 12),
              const Text('Message',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 4),
              SelectableText(
                msg.message.isEmpty ? '(numeric / no alpha)' : msg.message,
                style: TextStyle(
                    fontSize: 15,
                    color: msg.message.isEmpty ? Colors.grey : null),
              ),
              const SizedBox(height: 20),
              Wrap(spacing: 8, children: [
                FilledButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(
                        text:
                            '${msg.protocol} Addr:${msg.address} Fn:${msg.function}\n${msg.message}'));
                    ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
                        content: Text('Copied'),
                        duration: Duration(seconds: 1)));
                  },
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('Copy'),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext ctx) {
    final filtered = _filtered;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: _searchActive ? 0 : null,
        title: _searchActive
            ? TextField(
                controller: _searchCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                    hintText: 'Search address or message…',
                    border: InputBorder.none,
                    hintStyle: TextStyle(color: Colors.grey)),
                style: const TextStyle(fontSize: 16),
                onChanged: (v) => setState(() => _searchQuery = v),
              )
            : const Text('Messages'),
        actions: [
          IconButton(
            icon: Icon(_searchActive ? Icons.close : Icons.search),
            tooltip: _searchActive ? 'Cancel' : 'Search',
            onPressed: () => setState(() {
              _searchActive = !_searchActive;
              if (!_searchActive) {
                _searchQuery = '';
                _searchCtrl.clear();
              }
            }),
          ),
          IconButton(
            icon: Icon(
                _autoScroll ? Icons.vertical_align_bottom : Icons.pause),
            tooltip: _autoScroll ? 'Auto-scroll on' : 'Auto-scroll off',
            onPressed: () => setState(() => _autoScroll = !_autoScroll),
          ),
          if (widget.messages.isNotEmpty && widget.onClear != null)
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              tooltip: 'Clear',
              onPressed: widget.onClear,
            ),
        ],
      ),
      body: Column(children: [
        // Protocol filter chips
        SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            children: _protocols.map((proto) {
              final count    = _countFor(proto);
              final selected = proto == _selectedProtocol;
              return Padding(
                padding: const EdgeInsets.only(right: 6),
                child: FilterChip(
                  selected: selected,
                  label: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(proto == 'All'
                        ? 'All'
                        : proto.replaceAll('POCSAG', 'POC')),
                    if (count > 0) ...[
                      const SizedBox(width: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: selected
                              ? Theme.of(ctx)
                                  .colorScheme
                                  .onSecondaryContainer
                                  .withValues(alpha: 0.7)
                              : (proto == 'All'
                                  ? Colors.grey.shade700
                                  : _protoColor(proto).withValues(alpha: 0.8)),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text('$count',
                            style: const TextStyle(
                                fontSize: 10,
                                color: Colors.white,
                                fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ]),
                  onSelected: (_) =>
                      setState(() => _selectedProtocol = proto),
                ),
              );
            }).toList(),
          ),
        ),
        const Divider(height: 1),
        // Message list
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                    Icon(Icons.inbox_outlined,
                        size: 64, color: Colors.grey.shade700),
                    const SizedBox(height: 12),
                    Text(
                        widget.messages.isEmpty
                            ? 'No messages yet'
                            : 'No matches',
                        style:
                            TextStyle(color: Colors.grey.shade600)),
                  ]))
              : ListView.builder(
                  controller: _scroll,
                  reverse: true,
                  itemCount: filtered.length,
                  itemBuilder: (_, i) {
                    final msg   = filtered[i];
                    final entry =
                        widget.addressBook.entryFor(msg.address);
                    return _MessageTile(
                      msg: msg,
                      entry: entry,
                      protoColor: _protoColor(msg.protocol),
                      onTap: () => _showDetail(ctx, msg),
                    );
                  },
                ),
        ),
      ]),
    );
  }
}

class _ProtoBadge extends StatelessWidget {
  final String proto;
  final Color  color;

  const _ProtoBadge({required this.proto, required this.color});

  @override
  Widget build(BuildContext ctx) => Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            border: Border.all(color: color),
            borderRadius: BorderRadius.circular(6)),
        child: Text(proto,
            style: TextStyle(
                fontSize: 11,
                color: color,
                fontWeight: FontWeight.bold)),
      );
}

class _DetailRow extends StatelessWidget {
  final IconData   icon;
  final String     label;
  final String     value;
  final TextStyle? valueStyle;

  const _DetailRow(this.icon, this.label, this.value, {this.valueStyle});

  @override
  Widget build(BuildContext ctx) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          Icon(icon, size: 16, color: Colors.grey),
          const SizedBox(width: 10),
          Text('$label  ',
              style: const TextStyle(fontSize: 12, color: Colors.grey)),
          Expanded(
              child: Text(value,
                  style: valueStyle ??
                      const TextStyle(fontSize: 14))),
        ]),
      );
}

class _MessageTile extends StatelessWidget {
  final PagerMessage  msg;
  final AddressEntry? entry;
  final Color         protoColor;
  final VoidCallback  onTap;

  static final _timeFmt = DateFormat('HH:mm:ss');

  const _MessageTile({
    required this.msg,
    required this.entry,
    required this.protoColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext ctx) {
    final hasContact = entry != null;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                  width: 72,
                  child: _ProtoBadge(
                      proto: msg.protocol.replaceAll('POCSAG', 'POC'),
                      color: protoColor)),
              const SizedBox(width: 10),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Row(children: [
                      if (hasContact)
                        Text(entry!.name,
                            style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                                color: protoColor))
                      else
                        Text('${msg.address}',
                            style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13)),
                      Text('  Fn:${msg.function}',
                          style: const TextStyle(
                              fontSize: 11, color: Colors.grey)),
                      const Spacer(),
                      Text(
                          _timeFmt.format(msg.timestamp.toLocal()),
                          style: const TextStyle(
                              fontSize: 11, color: Colors.grey)),
                    ]),
                    if (msg.message.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(msg.message,
                          style: const TextStyle(fontSize: 13),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis),
                    ],
                  ])),
            ]),
      ),
    );
  }
}

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'pager_ffi.dart';
import 'services/address_book_service.dart';
import 'services/settings_service.dart';
import 'screens/messages_screen.dart';
import 'screens/settings_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final addressBook = AddressBookService();
  final settings    = SettingsService();
  await Future.wait([addressBook.load(), settings.load()]);
  runApp(PocketPagerApp(addressBook: addressBook, settings: settings));
}

class PocketPagerApp extends StatelessWidget {
  final AddressBookService addressBook;
  final SettingsService    settings;

  const PocketPagerApp(
      {super.key, required this.addressBook, required this.settings});

  @override
  Widget build(BuildContext ctx) => MaterialApp(
        title: 'PocketPager',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true).copyWith(
          colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.teal, brightness: Brightness.dark),
        ),
        home: HomePage(addressBook: addressBook, settings: settings),
      );
}

class HomePage extends StatefulWidget {
  final AddressBookService addressBook;
  final SettingsService    settings;

  const HomePage(
      {super.key, required this.addressBook, required this.settings});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const _usbChannel =
      MethodChannel('com.example.pocketpager/usb');

  final PagerDecoder       _decoder        = PagerDecoder();
  StreamSubscription<PagerMessage>? _sub;
  final List<PagerMessage> _messages       = [];
  final List<DateTime>     _msgTimestamps  = [];

  bool   _running    = false;
  String _status     = 'No RTL-SDR connected';
  int    _freqHz     = 439987500;
  int    _tabIndex   = 0;
  int    _newMsgCount = 0;

  List<Map<String, dynamic>> _devices = [];

  int get _msgRate {
    final cutoff = DateTime.now().subtract(const Duration(seconds: 60));
    return _msgTimestamps.where((t) => t.isAfter(cutoff)).length;
  }

  @override
  void initState() {
    super.initState();
    _sub = _decoder.messageStream.listen(_onMessage);
    _refreshDevices();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _decoder.dispose();
    super.dispose();
  }

  void _onMessage(PagerMessage msg) {
    setState(() {
      _messages.insert(0, msg);
      final now = DateTime.now();
      _msgTimestamps.add(now);
      final cutoff = now.subtract(const Duration(seconds: 60));
      _msgTimestamps.removeWhere((t) => t.isBefore(cutoff));
      while (_messages.length > widget.settings.maxMessages) {
        _messages.removeLast();
      }
      if (_tabIndex != 0) _newMsgCount++;
    });
  }

  Future<void> _refreshDevices() async {
    try {
      final raw =
          await _usbChannel.invokeMethod<List<dynamic>>('listDevices');
      setState(() {
        _devices = (raw ?? [])
            .whereType<Map>()
            .map((m) => Map<String, dynamic>.from(m))
            .toList();
        if (_devices.isEmpty) _status = 'No RTL-SDR detected';
      });
    } on PlatformException catch (e) {
      setState(() => _status = 'USB error: ${e.message}');
    }
  }

  Future<void> _openAndStart(Map<String, dynamic> device) async {
    try {
      final name = device['name']?.toString() ?? '';
      if (name.isEmpty) {
        setState(() => _status = 'Error: device has no path');
        return;
      }
      final raw = await _usbChannel.invokeMapMethod<String, dynamic>(
          'openDevice', {'name': name});
      if (raw == null) return;
      final rc = _decoder.open(
          raw['fd'] as int, raw['path'] as String, _freqHz);
      if (rc != 0) {
        setState(() => _status = 'pager_open failed ($rc)');
        return;
      }
      final rc2 = _decoder.start();
      if (rc2 != 0) {
        setState(() => _status = 'pager_start failed ($rc2)');
        return;
      }
      setState(() {
        _running = true;
        _status =
            'Decoding ${(_freqHz / 1e6).toStringAsFixed(4)} MHz';
      });
    } on PlatformException catch (e) {
      setState(() => _status = 'Error: ${e.message}');
    }
  }

  Future<void> _stop() async {
    _decoder.stop();
    await _usbChannel.invokeMethod<void>('closeDevice');
    setState(() {
      _running = false;
      _status  = 'Stopped';
    });
  }

  Widget _buildConnectionPanel() {
    final freqCtrl = TextEditingController(
        text: (_freqHz / 1e6).toStringAsFixed(4));
    return Container(
      color: Theme.of(context).colorScheme.surface,
      padding: const EdgeInsets.all(16),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Expanded(
                child: TextField(
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  controller: freqCtrl,
                  decoration: InputDecoration(
                    labelText: 'Frequency (MHz)',
                    border: const OutlineInputBorder(),
                    suffixText: 'MHz',
                    isDense: true,
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.star_outline, size: 18),
                      tooltip: 'Presets',
                      onPressed: _showPresetPicker,
                    ),
                  ),
                  onSubmitted: (v) {
                    final mhz = double.tryParse(v);
                    if (mhz != null) {
                      setState(() => _freqHz = (mhz * 1e6).round());
                    }
                  },
                ),
              ),
            ]),
            const SizedBox(height: 12),
            if (_devices.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  Icon(Icons.usb_off,
                      color: Colors.grey.shade600, size: 20),
                  const SizedBox(width: 8),
                  Text('No RTL-SDR detected — plug in via OTG',
                      style: TextStyle(
                          color: Colors.grey.shade600, fontSize: 13)),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: _refreshDevices,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('Scan'),
                  ),
                ]),
              )
            else
              ..._devices.map((d) => Card(
                    margin: const EdgeInsets.only(bottom: 4),
                    child: ListTile(
                      dense: true,
                      leading:
                          const Icon(Icons.usb, color: Colors.teal),
                      title: Text(d['name'] as String,
                          style: const TextStyle(fontSize: 13)),
                      subtitle: Text(
                          'VID:0x${(d['vid'] as int).toRadixString(16).toUpperCase()}  '
                          'PID:0x${(d['pid'] as int).toRadixString(16).toUpperCase()}',
                          style: const TextStyle(fontSize: 11)),
                      trailing: FilledButton(
                        onPressed: () => _openAndStart(d),
                        child: const Text('Connect'),
                      ),
                    ),
                  )),
          ]),
    );
  }

  void _showPresetPicker() {
    showModalBottomSheet(
      context: context,
      builder: (_) => Column(mainAxisSize: MainAxisSize.min, children: [
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('Frequency Presets',
              style: TextStyle(
                  fontWeight: FontWeight.bold, fontSize: 16)),
        ),
        ...widget.settings.presets.map((p) => ListTile(
              leading: const Icon(Icons.radio, color: Colors.teal),
              title: Text(p.label),
              subtitle:
                  Text('${(p.freqHz / 1e6).toStringAsFixed(4)} MHz'),
              trailing: p.freqHz == _freqHz
                  ? const Icon(Icons.check, color: Colors.teal)
                  : null,
              onTap: () {
                setState(() => _freqHz = p.freqHz);
                Navigator.pop(context);
              },
            )),
        if (widget.settings.presets.isEmpty)
          const Padding(
              padding: EdgeInsets.all(16),
              child: Text('No presets — add some in Settings',
                  style: TextStyle(color: Colors.grey))),
        const SizedBox(height: 16),
      ]),
    );
  }

  Widget _buildStatusBar() {
    return Container(
                  color: Colors.teal.shade900.withValues(alpha: 0.8),
      padding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(children: [
        Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
                color: _running ? Colors.greenAccent : Colors.grey,
                shape: BoxShape.circle)),
        const SizedBox(width: 8),
        Text(
            _running
                ? '${(_freqHz / 1e6).toStringAsFixed(4)} MHz'
                : _status,
            style: const TextStyle(fontSize: 13)),
        const Spacer(),
        if (_running) ...[
          Text('$_msgRate /min',
              style: const TextStyle(
                  fontSize: 11, color: Colors.grey)),
          const SizedBox(width: 12),
          Text('${_messages.length} msgs',
              style: const TextStyle(
                  fontSize: 11, color: Colors.grey)),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: _stop,
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 10, vertical: 3),
              decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.2),
                  border:
                      Border.all(color: Colors.red.shade400),
                  borderRadius: BorderRadius.circular(12)),
              child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.stop,
                        size: 12, color: Colors.redAccent),
                    SizedBox(width: 4),
                    Text('Stop',
                        style: TextStyle(
                            fontSize: 11,
                            color: Colors.redAccent)),
                  ]),
            ),
          ),
        ],
      ]),
    );
  }

  @override
  Widget build(BuildContext ctx) {
    return Scaffold(
      body: SafeArea(
        child: IndexedStack(
        index: _tabIndex,
        children: [
          // ── Messages tab ──────────────────────────────────────────
          Column(children: [
            _buildStatusBar(),
            if (!_running) _buildConnectionPanel(),
            const Divider(height: 1),
            Expanded(
              child: ListenableBuilder(
                listenable: widget.addressBook,
                builder: (ctx, _) => MessagesScreen(
                  messages: List.unmodifiable(_messages),
                  addressBook: widget.addressBook,
                  onClear: () => setState(() {
                    _messages.clear();
                    _msgTimestamps.clear();
                    _newMsgCount = 0;
                  }),
                ),
              ),
            ),
          ]),
          // ── Settings tab ──────────────────────────────────────────
          SettingsScreen(
            settings: widget.settings,
            currentFreqHz: _freqHz,
            onFreqSelected: (f) => setState(() => _freqHz = f),
          ),
        ],
      ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tabIndex,
        onDestinationSelected: (i) => setState(() {
          _tabIndex = i;
          if (i == 0) _newMsgCount = 0;
        }),
        destinations: [
          NavigationDestination(
            icon: Badge(
              isLabelVisible: _newMsgCount > 0,
              label: Text(_newMsgCount > 99 ? '99+' : '$_newMsgCount'),
              child: const Icon(Icons.message_outlined),
            ),
            selectedIcon: const Icon(Icons.message),
            label: 'Messages',
          ),
          const NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}

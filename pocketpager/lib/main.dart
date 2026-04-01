import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'pager_ffi.dart';

void main() {
  runApp(const PocketPagerApp());
}

class PocketPagerApp extends StatelessWidget {
  const PocketPagerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PocketPager',
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal,
          brightness: Brightness.dark,
        ),
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const _usbChannel = MethodChannel('com.example.pocketpager/usb');
  static const _defaultFreq = 439987500;

  final PagerDecoder _decoder = PagerDecoder();
  StreamSubscription<PagerMessage>? _sub;

  final List<PagerMessage> _messages = [];
  final ScrollController   _scroll   = ScrollController();

  List<Map<String, dynamic>> _devices = [];
  bool   _running = false;
  String _status  = 'No RTL-SDR connected';
  int    _freqHz  = _defaultFreq;

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
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _refreshDevices() async {
    try {
      final raw = await _usbChannel.invokeMethod<List<dynamic>>('listDevices');
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
      debugPrint('PocketPager: _openAndStart device=$device name="$name"');
      if (name.isEmpty) { setState(() => _status = 'Error: device has no path'); return; }

      debugPrint('PocketPager: calling openDevice with name="$name"');
      final raw = await _usbChannel.invokeMapMethod<String, dynamic>(
          'openDevice', {'name': name});
      debugPrint('PocketPager: openDevice returned raw=$raw');
      if (raw == null) return;

      final rc = _decoder.open(raw['fd'] as int, raw['path'] as String, _freqHz);
      if (rc != 0) { setState(() => _status = 'pager_open failed ($rc)'); return; }

      final rc2 = _decoder.start();
      if (rc2 != 0) { setState(() => _status = 'pager_start failed ($rc2)'); return; }

      setState(() {
        _running = true;
        _status  = 'Decoding on ${(_freqHz / 1e6).toStringAsFixed(4)} MHz';
      });
    } on PlatformException catch (e) {
      setState(() => _status = 'Error: ${e.message}');
    }
  }

  Future<void> _stop() async {
    _decoder.stop();
    await _usbChannel.invokeMethod('closeDevice');
    setState(() { _running = false; _status = 'Stopped'; });
  }

  void _onMessage(PagerMessage msg) {
    setState(() {
      _messages.insert(0, msg);
      if (_messages.length > 500) _messages.removeLast();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('PocketPager'),
        actions: [
          if (!_running)
            IconButton(icon: const Icon(Icons.refresh),
                tooltip: 'Scan', onPressed: _refreshDevices),
          if (_running)
            IconButton(icon: const Icon(Icons.stop_circle, color: Colors.redAccent),
                tooltip: 'Stop', onPressed: _stop),
          IconButton(icon: const Icon(Icons.delete_sweep),
              tooltip: 'Clear', onPressed: () => setState(() => _messages.clear())),
        ],
      ),
      body: Column(children: [
        _StatusBar(status: _status),
        if (!_running)
          _DevicePanel(
            devices: _devices,
            freqHz: _freqHz,
            onFreqChanged: (f) => setState(() => _freqHz = f),
            onConnect: _openAndStart,
          ),
        const Divider(height: 1),
        Expanded(
          child: _messages.isEmpty
              ? const Center(child: Text('No messages yet',
                  style: TextStyle(color: Colors.grey)))
              : ListView.builder(
                  controller: _scroll,
                  itemCount: _messages.length,
                  itemBuilder: (ctx, i) => _MessageTile(msg: _messages[i]),
                ),
        ),
      ]),
    );
  }
}

class _StatusBar extends StatelessWidget {
  final String status;
  const _StatusBar({required this.status});
  @override
  Widget build(BuildContext context) => Container(
    color: Colors.teal.shade900,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    child: Row(children: [
      const Icon(Icons.settings_input_antenna, size: 16),
      const SizedBox(width: 8),
      Expanded(child: Text(status, style: const TextStyle(fontSize: 13))),
    ]),
  );
}

class _DevicePanel extends StatelessWidget {
  final List<Map<String, dynamic>> devices;
  final int    freqHz;
  final void Function(int) onFreqChanged;
  final void Function(Map<String, dynamic>) onConnect;
  const _DevicePanel({required this.devices, required this.freqHz,
      required this.onFreqChanged, required this.onConnect});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(12),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      TextField(
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        controller: TextEditingController(
            text: (freqHz / 1e6).toStringAsFixed(4)),
        decoration: const InputDecoration(
            labelText: 'Frequency (MHz)', border: OutlineInputBorder(),
            suffixText: 'MHz', isDense: true),
        onSubmitted: (v) {
          final mhz = double.tryParse(v);
          if (mhz != null) onFreqChanged((mhz * 1e6).round());
        },
      ),
      const SizedBox(height: 8),
      if (devices.isEmpty)
        const Text('No RTL-SDR found. Plug in via OTG.',
            style: TextStyle(color: Colors.grey))
      else
        ...devices.map((d) => Card(child: ListTile(
          leading: const Icon(Icons.usb),
          title: Text(d['name'] as String),
          subtitle: Text(
              'VID:0x${(d['vid'] as int).toRadixString(16).toUpperCase()}  '
              'PID:0x${(d['pid'] as int).toRadixString(16).toUpperCase()}'),
          trailing: ElevatedButton(
              onPressed: () => onConnect(d), child: const Text('Connect')),
        ))),
    ]),
  );
}

class _MessageTile extends StatelessWidget {
  final PagerMessage msg;
  const _MessageTile({required this.msg});
  static final _fmt = DateFormat('HH:mm:ss');

  Color _color(String p) => switch (p) {
    'POCSAG512'  => Colors.orange,
    'POCSAG1200' => Colors.teal,
    'POCSAG2400' => Colors.cyan,
    'FLEX'       => Colors.purple,
    'FLEX_NEXT'  => Colors.deepPurple,
    _            => Colors.grey,
  };

  @override
  Widget build(BuildContext context) {
    final local = msg.timestamp.toLocal();
    final c = _color(msg.protocol);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: c.withOpacity(0.15),
              border: Border.all(color: c),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(msg.protocol,
                style: TextStyle(fontSize: 10, color: c, fontWeight: FontWeight.bold)),
          ),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text('${msg.address}',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
              const SizedBox(width: 8),
              Text('Fn:${msg.function}',
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
              const Spacer(),
              Text(_fmt.format(local),
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
            ]),
            if (msg.message.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(msg.message, style: const TextStyle(fontSize: 13)),
              ),
          ])),
        ]),
      ),
    );
  }
}

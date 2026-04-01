// lib/pager_ffi.dart
//
// Dart FFI bindings for libpocketpager.so
//
// C API:
//   int32_t pager_open (int32_t fd, const char *path,
//                       uint32_t frequency_hz, int32_t gain_tenths_db)
//   int32_t pager_start(void (*cb)(int32_t proto, uint32_t addr,
//                                  int32_t func, char *msg, int64_t ts_ms))
//   void    pager_stop (void)
//   void    pager_free (void *ptr)

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

// ── Model ──────────────────────────────────────────────────────────────────

const List<String> kProtocolNames = [
  'POCSAG512',
  'POCSAG1200',
  'POCSAG2400',
  'FLEX',
  'FLEX_NEXT',
];

class PagerMessage {
  final String  protocol;
  final int     address;
  final int     function;
  final String  message;
  final DateTime timestamp;

  const PagerMessage({
    required this.protocol,
    required this.address,
    required this.function,
    required this.message,
    required this.timestamp,
  });
}

// ── Native type signatures ─────────────────────────────────────────────────

// void cb(int32_t proto, uint32_t addr, int32_t func, char *msg, int64_t ts)
typedef _PagerCbNative = Void Function(
    Int32 proto, Uint32 addr, Int32 func, Pointer<Utf8> msg, Int64 tsMs);

// int32_t pager_open(int32_t fd, const char *path, uint32_t freq, int32_t gain)
typedef _PagerOpenNative = Int32 Function(
    Int32 fd, Pointer<Utf8> path, Uint32 freq, Int32 gain);
typedef _PagerOpenDart   = int   Function(
    int  fd, Pointer<Utf8> path, int   freq, int  gain);

// int32_t pager_start(pager_cb_t cb)
typedef _PagerStartNative = Int32 Function(
    Pointer<NativeFunction<_PagerCbNative>> cb);
typedef _PagerStartDart   = int   Function(
    Pointer<NativeFunction<_PagerCbNative>> cb);

// void pager_stop(void)
typedef _PagerStopNative = Void Function();
typedef _PagerStopDart   = void Function();

// void pager_free(void *ptr)
typedef _PagerFreeNative = Void Function(Pointer<Void> ptr);
typedef _PagerFreeDart   = void Function(Pointer<Void> ptr);

// ── PagerDecoder ───────────────────────────────────────────────────────────

class PagerDecoder {
  static final DynamicLibrary _lib = Platform.isAndroid
      ? DynamicLibrary.open('libpocketpager.so')
      : DynamicLibrary.process();

  static final _pagerOpen  = _lib.lookupFunction<_PagerOpenNative,  _PagerOpenDart> ('pager_open');
  static final _pagerStart = _lib.lookupFunction<_PagerStartNative, _PagerStartDart>('pager_start');
  static final _pagerStop  = _lib.lookupFunction<_PagerStopNative,  _PagerStopDart> ('pager_stop');
  static final _pagerFree  = _lib.lookupFunction<_PagerFreeNative,  _PagerFreeDart> ('pager_free');

  final _controller = StreamController<PagerMessage>.broadcast();
  Stream<PagerMessage> get messageStream => _controller.stream;

  NativeCallable<_PagerCbNative>? _callable;
  bool _running = false;

  /// Open the RTL-SDR device.
  /// [fd]          – file descriptor from Kotlin openDevice()
  /// [path]        – USB device path  (e.g. /dev/bus/usb/001/002)
  /// [frequencyHz] – centre frequency in Hz (e.g. 439987500)
  /// [gainTenthsDb]– tuner gain in tenths of dB (0 = auto AGC)
  int open(int fd, String path, int frequencyHz, {int gainTenthsDb = 300}) {
    final pathPtr = path.toNativeUtf8();
    final result  = _pagerOpen(fd, pathPtr, frequencyHz, gainTenthsDb);
    calloc.free(pathPtr);
    return result;
  }

  /// Begin decoding. Decoded messages arrive on [messageStream].
  int start() {
    if (_running) return -1;

    // NativeCallable.listener() safely posts from any native thread.
    _callable = NativeCallable<_PagerCbNative>.listener(_onMessage);

    final result = _pagerStart(_callable!.nativeFunction);
    if (result == 0) {
      _running = true;
    } else {
      _callable!.close();
      _callable = null;
    }
    return result;
  }

  /// Stop decoding and release resources.
  void stop() {
    if (!_running) return;
    _pagerStop();
    _running = false;
    _callable?.close();
    _callable = null;
  }

  void dispose() {
    stop();
    _controller.close();
  }

  // ── Private callback (called from C decode thread) ─────────────────────

  void _onMessage(int proto, int addr, int func,
                  Pointer<Utf8> msgPtr, int tsMs) {
    if (_controller.isClosed) return;

    final message = msgPtr == nullptr ? '' : msgPtr.toDartString();

    // Free the C-malloc'd string immediately after copying.
    if (msgPtr != nullptr) _pagerFree(msgPtr.cast<Void>());

    final protocolName = (proto >= 0 && proto < kProtocolNames.length)
        ? kProtocolNames[proto]
        : 'UNKNOWN';

    _controller.add(PagerMessage(
      protocol:  protocolName,
      address:   addr,
      function:  func,
      message:   message,
      timestamp: DateTime.fromMillisecondsSinceEpoch(tsMs, isUtc: true),
    ));
  }
}

package com.example.pocketpager

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbManager
import android.os.Build
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * MainActivity – bridges Flutter ↔ Android USB Host API for RTL-SDR OTG.
 *
 * MethodChannel: "com.example.pocketpager/usb"
 *
 *   listDevices()  → List<Map<String, Any>>
 *       [ { "name": "/dev/bus/usb/001/002", "vid": 3034, "pid": 10296 } ]
 *
 *   openDevice(name: String) → Map<String, Any>
 *       { "fd": <int>, "path": <String> }
 *       The fd is handed to pager_open() via Dart FFI.
 *
 *   closeDevice() → null
 */
class MainActivity : FlutterActivity() {

    private val CHANNEL = "com.example.pocketpager/usb"
    private val ACTION_USB_PERMISSION = "com.example.pocketpager.USB_PERMISSION"
    private val RTLSDR_VID = 0x0BDA

    private var usbManager: UsbManager? = null
    private var openConnection: UsbDeviceConnection? = null
    private var pendingPermResult: MethodChannel.Result? = null
    private var pendingDevice: UsbDevice? = null

    private val permissionReceiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context, intent: Intent) {
            if (ACTION_USB_PERMISSION != intent.action) return
            val device: UsbDevice? =
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU)
                    intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
                else
                    @Suppress("DEPRECATION") intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)

            val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
            val result  = pendingPermResult ?: return
            val dev     = pendingDevice    ?: return
            pendingPermResult = null
            pendingDevice     = null

            if (!granted) {
                result.error("PERMISSION_DENIED", "USB permission denied for ${dev.deviceName}", null)
                return
            }
            openDeviceAndReturn(dev, result)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        usbManager = getSystemService(USB_SERVICE) as UsbManager

        val filter = IntentFilter(ACTION_USB_PERMISSION)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU)
            registerReceiver(permissionReceiver, filter, RECEIVER_NOT_EXPORTED)
        else
            registerReceiver(permissionReceiver, filter)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "listDevices" -> listDevices(result)
                    "openDevice"  -> {
                        Log.d("PocketPager", "openDevice called: args=${call.arguments} type=${call.arguments?.javaClass?.name}")
                        val name = call.argument<String>("name")
                        Log.d("PocketPager", "openDevice name=$name")
                        if (name == null) {
                            return@setMethodCallHandler result.error("BAD_ARGS",
                                "name required, got type=${call.arguments?.javaClass?.name} val=${call.arguments}", null)
                        }
                        openDevice(name, result)
                    }
                    "closeDevice" -> {
                        openConnection?.close()
                        openConnection = null
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        super.onDestroy()
        try { unregisterReceiver(permissionReceiver) } catch (_: Exception) {}
        openConnection?.close()
    }

    private fun listDevices(result: MethodChannel.Result) {
        val mgr  = usbManager ?: return result.error("NO_USB", "UsbManager unavailable", null)
        val list = mgr.deviceList.values
            .filter { it.vendorId == RTLSDR_VID }
            .map { dev -> mapOf("name" to dev.deviceName, "vid" to dev.vendorId, "pid" to dev.productId) }
        result.success(list)
    }

    private fun openDevice(name: String, result: MethodChannel.Result) {
        val mgr = usbManager ?: return result.error("NO_USB", "UsbManager unavailable", null)
        val dev = mgr.deviceList[name]
            ?: return result.error("NOT_FOUND", "Device $name not found", null)

        if (!mgr.hasPermission(dev)) {
            pendingPermResult = result
            pendingDevice     = dev
            val flags  = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
                PendingIntent.FLAG_MUTABLE else 0
            mgr.requestPermission(dev,
                PendingIntent.getBroadcast(this, 0, Intent(ACTION_USB_PERMISSION), flags))
        } else {
            openDeviceAndReturn(dev, result)
        }
    }

    private fun openDeviceAndReturn(dev: UsbDevice, result: MethodChannel.Result) {
        val mgr  = usbManager ?: return result.error("NO_USB", "UsbManager unavailable", null)
        val conn = mgr.openDevice(dev)
            ?: return result.error("OPEN_FAILED", "Failed to open ${dev.deviceName}", null)
        openConnection?.close()
        openConnection = conn
        result.success(mapOf("fd" to conn.fileDescriptor, "path" to dev.deviceName))
    }
}

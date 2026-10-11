package com.xjanova.localvpn

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity(), LocalVpnService.Listener {
    companion object {
        private const val TAG = "MainActivity"
    }

    private val VPN_CHANNEL = "com.xjanova.localvpn/vpn"
    private val INSTALL_CHANNEL = "com.xjanova.localvpn/installer"
    private val VPN_REQUEST_CODE = 100

    private var pendingResult: MethodChannel.Result? = null
    private var pendingVirtualIp: String? = null
    private var pendingSubnet: String? = null

    private val mainHandler = Handler(Looper.getMainLooper())
    private var vpnChannel: MethodChannel? = null

    // Hands every packet the TUN reader queued since the last run to Dart in one call.
    private val deliverPackets = Runnable {
        val packets = LocalVpnService.takePackets()
        if (packets.isNotEmpty()) {
            vpnChannel?.invokeMethod("onTunPackets", packets)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // APK Installer channel — uses FileProvider for Android 7+
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, INSTALL_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "installApk" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.error("INVALID_ARGS", "path is required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        installApk(path)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("INSTALL_ERROR", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, VPN_CHANNEL)
        vpnChannel = channel
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "startVpn" -> {
                    val virtualIp = call.argument<String>("virtualIp")
                    val subnet = call.argument<String>("subnet")

                    if (virtualIp == null || subnet == null) {
                        result.error("INVALID_ARGS", "virtualIp and subnet are required", null)
                        return@setMethodCallHandler
                    }
                    if (VirtualSubnet.parse(virtualIp, subnet) == null) {
                        result.error("INVALID_ARGS", "ข้อมูล IP ของวงเครือข่ายไม่ถูกต้อง", null)
                        return@setMethodCallHandler
                    }

                    pendingResult = result
                    pendingVirtualIp = virtualIp
                    pendingSubnet = subnet

                    val intent = VpnService.prepare(this)
                    if (intent != null) {
                        startActivityForResult(intent, VPN_REQUEST_CODE)
                    } else {
                        startVpnService(virtualIp, subnet)
                    }
                }
                "stopVpn" -> {
                    val stopIntent = Intent(this, LocalVpnService::class.java)
                    stopIntent.action = LocalVpnService.ACTION_STOP
                    try {
                        startService(stopIntent)
                    } catch (e: IllegalStateException) {
                        // Background start limits: no foreground VPN is running to stop.
                        Log.w(TAG, "Could not deliver stop request", e)
                    }
                    result.success(true)
                }
                "getVpnStatus" -> {
                    val status = if (LocalVpnService.isRunning) "connected" else "disconnected"
                    result.success(status)
                }
                "injectPacket" -> {
                    val data = call.argument<ByteArray>("data")
                    result.success(data != null && LocalVpnService.injectPacket(data))
                }
                "getStats" -> {
                    result.success(LocalVpnService.stats())
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        LocalVpnService.listener = this
        // Anything queued before this engine attached.
        mainHandler.post(deliverPackets)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        // The VPN keeps running without the UI; it just has nobody to hand
        // packets to until the app is opened again.
        if (LocalVpnService.listener === this) {
            LocalVpnService.listener = null
        }
        mainHandler.removeCallbacks(deliverPackets)
        vpnChannel?.setMethodCallHandler(null)
        vpnChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onPacketsQueued() {
        mainHandler.post(deliverPackets)
    }

    override fun onVpnStatusChanged(status: String) {
        vpnChannel?.invokeMethod("onVpnStatusChanged", status)
    }

    override fun onVpnError(message: String) {
        vpnChannel?.invokeMethod("onVpnError", message)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)

        // Handle Local VPN (Virtual LAN) permission result
        if (requestCode == VPN_REQUEST_CODE) {
            if (resultCode == Activity.RESULT_OK) {
                val ip = pendingVirtualIp
                val subnet = pendingSubnet
                if (ip != null && subnet != null) {
                    startVpnService(ip, subnet)
                } else {
                    pendingResult?.error("VPN_ERROR", "Missing VPN configuration", null)
                    pendingResult = null
                }
            } else {
                pendingResult?.error("VPN_DENIED", "User denied VPN permission", null)
                pendingResult = null
            }
        }

    }

    private fun startVpnService(virtualIp: String, subnet: String) {
        val intent = Intent(this, LocalVpnService::class.java)
        intent.action = LocalVpnService.ACTION_START
        intent.putExtra(LocalVpnService.EXTRA_VIRTUAL_IP, virtualIp)
        intent.putExtra(LocalVpnService.EXTRA_SUBNET, subnet)
        try {
            startService(intent)
            pendingResult?.success(true)
        } catch (e: IllegalStateException) {
            // Background start limits (Android 8+) when the app is not in front.
            Log.e(TAG, "Could not start LocalVpnService", e)
            pendingResult?.error("VPN_ERROR", "เปิด VPN ไม่สำเร็จ กรุณาเปิดแอปแล้วลองใหม่", null)
        }
        pendingResult = null
    }

    /// Install APK via FileProvider content:// URI (works on Android 7+)
    private fun installApk(filePath: String) {
        val file = File(filePath)
        if (!file.exists()) {
            throw IllegalArgumentException("APK file not found: $filePath")
        }

        val uri: Uri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            // Android 7+: use FileProvider for content:// URI
            FileProvider.getUriForFile(
                this,
                "${applicationContext.packageName}.fileprovider",
                file
            )
        } else {
            // Android 6 and below: use file:// URI directly
            Uri.fromFile(file)
        }

        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }

        startActivity(intent)
    }
}

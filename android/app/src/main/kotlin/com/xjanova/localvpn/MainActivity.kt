package com.xjanova.localvpn

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val VPN_CHANNEL = "com.xjanova.localvpn/vpn"
    private val VPN_REQUEST_CODE = 100

    private var pendingResult: MethodChannel.Result? = null
    private var pendingVirtualIp: String? = null
    private var pendingSubnet: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, VPN_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startVpn" -> {
                    val virtualIp = call.argument<String>("virtualIp")
                    val subnet = call.argument<String>("subnet")

                    if (virtualIp == null || subnet == null) {
                        result.error("INVALID_ARGS", "virtualIp and subnet are required", null)
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
                    startService(stopIntent)
                    result.success(true)
                }
                "getVpnStatus" -> {
                    val status = if (LocalVpnService.isRunning) "connected" else "disconnected"
                    result.success(status)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
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
        startService(intent)
        pendingResult?.success(true)
        pendingResult = null
    }
}

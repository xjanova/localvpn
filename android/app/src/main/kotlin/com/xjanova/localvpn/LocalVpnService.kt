package com.xjanova.localvpn

import android.content.Intent
import android.net.VpnService
import android.os.ParcelFileDescriptor

class LocalVpnService : VpnService() {

    companion object {
        const val ACTION_START = "com.xjanova.localvpn.START"
        const val ACTION_STOP = "com.xjanova.localvpn.STOP"
        const val EXTRA_VIRTUAL_IP = "virtual_ip"
        const val EXTRA_SUBNET = "subnet"

        @Volatile
        var isRunning: Boolean = false
            private set
    }

    private var vpnInterface: ParcelFileDescriptor? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val virtualIp = intent.getStringExtra(EXTRA_VIRTUAL_IP) ?: "10.10.0.2"
                val subnet = intent.getStringExtra(EXTRA_SUBNET) ?: "255.255.255.0"
                startVpn(virtualIp, subnet)
            }
            ACTION_STOP -> {
                stopVpn()
            }
        }
        return START_STICKY
    }

    private fun startVpn(virtualIp: String, subnet: String) {
        try {
            val prefixLength = subnetToPrefixLength(subnet)

            val builder = Builder()
                .setSession("LocalVPN")
                .addAddress(virtualIp, prefixLength)
                .addRoute("10.10.0.0", 24)
                .setMtu(1500)

            vpnInterface = builder.establish()
            isRunning = true
        } catch (e: Exception) {
            e.printStackTrace()
            stopVpn()
        }
    }

    private fun stopVpn() {
        try {
            vpnInterface?.close()
            vpnInterface = null
        } catch (e: Exception) {
            e.printStackTrace()
        }
        isRunning = false
        stopSelf()
    }

    override fun onDestroy() {
        stopVpn()
        super.onDestroy()
    }

    override fun onRevoke() {
        stopVpn()
        super.onRevoke()
    }

    private fun subnetToPrefixLength(subnet: String): Int {
        return when (subnet) {
            "255.255.255.0" -> 24
            "255.255.0.0" -> 16
            "255.0.0.0" -> 8
            "255.255.255.128" -> 25
            "255.255.255.192" -> 26
            "255.255.255.224" -> 27
            "255.255.255.240" -> 28
            else -> 24
        }
    }
}

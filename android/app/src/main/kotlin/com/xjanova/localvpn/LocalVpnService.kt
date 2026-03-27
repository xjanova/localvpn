package com.xjanova.localvpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log

class LocalVpnService : VpnService() {

    companion object {
        const val ACTION_START = "com.xjanova.localvpn.START"
        const val ACTION_STOP = "com.xjanova.localvpn.STOP"
        const val EXTRA_VIRTUAL_IP = "virtual_ip"
        const val EXTRA_SUBNET = "subnet"

        private const val TAG = "LocalVpnService"
        private const val CHANNEL_ID = "localvpn_channel"
        private const val NOTIFICATION_ID = 1

        @Volatile
        var isRunning: Boolean = false
            private set
    }

    private var vpnInterface: ParcelFileDescriptor? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val virtualIp = intent.getStringExtra(EXTRA_VIRTUAL_IP) ?: "10.10.0.2"
                val subnet = intent.getStringExtra(EXTRA_SUBNET) ?: "10.10.0.0/24"
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
            // Parse subnet — support both CIDR (10.10.0.0/24) and netmask (255.255.255.0)
            val prefixLength: Int
            val routeAddress: String

            if (subnet.contains("/")) {
                val parts = subnet.split("/")
                routeAddress = parts[0]
                prefixLength = parts[1].toIntOrNull() ?: 24
            } else {
                routeAddress = "10.10.0.0"
                prefixLength = subnetMaskToPrefixLength(subnet)
            }

            val builder = Builder()
                .setSession("LocalVPN")
                .addAddress(virtualIp, prefixLength)
                .addRoute(routeAddress, prefixLength)
                .setMtu(1500)
                .setBlocking(false)

            // Don't route all traffic through VPN — only the virtual LAN subnet
            // This prevents breaking internet connectivity

            vpnInterface = builder.establish()

            if (vpnInterface != null) {
                isRunning = true
                startForegroundNotification()
                Log.i(TAG, "VPN started: $virtualIp/$prefixLength route=$routeAddress")
            } else {
                Log.e(TAG, "Failed to establish VPN interface")
                stopVpn()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error starting VPN", e)
            stopVpn()
        }
    }

    private fun stopVpn() {
        try {
            vpnInterface?.close()
            vpnInterface = null
        } catch (e: Exception) {
            Log.e(TAG, "Error closing VPN interface", e)
        }
        isRunning = false
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun startForegroundNotification() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "LocalVPN Service",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "LocalVPN is running"
                setShowBadge(false)
            }
            val nm = getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(channel)
        }

        val notification = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
            .setContentTitle("LocalVPN")
            .setContentText("Virtual LAN is active")
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setOngoing(true)
            .build()

        startForeground(NOTIFICATION_ID, notification)
    }

    override fun onDestroy() {
        stopVpn()
        super.onDestroy()
    }

    override fun onRevoke() {
        stopVpn()
        super.onRevoke()
    }

    private fun subnetMaskToPrefixLength(mask: String): Int {
        return when (mask) {
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

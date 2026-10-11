package com.xjanova.localvpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.util.Log

class LocalVpnService : VpnService() {

    /** Implemented by MainActivity while its Flutter engine is attached. */
    interface Listener {
        /** Reader thread: packets are waiting in [takePackets]. Must be cheap. */
        fun onPacketsQueued()
        /** Main thread: "connected" or "disconnected". */
        fun onVpnStatusChanged(status: String)
        /** Main thread: the tunnel failed; [message] is shown to the user. */
        fun onVpnError(message: String)
    }

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

        // Everything below is used on the main thread only.
        private var tunnel: VpnTunnel? = null
        private val counters = VpnTunnel.Stats()

        /** Null while no Flutter UI is attached; the tunnel keeps running. */
        var listener: Listener? = null
            set(value) {
                field = value
                tunnel?.setWake(value?.let { it::onPacketsQueued })
            }

        fun takePackets(): List<ByteArray> = tunnel?.takePackets() ?: emptyList()

        fun injectPacket(data: ByteArray): Boolean = tunnel?.inject(data) ?: false

        fun stats(): Map<String, Any> = mapOf(
            "running" to (tunnel != null),
            "packetsIn" to counters.packetsIn.get(),
            "packetsOut" to counters.packetsOut.get(),
            "packetsDropped" to counters.packetsDropped.get(),
        )
    }

    private val mainHandler = Handler(Looper.getMainLooper())

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
            else -> {
                // Restarted after the process died: the Flutter side that carried
                // the traffic is gone, so there is nothing to resume.
                if (tunnel == null) stopSelf(startId)
            }
        }
        return START_STICKY
    }

    private fun startVpn(virtualIp: String, subnetText: String) {
        val subnet = VirtualSubnet.parse(virtualIp, subnetText)
        if (subnet == null) {
            failStart("ข้อมูล IP ของวงเครือข่ายไม่ถูกต้อง")
            return
        }

        // Joining another network replaces the running interface.
        closeTunnel()

        var pfd: ParcelFileDescriptor? = null
        try {
            // Only the virtual LAN subnet goes through the VPN, so internet
            // traffic keeps using the normal connection.
            pfd = Builder()
                .setSession("LocalVPN")
                .addAddress(virtualIp, subnet.prefix)
                .addRoute(VirtualSubnet.format(subnet.network), subnet.prefix)
                .setMtu(VpnTunnel.MTU)
                .setBlocking(false)
                .establish()
            if (pfd == null) {
                failStart("ไม่ได้รับอนุญาตให้เปิด VPN กรุณาเชื่อมต่อใหม่")
                return
            }

            val newTunnel = VpnTunnel(pfd, subnet, counters) { failed, message ->
                mainHandler.post { onTunnelFailed(failed, message) }
            }
            newTunnel.setWake(listener?.let { it::onPacketsQueued })
            newTunnel.start()
            tunnel = newTunnel
            isRunning = true
            startForegroundNotification()
            Log.i(TAG, "VPN started: $virtualIp/${subnet.prefix} mtu=${VpnTunnel.MTU}")
            listener?.onVpnStatusChanged("connected")
        } catch (e: Exception) {
            Log.e(TAG, "Error starting VPN", e)
            // Once the tunnel is stored it owns the fd and failStart() closes it.
            if (tunnel == null) {
                try {
                    pfd?.close()
                } catch (closeError: Exception) {
                    Log.w(TAG, "Error closing VPN interface", closeError)
                }
            }
            failStart("เปิดการ์ดเครือข่ายเสมือนไม่สำเร็จ")
        }
    }

    private fun failStart(message: String) {
        Log.e(TAG, message)
        closeTunnel()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
        listener?.onVpnError(message)
    }

    private fun onTunnelFailed(failed: VpnTunnel, message: String) {
        if (tunnel !== failed) return  // already stopped or replaced
        failStart(message)
    }

    private fun stopVpn() {
        val wasRunning = closeTunnel()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
        if (wasRunning) listener?.onVpnStatusChanged("disconnected")
    }

    /** Stops the reader and closes the interface. Returns whether one was open. */
    private fun closeTunnel(): Boolean {
        val current = tunnel ?: return false
        tunnel = null
        isRunning = false
        current.stop()
        Log.i(TAG, "VPN stopped")
        return true
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
        if (closeTunnel()) listener?.onVpnStatusChanged("disconnected")
        super.onDestroy()
    }

    override fun onRevoke() {
        // Another VPN took over or the user turned it off in system settings.
        // This arrives on a binder thread, while the tunnel and the Flutter
        // channel belong to the main thread. super.onRevoke() only calls
        // stopSelf(), which stopVpn() does.
        mainHandler.post { stopVpn() }
    }
}

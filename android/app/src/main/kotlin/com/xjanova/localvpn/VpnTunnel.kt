package com.xjanova.localvpn

import android.os.ParcelFileDescriptor
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.system.StructPollfd
import android.util.Log
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.util.concurrent.atomic.AtomicLong

/** The member's place in the virtual LAN. Addresses are host byte order. */
class VirtualSubnet(val ownIp: Int, val prefix: Int) {
    val mask: Int = -1 shl (32 - prefix)
    val network: Int = ownIp and mask
    val broadcast: Int = network or mask.inv()

    companion object {
        fun parse(virtualIp: String, subnet: String): VirtualSubnet? {
            val ip = parseIpv4(virtualIp) ?: return null
            val prefix = parsePrefix(subnet) ?: return null
            return VirtualSubnet(ip, prefix)
        }

        fun parseIpv4(text: String): Int? {
            val parts = text.split('.')
            if (parts.size != 4) return null
            var value = 0
            for (part in parts) {
                if (part.isEmpty() || part.length > 3 || !part.all { it in '0'..'9' }) return null
                val octet = part.toInt()
                if (octet > 255) return null
                value = (value shl 8) or octet
            }
            return value
        }

        // Accepts "10.10.0.0/24" or a netmask such as "255.255.255.0", 8..30 bits
        // like the Windows runner.
        fun parsePrefix(subnet: String): Int? {
            val slash = subnet.indexOf('/')
            val bits = if (slash >= 0) {
                subnet.substring(slash + 1).toIntOrNull() ?: return null
            } else {
                val mask = parseIpv4(subnet) ?: return null
                val ones = Integer.numberOfLeadingZeros(mask.inv())
                // Reject non-contiguous masks.
                if (ones >= 32 || (mask shl ones) != 0) return null
                ones
            }
            return bits.takeIf { it in 8..30 }
        }

        fun format(ip: Int): String =
            "${ip ushr 24}.${(ip ushr 16) and 0xFF}.${(ip ushr 8) and 0xFF}.${ip and 0xFF}"
    }
}

/**
 * Moves packets between the VpnService TUN interface and Flutter — the Android
 * counterpart of windows/runner/vpn_tunnel.cpp.
 *
 * A reader thread queues IPv4 packets addressed to the virtual subnet and
 * calls [wake] whenever the queue goes from empty to non-empty; the caller
 * drains it on the main thread with [takePackets]. [inject] writes a packet
 * received from a peer back into the interface.
 *
 * The tunnel owns [tun] and closes it in [stop].
 */
class VpnTunnel(
    private val tun: ParcelFileDescriptor,
    private val subnet: VirtualSubnet,
    private val stats: Stats,
    // Reader thread, when the interface dies on its own.
    private val onFail: (VpnTunnel, String) -> Unit,
) {
    companion object {
        private const val TAG = "VpnTunnel"

        const val MTU = 1400  // leaves room for UDP/relay overhead
        private const val MAX_PACKET_SIZE = 0xFFFF
        private const val MAX_QUEUED_PACKETS = 4096
        private const val LIMITED_BROADCAST = -1  // 255.255.255.255

        private fun ipv4At(p: ByteArray, offset: Int): Int =
            ((p[offset].toInt() and 0xFF) shl 24) or
                ((p[offset + 1].toInt() and 0xFF) shl 16) or
                ((p[offset + 2].toInt() and 0xFF) shl 8) or
                (p[offset + 3].toInt() and 0xFF)

        private fun isIpv4(p: ByteArray): Boolean = ((p[0].toInt() shr 4) and 0xF) == 4
    }

    /** Process-wide counters, reported by getStats. */
    class Stats {
        val packetsIn = AtomicLong()
        val packetsOut = AtomicLong()
        val packetsDropped = AtomicLong()
    }

    private val output = FileOutputStream(tun.fileDescriptor)
    private val lock = Any()
    private var queue = ArrayList<ByteArray>()
    private var reader: Thread? = null
    // Closing the write end wakes the reader out of poll().
    private var wakeRead: ParcelFileDescriptor? = null
    private var wakeWrite: ParcelFileDescriptor? = null

    @Volatile
    private var running = false

    // Null while no Flutter engine is attached; packets read then are dropped
    // instead of piling up for a UI that may never come back.
    @Volatile
    private var wake: (() -> Unit)? = null

    fun setWake(callback: (() -> Unit)?) {
        wake = callback
        if (callback == null) {
            synchronized(lock) { queue.clear() }
        }
    }

    fun start() {
        val pipe = ParcelFileDescriptor.createPipe()
        wakeRead = pipe[0]
        wakeWrite = pipe[1]
        running = true
        reader = Thread(::readLoop, "LocalVpnTunReader").apply {
            isDaemon = true
            start()
        }
    }

    fun stop() {
        synchronized(lock) {
            running = false
            queue.clear()
        }
        closeQuietly(wakeWrite)
        wakeWrite = null
        reader?.let {
            it.join(1000)
            if (it.isAlive) Log.w(TAG, "Reader thread did not stop in time")
        }
        reader = null
        closeQuietly(wakeRead)
        wakeRead = null
        // The reader has exited and inject() checks |running| under |lock|, so
        // nothing touches the fd once it is closed.
        synchronized(lock) { closeQuietly(tun) }
    }

    /** Moves every queued packet out. Thread-safe. */
    fun takePackets(): List<ByteArray> = synchronized(lock) {
        if (queue.isEmpty()) return emptyList()
        val out = queue
        queue = ArrayList()
        out
    }

    /** Writes a packet from a peer into the interface. Thread-safe. */
    fun inject(data: ByteArray): Boolean {
        if (data.size < 20 || data.size > MAX_PACKET_SIZE || !isIpv4(data)) return false
        // A peer may only hand us packets from inside the virtual subnet, addressed
        // to us or to a broadcast address — nothing that looks like it came from the
        // internet or targets another host.
        val src = ipv4At(data, 12)
        val dst = ipv4At(data, 16)
        if ((src and subnet.mask) != subnet.network || src == subnet.ownIp) return false
        if (dst != subnet.ownIp && dst != subnet.broadcast && dst != LIMITED_BROADCAST) return false

        synchronized(lock) {
            if (!running) return false
            try {
                output.write(data)
            } catch (e: IOException) {
                stats.packetsDropped.incrementAndGet()
                return false
            }
        }
        stats.packetsIn.incrementAndGet()
        return true
    }

    private fun shouldForward(p: ByteArray, size: Int): Boolean {
        if (size < 20 || !isIpv4(p)) return false
        val dst = ipv4At(p, 16)
        if (dst == LIMITED_BROADCAST) return true
        if ((dst ushr 28) == 0xE) return false  // multicast noise
        if ((dst and subnet.mask) != subnet.network) return false
        if (dst == subnet.ownIp || dst == subnet.network) return false
        return true  // a peer, or the subnet broadcast (LAN game discovery)
    }

    private fun enqueue(buffer: ByteArray, size: Int) {
        if (!shouldForward(buffer, size)) return
        val callback = wake
        if (callback == null) {
            stats.packetsDropped.incrementAndGet()
            return
        }
        val packet = buffer.copyOf(size)
        val wasEmpty: Boolean
        synchronized(lock) {
            if (!running) return
            if (queue.size >= MAX_QUEUED_PACKETS) {
                stats.packetsDropped.incrementAndGet()
                return
            }
            wasEmpty = queue.isEmpty()
            queue.add(packet)
        }
        stats.packetsOut.incrementAndGet()
        if (wasEmpty) callback()
    }

    private fun readLoop() {
        // Non-blocking fd: read() returns 0 when the interface is empty.
        val input = FileInputStream(tun.fileDescriptor)
        val buffer = ByteArray(MAX_PACKET_SIZE)
        val tunPoll = StructPollfd().apply {
            fd = tun.fileDescriptor
            events = OsConstants.POLLIN.toShort()
        }
        val wakePoll = StructPollfd().apply {
            fd = wakeRead!!.fileDescriptor
            events = OsConstants.POLLIN.toShort()
        }
        val polls = arrayOf(tunPoll, wakePoll)
        val errorBits = OsConstants.POLLERR or OsConstants.POLLHUP or OsConstants.POLLNVAL

        try {
            while (running) {
                val size = input.read(buffer)
                if (size > 0) {
                    enqueue(buffer, size)
                    continue
                }
                if (size < 0) throw IOException("TUN interface closed")

                tunPoll.revents = 0
                wakePoll.revents = 0
                try {
                    Os.poll(polls, -1)
                } catch (e: ErrnoException) {
                    if (e.errno == OsConstants.EINTR) continue
                    throw e
                }
                if (wakePoll.revents.toInt() != 0) break  // stop()
                if ((tunPoll.revents.toInt() and errorBits) != 0) {
                    throw IOException("TUN poll revents=${tunPoll.revents}")
                }
            }
        } catch (e: Exception) {
            if (running) {
                Log.e(TAG, "Reader failed", e)
                onFail(this, "การ์ดเครือข่ายเสมือนหยุดทำงาน")
            }
        }
    }

    private fun closeQuietly(pfd: ParcelFileDescriptor?) {
        try {
            pfd?.close()
        } catch (e: IOException) {
            Log.w(TAG, "close failed", e)
        }
    }
}

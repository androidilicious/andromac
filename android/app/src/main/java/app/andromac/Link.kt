package app.andromac

import android.content.Context
import android.net.Uri
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.util.Log
import org.json.JSONObject
import java.net.InetAddress
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Shared connection state. The socket itself is owned by [LinkService]. */
object Link {
    const val TAG = "AndroMac"
    @Volatile var channel: SecureChannel? = null
    @Volatile var peerName: String? = null
    @Volatile var onStatus: (() -> Unit)? = null
    /** Set by [LinkService]: sends the current status to the Mac. */
    @Volatile var pushStatus: (() -> Unit)? = null

    val main = Handler(Looper.getMainLooper())
    /** Slow jobs (photos, contacts, file sends) run here, one at a time. */
    val worker = Executors.newSingleThreadExecutor()
    /** Small messages posted from the main thread are sent here, since sockets are not allowed on it. */
    private val tx = Executors.newSingleThreadExecutor()

    val connected get() = channel != null

    fun prefs(c: Context) = c.getSharedPreferences("link", Context.MODE_PRIVATE)
    fun paired(c: Context) = prefs(c).contains("key")

    /** Accepts andromac://pair?h=HOST&p=PORT&k=KEY&id=ID&n=NAME (the content of the Mac's QR code). */
    fun savePairing(c: Context, text: String): Boolean {
        val u = try { Uri.parse(text.trim()) } catch (_: Exception) { return false }
        if (u.scheme != "andromac" || u.host != "pair") return false
        val key = u.getQueryParameter("k") ?: return false
        val host = u.getQueryParameter("h") ?: return false
        val port = u.getQueryParameter("p")?.toIntOrNull() ?: return false
        val id = u.getQueryParameter("id") ?: return false
        if (decodeKey(key)?.size != 32) return false
        prefs(c).edit().putString("key", key).putString("host", host).putInt("port", port)
            .putString("id", id).putString("name", u.getQueryParameter("n") ?: "Mac").apply()
        return true
    }

    fun decodeKey(s: String): ByteArray? =
        try { Base64.decode(s, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING) } catch (_: Exception) { null }

    fun msg(t: String, build: JSONObject.() -> Unit = {}): JSONObject = JSONObject().put("t", t).apply(build)

    /** Queue a JSON message. Safe from any thread, including main. */
    fun send(j: JSONObject) = tx.execute { sendNow(j) }

    /** Send immediately on the calling thread. Never call from the main thread. */
    fun sendNow(j: JSONObject) = sendNow(T.JSON, j.toString().toByteArray(Charsets.UTF_8))

    fun sendNow(type: Int, vararg parts: ByteArray): Boolean {
        val ch = channel ?: return false
        return try { ch.send(type, *parts); true } catch (e: Exception) {
            Log.w(TAG, "send failed: $e"); ch.close(); false
        }
    }

    fun error(text: String) = send(msg("error") { put("msg", text) })
    /** Something the UI and the Mac both show has changed (a service was switched on or off). */
    fun status() { pushStatus?.invoke(); main.post { onStatus?.invoke() } }
}

/** Finds the Mac on the local network by its Bonjour name, so pairing survives IP changes. */
object Discovery {
    fun find(ctx: Context, namePrefix: String, timeoutMs: Long): Pair<InetAddress, Int>? {
        val nsd = ctx.getSystemService(NsdManager::class.java) ?: return null
        val latch = CountDownLatch(1)
        var result: Pair<InetAddress, Int>? = null
        val listener = object : NsdManager.DiscoveryListener {
            override fun onServiceFound(info: NsdServiceInfo) {
                if (!info.serviceName.startsWith(namePrefix)) return
                try {
                    @Suppress("DEPRECATION")
                    nsd.resolveService(info, object : NsdManager.ResolveListener {
                        override fun onResolveFailed(i: NsdServiceInfo, code: Int) {}
                        override fun onServiceResolved(i: NsdServiceInfo) {
                            @Suppress("DEPRECATION")
                            val host = i.host ?: return
                            result = host to i.port
                            latch.countDown()
                        }
                    })
                } catch (_: Exception) {}
            }
            override fun onServiceLost(info: NsdServiceInfo) {}
            override fun onDiscoveryStarted(type: String) {}
            override fun onDiscoveryStopped(type: String) {}
            override fun onStartDiscoveryFailed(type: String, code: Int) { latch.countDown() }
            override fun onStopDiscoveryFailed(type: String, code: Int) {}
        }
        return try {
            nsd.discoverServices("_andromac._tcp", NsdManager.PROTOCOL_DNS_SD, listener)
            latch.await(timeoutMs, TimeUnit.MILLISECONDS)
            try { nsd.stopServiceDiscovery(listener) } catch (_: Exception) {}
            result
        } catch (e: Exception) { Log.w(Link.TAG, "discovery failed: $e"); null }
    }
}

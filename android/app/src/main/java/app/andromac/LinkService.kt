package app.andromac

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.media.projection.MediaProjectionManager
import android.os.BatteryManager
import android.os.Build
import android.os.IBinder
import android.provider.Settings
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import org.json.JSONObject
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer

/** Foreground service that owns the connection to the Mac and routes every incoming message. */
class LinkService : Service() {
    @Volatile private var running = false
    private var loop: Thread? = null
    private var screen: ScreenStreamer? = null
    private var camera: CameraStreamer? = null
    private val fileRx by lazy { Media.FileRx(this) }
    private val smsWatcher by lazy { Sms.Watcher(this) }
    private var mirrorMax = 1280
    private var mirrorBitrate = 6_000_000

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CH_LINK, "Connection", NotificationManager.IMPORTANCE_LOW))
        nm.createNotificationChannel(NotificationChannel(CH_REQ, "Requests from your Mac", NotificationManager.IMPORTANCE_HIGH))
        nm.createNotificationChannel(NotificationChannel(CH_FILES, "Received files", NotificationManager.IMPORTANCE_DEFAULT))
        Link.pushStatus = { if (Link.connected) sendStatus() }
        registerReceiver(batteryWatcher, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> { shutdown(); stopSelf(); return START_NOT_STICKY }
            ACTION_PROJECTION -> {
                goForeground(projection = true)
                getSystemService(NotificationManager::class.java).cancel(NOTE_REQ)
                val code = intent.getIntExtra("code", 0)
                @Suppress("DEPRECATION") val data = intent.getParcelableExtra<Intent>("data")
                if (data != null) startMirror(code, data)
            }
            else -> goForeground(projection = screen != null)
        }
        if (running && !Link.connected) loop?.interrupt() // opening the app retries right away
        if (!running && Link.paired(this)) {
            running = true
            loop = Thread({ runLoop() }, "andromac-link").also { it.start() }
        }
        return START_STICKY
    }

    override fun onDestroy() { shutdown(); Link.pushStatus = null; smsWatcher.stop()
        try { unregisterReceiver(batteryWatcher) } catch (_: Exception) {}
        super.onDestroy() }

    private fun shutdown() {
        running = false
        Link.channel?.close()
        loop?.interrupt()
    }

    private fun goForeground(projection: Boolean) {
        var types = ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
        if (projection) types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
        if (checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED)
            types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
        try {
            ServiceCompat.startForeground(this, NOTE_LINK, statusNote(), types)
        } catch (e: Exception) {
            Log.w(Link.TAG, "foreground with types $types refused: $e")
            ServiceCompat.startForeground(this, NOTE_LINK, statusNote(), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        }
    }

    private fun statusNote(): Notification {
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val text = if (Link.connected) "Connected to ${Link.peerName ?: "your Mac"}" else "Looking for your Mac"
        return NotificationCompat.Builder(this, CH_LINK)
            .setSmallIcon(R.drawable.ic_link).setContentTitle("AndroMac").setContentText(text)
            .setContentIntent(open).setOngoing(true).build()
    }

    private fun refreshNote() {
        try { getSystemService(NotificationManager::class.java).notify(NOTE_LINK, statusNote()) } catch (_: Exception) {}
        Link.main.post { Link.onStatus?.invoke() }
    }

    // ---- connection loop ----

    private fun runLoop() {
        var wait = 2000L // grows while the Mac is away, to spare the battery
        while (running) {
            var ch: SecureChannel? = null
            try {
                val p = Link.prefs(this)
                val key = Link.decodeKey(p.getString("key", "")!!) ?: throw IllegalStateException("no key")
                val found = Discovery.find(this, "AndroMac-" + p.getString("id", ""), 2500)
                val host = found?.first ?: InetAddress.getByName(p.getString("host", ""))
                val port = found?.second ?: p.getInt("port", 47800)
                if (found != null) p.edit().putString("host", host.hostAddress).putInt("port", port).apply()

                val s = Socket()
                s.tcpNoDelay = true
                s.connect(InetSocketAddress(host, port), 4000)
                s.soTimeout = 30_000 // the Mac pings every 10 s
                ch = SecureChannel(s, key)
                Link.channel = ch
                wait = 2000L
                Link.sendNow(Link.msg("hello") {
                    put("name", "${Build.MANUFACTURER} ${Build.MODEL}")
                    put("sdk", Build.VERSION.SDK_INT)
                })
                ensureWirelessDebugging()
                sendStatus()
                refreshNote()
                smsWatcher.start()
                while (running) {
                    val (type, data) = ch.recv()
                    try { handle(type, data) } catch (e: Exception) {
                        Log.w(Link.TAG, "handler error", e)
                        Link.error(e.message ?: e.toString())
                    }
                }
            } catch (e: Exception) {
                Log.i(Link.TAG, "link down: $e")
            } finally {
                ch?.close()
                Link.channel = null
                Link.peerName = null
                Link.main.post { stopMirror(); stopCamera() }
                fileRx.abort()
                refreshNote()
            }
            if (running) try { Thread.sleep(wait) } catch (_: InterruptedException) {}
            wait = minOf(wait * 2, 20_000L)
        }
    }

    /**
     * Android switches wireless debugging off at every restart, which would leave the Mac's native phone
     * window needing a cable again. Once the Mac has granted WRITE_SECURE_SETTINGS over adb, switch it back
     * on each time the link comes up. The phone still only accepts computers approved on its debugging prompt.
     */
    private fun ensureWirelessDebugging() {
        if (checkSelfPermission(Manifest.permission.WRITE_SECURE_SETTINGS) != PackageManager.PERMISSION_GRANTED) return
        try {
            val cr = contentResolver
            if (Settings.Global.getInt(cr, Settings.Global.ADB_ENABLED, 0) != 1) return // debugging was turned off: respect that
            if (Settings.Global.getInt(cr, "adb_wifi_enabled", 0) != 1) Settings.Global.putInt(cr, "adb_wifi_enabled", 1)
        } catch (e: Exception) { Log.w(Link.TAG, "could not enable wireless debugging: $e") }
    }

    private fun sendStatus() = Link.send(Link.msg("status") {
        put("accessibility", InputService.instance != null)
        put("notifications", NotifService.instance != null)
        put("mirror", screen != null)
        put("camera", camera != null)
        val b = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val level = b?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = b?.getIntExtra(BatteryManager.EXTRA_SCALE, 100) ?: 100
        put("battery", if (level >= 0 && scale > 0) level * 100 / scale else -1)
        put("charging", (b?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0) != 0)
    })

    /** Re-sends the status when the battery level or charging state changes, for the Mac's battery display. */
    private val batteryWatcher = object : BroadcastReceiver() {
        private var last = -1
        override fun onReceive(c: Context, i: Intent) {
            val now = i.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) * 2 + (if (i.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) != 0) 1 else 0)
            if (now != last) { last = now; if (Link.connected) sendStatus() }
        }
    }

    // ---- message routing ----

    private fun handle(type: Int, data: ByteArray) {
        when (type) {
            T.JSON -> onJson(JSONObject(String(data, Charsets.UTF_8)))
            T.FILE -> fileRx.chunk(data)
        }
    }

    private fun onJson(j: JSONObject) {
        when (j.getString("t")) {
            "hello" -> { Link.peerName = j.optString("name", "Mac"); refreshNote() }
            "ping" -> {}
            "clip" -> {
                val text = j.getString("text")
                Link.main.post {
                    getSystemService(ClipboardManager::class.java)
                        .setPrimaryClip(ClipData.newPlainText("AndroMac", text))
                }
            }
            "reply" -> NotifService.instance?.reply(j.getString("key"), j.getString("text"))
                ?: Link.error("Notification access is off on the phone")
            "dismiss" -> NotifService.instance?.dismiss(j.getString("key"))
            "file_start" -> fileRx.start(j)
            "file_end" -> fileRx.end()
            "photos_get" -> Link.worker.execute {
                guarded { Link.sendNow(Media.photos(this, j.optInt("offset"), j.optInt("limit", 60))) }
            }
            "thumb_get" -> Link.worker.execute {
                guarded {
                    val id = j.getLong("id")
                    Media.thumb(this, id)?.let {
                        Link.sendNow(T.THUMB, ByteBuffer.allocate(8).putLong(id).array(), it)
                    }
                }
            }
            "photo_get" -> Link.worker.execute { guarded { Media.sendPhoto(this, j.getLong("id")) } }
            "contacts_get" -> Link.worker.execute { guarded { Link.sendNow(Media.contacts(this)) } }
            "apps_get" -> Link.worker.execute { guarded { Link.sendNow(Media.apps(this)) } }
            "app_icon_get" -> Link.worker.execute {
                guarded {
                    val pkg = j.getString("pkg").toByteArray(Charsets.UTF_8)
                    Link.sendNow(T.ICON, ByteBuffer.allocate(2).putShort(pkg.size.toShort()).array(), pkg,
                        Media.appIcon(this, j.getString("pkg")))
                }
            }
            "sms_threads_get" -> Link.worker.execute { guarded { smsWatcher.start(); Link.sendNow(Sms.threads(this)) } }
            "sms_get" -> Link.worker.execute {
                guarded { Link.sendNow(Sms.messages(this, j.getLong("thread"), j.optInt("limit", 200))) }
            }
            "sms_send" -> Link.worker.execute { guarded { Sms.send(this, j.getString("to"), j.getString("text")) } }
            "mirror_start" -> {
                mirrorMax = j.optInt("max", 1280)
                mirrorBitrate = j.optInt("bitrate", 6_000_000)
                Link.main.post { requestProjection() }
            }
            "mirror_stop" -> Link.main.post { stopMirror() }
            "keyframe" -> { screen?.requestKeyframe(); camera?.requestKeyframe() }
            "input" -> InputService.instance?.handle(j)
                ?: Link.error("Turn on AndroMac remote control in Accessibility settings on the phone")
            "cam_start" -> Link.main.post { startCamera(j.optBoolean("front", false)) }
            "cam_stop" -> Link.main.post { stopCamera() }
        }
    }

    private inline fun guarded(block: () -> Unit) {
        try { block() } catch (e: SecurityException) {
            Link.error("Permission missing on the phone. Open AndroMac and tap Grant permissions.")
        } catch (e: Exception) {
            Log.w(Link.TAG, "job failed", e); Link.error(e.message ?: e.toString())
        }
    }

    // ---- screen mirroring ----

    /** Android requires a fresh on-phone consent for every capture session. */
    private fun requestProjection() {
        if (screen != null) { screen?.requestKeyframe(); return }
        val i = Intent(this, ProjectionActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        // Works when the accessibility service is on or the app is visible; otherwise the notification is the way in.
        try { startActivity(i) } catch (_: Exception) {}
        val pi = PendingIntent.getActivity(this, 1, i, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val note = NotificationCompat.Builder(this, CH_REQ)
            .setSmallIcon(R.drawable.ic_link).setContentTitle("Your Mac wants to mirror this screen")
            .setContentText("Tap to allow").setContentIntent(pi).setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH).build()
        try { getSystemService(NotificationManager::class.java).notify(NOTE_REQ, note) } catch (_: Exception) {}
    }

    private fun startMirror(code: Int, data: Intent) {
        stopMirror()
        try {
            val mp = getSystemService(MediaProjectionManager::class.java).getMediaProjection(code, data)
            screen = ScreenStreamer(this, mp, mirrorMax, mirrorBitrate) { Link.main.post { stopMirror() } }
        } catch (e: Exception) {
            Log.w(Link.TAG, "mirror failed", e); Link.error("Could not start mirroring: ${e.message}")
        }
        sendStatus()
    }

    private fun stopMirror() {
        val s = screen ?: return
        screen = null
        s.stop()
        sendStatus()
    }

    // ---- camera ----

    private fun startCamera(front: Boolean) {
        stopCamera()
        if (checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            Link.error("Camera permission is off. Open AndroMac on the phone and tap Grant permissions."); return
        }
        try { camera = CameraStreamer(this, front) } catch (e: Exception) {
            Log.w(Link.TAG, "camera failed", e); Link.error("Could not start the camera: ${e.message}")
        }
        sendStatus()
    }

    private fun stopCamera() {
        val c = camera ?: return
        camera = null
        c.stop()
        sendStatus()
    }

    companion object {
        const val ACTION_STOP = "app.andromac.STOP"
        const val ACTION_PROJECTION = "app.andromac.PROJECTION"
        const val CH_LINK = "link"
        const val CH_REQ = "requests"
        const val CH_FILES = "files"
        const val NOTE_LINK = 1
        const val NOTE_REQ = 2

        fun start(c: Context) = c.startForegroundService(Intent(c, LinkService::class.java))
    }
}

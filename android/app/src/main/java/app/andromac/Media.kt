package app.andromac

import android.app.NotificationManager
import android.content.ContentResolver
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.graphics.Canvas
import android.graphics.Bitmap
import android.net.Uri
import android.os.Bundle
import android.provider.ContactsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.util.Log
import android.util.Size
import androidx.core.app.NotificationCompat
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicInteger

/** Files, photos and contacts. */
object Media {
    private val nextId = AtomicInteger(1)

    class SendJob(val name: String, val size: Long, val input: InputStream, val photoId: Long? = null)

    fun open(ctx: Context, uri: Uri): SendJob? {
        var name = uri.lastPathSegment ?: "file"
        var size = -1L
        ctx.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { c ->
            if (c.moveToFirst()) {
                if (!c.isNull(0)) name = c.getString(0)
                if (!c.isNull(1)) size = c.getLong(1)
            }
        }
        val input = ctx.contentResolver.openInputStream(uri) ?: return null
        return SendJob(name, size, input)
    }

    /** file_start, then FILE chunks of id(4) + data, then file_end. Runs on the worker thread. */
    fun sendStream(job: SendJob) {
        val id = nextId.getAndIncrement()
        val idBytes = ByteBuffer.allocate(4).putInt(id).array()
        try {
            job.input.use { input ->
                if (!Link.sendNow(Link.msg("file_start") {
                        put("id", id); put("name", job.name); put("size", job.size)
                        job.photoId?.let { put("photo", it) }
                    })) return
                val buf = ByteArray(64 * 1024)
                while (true) {
                    val n = input.read(buf)
                    if (n < 0) break
                    if (!Link.sendNow(T.FILE, idBytes, buf.copyOf(n))) return
                }
                Link.sendNow(Link.msg("file_end") { put("id", id); put("ok", true) })
            }
        } catch (e: Exception) {
            Log.w(Link.TAG, "file send failed", e)
            Link.sendNow(Link.msg("file_end") { put("id", id); put("ok", false) })
        }
    }

    fun sendPhoto(ctx: Context, id: Long) {
        val uri = ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id)
        open(ctx, uri)?.let { sendStream(SendJob(it.name, it.size, it.input, id)) }
    }

    fun photos(ctx: Context, offset: Int, limit: Int): JSONObject {
        val items = JSONArray()
        val args = Bundle().apply {
            putStringArray(ContentResolver.QUERY_ARG_SORT_COLUMNS, arrayOf(MediaStore.Images.Media.DATE_ADDED))
            putInt(ContentResolver.QUERY_ARG_SORT_DIRECTION, ContentResolver.QUERY_SORT_DIRECTION_DESCENDING)
            putInt(ContentResolver.QUERY_ARG_LIMIT, limit)
            putInt(ContentResolver.QUERY_ARG_OFFSET, offset)
        }
        val cols = arrayOf(MediaStore.Images.Media._ID, MediaStore.Images.Media.DISPLAY_NAME, MediaStore.Images.Media.DATE_ADDED)
        ctx.contentResolver.query(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, cols, args, null)?.use { c ->
            while (c.moveToNext()) {
                items.put(JSONObject().put("id", c.getLong(0)).put("name", c.getString(1) ?: "").put("ts", c.getLong(2)))
            }
        }
        return Link.msg("photos") { put("offset", offset); put("items", items); put("more", items.length() == limit) }
    }

    fun thumb(ctx: Context, id: Long): ByteArray? {
        val uri = ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id)
        val bmp = ctx.contentResolver.loadThumbnail(uri, Size(320, 320), null)
        val out = ByteArrayOutputStream()
        bmp.compress(Bitmap.CompressFormat.JPEG, 75, out)
        bmp.recycle()
        return out.toByteArray()
    }

    /** Apps that have a launcher icon, by name. */
    fun apps(ctx: Context): JSONObject {
        val pm = ctx.packageManager
        val launch = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val seen = HashSet<String>()
        val rows = ArrayList<JSONObject>()
        for (r in pm.queryIntentActivities(launch, 0)) {
            val info = r.activityInfo?.applicationInfo ?: continue
            if (info.packageName == ctx.packageName || !seen.add(info.packageName)) continue
            rows += JSONObject().put("pkg", info.packageName).put("name", pm.getApplicationLabel(info).toString())
                .put("system", info.flags and ApplicationInfo.FLAG_SYSTEM != 0)
        }
        rows.sortBy { it.getString("name").lowercase() }
        return Link.msg("apps") { put("items", JSONArray(rows)) }
    }

    /** The app's launcher icon as a 144 px PNG. */
    fun appIcon(ctx: Context, pkg: String): ByteArray {
        val d = ctx.packageManager.getApplicationIcon(pkg)
        val bmp = Bitmap.createBitmap(144, 144, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        d.setBounds(0, 0, 144, 144)
        d.draw(canvas)
        val out = ByteArrayOutputStream()
        bmp.compress(Bitmap.CompressFormat.PNG, 100, out)
        bmp.recycle()
        return out.toByteArray()
    }

    fun contacts(ctx: Context): JSONObject {
        val byName = LinkedHashMap<String, LinkedHashSet<String>>()
        val cols = arrayOf(
            ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
            ContactsContract.CommonDataKinds.Phone.NUMBER
        )
        ctx.contentResolver.query(
            ContactsContract.CommonDataKinds.Phone.CONTENT_URI, cols, null, null,
            ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME + " COLLATE NOCASE ASC"
        )?.use { c ->
            while (c.moveToNext()) {
                val name = c.getString(0) ?: continue
                val number = c.getString(1) ?: continue
                byName.getOrPut(name) { LinkedHashSet() }.add(number)
            }
        }
        val items = JSONArray()
        for ((name, numbers) in byName) items.put(JSONObject().put("name", name).put("phones", JSONArray(numbers.toList())))
        return Link.msg("contacts") { put("items", items) }
    }

    /** Receives one file at a time from the Mac into Downloads/AndroMac. Called on the link thread only. */
    class FileRx(private val ctx: Context) {
        private var out: OutputStream? = null
        private var uri: Uri? = null
        private var name = ""

        fun start(j: JSONObject) {
            abort()
            name = j.optString("name", "file").substringAfterLast('/').ifEmpty { "file" }
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, name)
                put(MediaStore.Downloads.RELATIVE_PATH, "Download/AndroMac")
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            uri = ctx.contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            out = uri?.let { ctx.contentResolver.openOutputStream(it) }
        }

        fun chunk(d: ByteArray) { if (d.size > 4) out?.write(d, 4, d.size - 4) }

        fun end() {
            val u = uri ?: return
            try { out?.close() } catch (_: Exception) {}
            out = null; uri = null
            ctx.contentResolver.update(u, ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }, null, null)
            val note = NotificationCompat.Builder(ctx, LinkService.CH_FILES)
                .setSmallIcon(R.drawable.ic_link).setContentTitle("Received from Mac")
                .setContentText("$name saved to Downloads/AndroMac").setAutoCancel(true).build()
            try { ctx.getSystemService(NotificationManager::class.java).notify(name.hashCode(), note) } catch (_: Exception) {}
        }

        /** Drop a half-received file, for example when the connection is lost. */
        fun abort() {
            val u = uri ?: return
            try { out?.close() } catch (_: Exception) {}
            try { ctx.contentResolver.delete(u, null, null) } catch (_: Exception) {}
            out = null; uri = null
        }
    }
}

package app.andromac

import android.content.Context
import android.database.ContentObserver
import android.net.Uri
import android.os.Build
import android.provider.ContactsContract
import android.provider.Telephony
import android.telephony.SmsManager
import org.json.JSONArray
import org.json.JSONObject

/** Text messages: conversation list, one conversation, sending. SMS only; MMS and RCS chats are not in this store. */
object Sms {
    private const val MAX_THREADS = 150
    private const val SCAN_ROWS = 4000

    /** Latest message of each conversation, newest conversation first. */
    fun threads(ctx: Context): JSONObject {
        val items = JSONArray()
        val seen = HashSet<Long>()
        val names = HashMap<String, String>()
        val cols = arrayOf(
            Telephony.Sms.THREAD_ID, Telephony.Sms.ADDRESS, Telephony.Sms.BODY,
            Telephony.Sms.DATE, Telephony.Sms.TYPE, Telephony.Sms.READ
        )
        ctx.contentResolver.query(Telephony.Sms.CONTENT_URI, cols, null, null, Telephony.Sms.DATE + " DESC")?.use { c ->
            var rows = 0
            while (c.moveToNext() && rows++ < SCAN_ROWS && items.length() < MAX_THREADS) {
                val thread = c.getLong(0)
                if (!seen.add(thread)) continue
                val address = c.getString(1) ?: ""
                items.put(JSONObject()
                    .put("id", thread)
                    .put("address", address)
                    .put("name", names.getOrPut(address) { contactName(ctx, address) })
                    .put("snippet", (c.getString(2) ?: "").take(200))
                    .put("ts", c.getLong(3))
                    .put("out", c.getInt(4) != Telephony.Sms.MESSAGE_TYPE_INBOX)
                    .put("unread", c.getInt(5) == 0))
            }
        }
        return Link.msg("sms_threads") { put("items", items) }
    }

    /** The most recent messages of one conversation, oldest first. */
    fun messages(ctx: Context, thread: Long, limit: Int): JSONObject {
        val rows = ArrayList<JSONObject>()
        val cols = arrayOf(Telephony.Sms._ID, Telephony.Sms.BODY, Telephony.Sms.DATE, Telephony.Sms.TYPE)
        ctx.contentResolver.query(
            Telephony.Sms.CONTENT_URI, cols, Telephony.Sms.THREAD_ID + " = ?", arrayOf(thread.toString()),
            Telephony.Sms.DATE + " DESC"
        )?.use { c ->
            while (c.moveToNext() && rows.size < limit) {
                rows += JSONObject().put("id", c.getLong(0)).put("body", c.getString(1) ?: "")
                    .put("ts", c.getLong(2)).put("out", c.getInt(3) != Telephony.Sms.MESSAGE_TYPE_INBOX)
            }
        }
        return Link.msg("sms") { put("thread", thread); put("items", JSONArray(rows.reversed())) }
    }

    fun send(ctx: Context, to: String, text: String) {
        require(to.isNotBlank() && text.isNotEmpty()) { "Message needs a number and some text" }
        @Suppress("DEPRECATION")
        val mgr = if (Build.VERSION.SDK_INT >= 31) ctx.getSystemService(SmsManager::class.java) else SmsManager.getDefault()
        val parts = mgr.divideMessage(text)
        if (parts.size > 1) mgr.sendMultipartTextMessage(to, null, parts, null, null)
        else mgr.sendTextMessage(to, null, text, null, null)
    }

    private fun contactName(ctx: Context, number: String): String {
        if (number.isEmpty()) return ""
        return try {
            val uri = Uri.withAppendedPath(ContactsContract.PhoneLookup.CONTENT_FILTER_URI, Uri.encode(number))
            ctx.contentResolver.query(uri, arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME), null, null, null)?.use { c ->
                if (c.moveToFirst()) c.getString(0) else null
            } ?: ""
        } catch (_: Exception) { "" } // contacts permission missing: show the number
    }

    /** Tells the Mac whenever a message arrives or is sent, so its open conversation stays current. */
    class Watcher(private val ctx: Context) : ContentObserver(Link.main) {
        private var registered = false
        private val notify = Runnable { if (Link.connected) Link.send(Link.msg("sms_changed")) }

        fun start() {
            if (registered) return
            try {
                ctx.contentResolver.registerContentObserver(Telephony.Sms.CONTENT_URI, true, this)
                registered = true
            } catch (_: Exception) {}
        }

        fun stop() {
            if (registered) try { ctx.contentResolver.unregisterContentObserver(this) } catch (_: Exception) {}
            registered = false
        }

        override fun onChange(selfChange: Boolean) {
            // One incoming text touches the store several times; send a single nudge.
            Link.main.removeCallbacks(notify)
            Link.main.postDelayed(notify, 400)
        }
    }
}

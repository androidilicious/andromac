package app.andromac

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.ClipboardManager
import android.content.Intent
import android.media.projection.MediaProjectionConfig
import android.media.projection.MediaProjectionManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.service.quicksettings.TileService
import android.widget.Toast

/**
 * Invisible activity with three jobs:
 *  - launched plainly (tile or app button): read the clipboard and send it. Android only lets the
 *    focused app read the clipboard, which is why this has to be an activity.
 *  - "Send to Mac" in the text-selection menu: send the selected text as clipboard.
 *  - share sheet: send shared text as clipboard, shared files as files.
 */
class SendActivity : Activity() {
    private var wantClipboard = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (!Link.connected) { toast("Not connected to your Mac"); finish(); return }
        when (intent.action) {
            Intent.ACTION_PROCESS_TEXT -> { sendText(intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)); finish() }
            Intent.ACTION_SEND, Intent.ACTION_SEND_MULTIPLE -> { share(); finish() }
            else -> wantClipboard = true
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!hasFocus || !wantClipboard) return
        wantClipboard = false
        val clip = getSystemService(ClipboardManager::class.java).primaryClip
        sendText(if (clip != null && clip.itemCount > 0) clip.getItemAt(0).coerceToText(this) else null)
        finish()
    }

    private fun sendText(text: CharSequence?) {
        if (text.isNullOrEmpty()) { toast("Nothing to send"); return }
        Link.send(Link.msg("clip") { put("text", text.toString()) })
        toast("Sent to Mac clipboard")
    }

    private fun share() {
        @Suppress("DEPRECATION")
        val uris: List<Uri> = when (intent.action) {
            Intent.ACTION_SEND_MULTIPLE -> intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM) ?: emptyList()
            else -> listOfNotNull(intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))
        }
        if (uris.isEmpty()) { sendText(intent.getCharSequenceExtra(Intent.EXTRA_TEXT)); return }
        // Open the streams now: our read permission on these URIs ends when this activity finishes.
        var count = 0
        for (u in uris) {
            val job = try { Media.open(this, u) } catch (_: Exception) { null } ?: continue
            Link.worker.execute { Media.sendStream(job) }
            count++
        }
        toast(if (count > 0) "Sending $count file${if (count > 1) "s" else ""} to Mac" else "Could not read that file")
    }

    private fun toast(s: String) = Toast.makeText(applicationContext, s, Toast.LENGTH_SHORT).show()
}

/** Quick Settings tile: one tap sends the current clipboard to the Mac. */
class ClipTile : TileService() {
    override fun onClick() {
        val i = Intent(this, SendActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (Build.VERSION.SDK_INT >= 34) {
            startActivityAndCollapse(PendingIntent.getActivity(this, 0, i, PendingIntent.FLAG_IMMUTABLE))
        } else {
            @Suppress("DEPRECATION", "StartActivityAndCollapseDeprecated")
            startActivityAndCollapse(i)
        }
    }
}

/** Shows Android's screen-capture consent dialog and hands the result to [LinkService]. */
class ProjectionActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val mgr = getSystemService(MediaProjectionManager::class.java)
        // Android 14+ offers "a single app" by default. Ask for the whole screen, which is what mirroring means here.
        val ask = if (Build.VERSION.SDK_INT >= 34) {
            mgr.createScreenCaptureIntent(MediaProjectionConfig.createConfigForDefaultDisplay())
        } else mgr.createScreenCaptureIntent()
        @Suppress("DEPRECATION")
        startActivityForResult(ask, 1)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (resultCode == RESULT_OK && data != null) {
            startForegroundService(
                Intent(this, LinkService::class.java).setAction(LinkService.ACTION_PROJECTION)
                    .putExtra("code", resultCode).putExtra("data", data)
            )
        } else {
            Link.error("Screen mirroring was declined on the phone")
        }
        finish()
    }
}

/** Restarts the link after the phone reboots or the app is updated. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(c: Context, intent: Intent) {
        if (!Link.paired(c)) return
        try { LinkService.start(c) } catch (e: Exception) { android.util.Log.w(Link.TAG, "start after boot refused: $e") }
    }
}

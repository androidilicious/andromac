package app.andromac

import android.app.Notification
import android.app.RemoteInput
import android.content.Intent
import android.os.Bundle
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log

/** Forwards phone notifications to the Mac and performs replies and dismissals coming back. */
class NotifService : NotificationListenerService() {
    override fun onListenerConnected() {
        instance = this
        Link.status()
        // The system binds this listener at boot and keeps it alive, so it doubles as a way to revive the link.
        if (Link.paired(this)) try { LinkService.start(this) } catch (_: Exception) {}
    }
    override fun onListenerDisconnected() { instance = null; Link.status() }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        if (!Link.connected || sbn.packageName == packageName || sbn.isOngoing) return
        val n = sbn.notification
        if (n.flags and Notification.FLAG_GROUP_SUMMARY != 0) return
        val title = n.extras.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: ""
        val text = n.extras.getCharSequence(Notification.EXTRA_TEXT)?.toString() ?: ""
        if (title.isEmpty() && text.isEmpty()) return
        Link.send(Link.msg("notif") {
            put("key", sbn.key)
            put("app", appLabel(sbn.packageName))
            put("pkg", sbn.packageName)
            put("title", title)
            put("text", text)
            put("ts", sbn.postTime)
            put("reply", replyAction(n) != null)
        })
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        if (Link.connected) Link.send(Link.msg("notif_gone") { put("key", sbn.key) })
    }

    private fun appLabel(pkg: String): String = try {
        packageManager.getApplicationLabel(packageManager.getApplicationInfo(pkg, 0)).toString()
    } catch (_: Exception) { pkg }

    private fun replyAction(n: Notification): Notification.Action? =
        n.actions?.firstOrNull { a -> a.remoteInputs?.any { it.allowFreeFormInput } == true }

    fun reply(key: String, text: String) {
        try {
            val sbn = activeNotifications.firstOrNull { it.key == key } ?: return Link.error("That notification is gone")
            val action = replyAction(sbn.notification) ?: return Link.error("That notification cannot be replied to")
            val results = Bundle()
            for (ri in action.remoteInputs) results.putCharSequence(ri.resultKey, text)
            val fill = Intent()
            RemoteInput.addResultsToIntent(action.remoteInputs, fill, results)
            action.actionIntent.send(this, 0, fill)
        } catch (e: Exception) {
            Log.w(Link.TAG, "reply failed", e); Link.error("Reply failed: ${e.message}")
        }
    }

    fun dismiss(key: String) { try { cancelNotification(key) } catch (_: Exception) {} }

    companion object { @Volatile var instance: NotifService? = null }
}

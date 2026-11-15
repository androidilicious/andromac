package app.andromac

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.os.Bundle
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import org.json.JSONObject

/** Injects taps, swipes, system keys and text sent from the Mac's mirror window. */
class InputService : AccessibilityService() {
    override fun onServiceConnected() { instance = this; Link.status() }
    override fun onDestroy() { instance = null; super.onDestroy() }
    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}
    override fun onInterrupt() {}

    /** Coordinates arrive normalised to 0..1 of the screen. */
    fun handle(j: JSONObject) {
        val b = getSystemService(WindowManager::class.java).maximumWindowMetrics.bounds
        fun px(key: String, size: Int) = (j.optDouble(key, 0.0).coerceIn(0.0, 1.0) * (size - 1)).toFloat()
        when (j.optString("k")) {
            "tap" -> stroke(px("x", b.width()), px("y", b.height()), null, null, 60)
            "swipe" -> stroke(
                px("x", b.width()), px("y", b.height()), px("x2", b.width()), px("y2", b.height()),
                j.optLong("ms", 200).coerceIn(40, 2000)
            )
            "key" -> when (j.optString("key")) {
                "back" -> performGlobalAction(GLOBAL_ACTION_BACK)
                "home" -> performGlobalAction(GLOBAL_ACTION_HOME)
                "recents" -> performGlobalAction(GLOBAL_ACTION_RECENTS)
                "notifications" -> performGlobalAction(GLOBAL_ACTION_NOTIFICATIONS)
                "del" -> edit { it.dropLast(1) }
                "enter" -> focused()?.performAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id)
            }
            "text" -> { val s = j.optString("text"); edit { it + s } }
        }
    }

    private fun stroke(x: Float, y: Float, x2: Float?, y2: Float?, ms: Long) {
        val path = Path().apply { moveTo(x, y); lineTo(x2 ?: x, y2 ?: y) }
        val g = GestureDescription.Builder()
            .addStroke(GestureDescription.StrokeDescription(path, 0, ms)).build()
        dispatchGesture(g, null, null)
    }

    private fun focused(): AccessibilityNodeInfo? = rootInActiveWindow?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)

    /** Typing works by rewriting the focused field's text, which is the reliable route without being the keyboard. */
    private fun edit(change: (String) -> String) {
        val node = focused() ?: return
        val current = if (node.isShowingHintText) "" else node.text?.toString() ?: ""
        val args = Bundle().apply {
            putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, change(current))
        }
        node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
    }

    companion object { @Volatile var instance: InputService? = null }
}

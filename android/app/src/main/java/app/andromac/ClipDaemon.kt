package app.andromac

import android.content.ClipData
import android.content.ClipDescription
import android.os.IBinder
import android.util.Base64
import java.lang.reflect.Method

/**
 * Watches the phone clipboard from the debugging shell and prints each new text as one base64 line.
 *
 * Android does not let an installed app read the clipboard in the background, which is why phone-to-Mac
 * clipboard otherwise needs a tap. The debugging shell is allowed to. So the Mac starts this class over adb:
 *
 *     CLASSPATH=<path of this APK> app_process / app.andromac.ClipDaemon
 *
 * and reads its output. It is not part of the running app: no Context, no Android lifecycle, only the
 * clipboard system service reached by reflection, because its method signatures differ between Android versions.
 */
object ClipDaemon {
    private const val SHELL = "com.android.shell"

    @JvmStatic
    fun main(args: Array<String>) {
        val service = try { clipboardService() } catch (e: Throwable) {
            System.err.println("clipboard service unavailable: $e"); return
        }
        val methods = service.javaClass.methods
        val getClip = methods.firstOrNull { it.name == "getPrimaryClip" }
        val getDescription = methods.firstOrNull { it.name == "getPrimaryClipDescription" }
        if (getClip == null) { System.err.println("no getPrimaryClip on this Android version"); return }

        println("READY")
        var lastStamp = Long.MIN_VALUE
        var lastText: String? = null
        var first = true
        while (!System.out.checkError()) { // the Mac went away: stop
            try {
                // The description is cheap and does not trigger Android's "pasted from clipboard" notice,
                // so poll that and read the content only when it changed.
                val stamp = (getDescription?.let { call(service, it) } as? ClipDescription)?.timestamp
                if (stamp == null || stamp != lastStamp || getDescription == null) {
                    if (stamp != null) lastStamp = stamp
                    val clip = call(service, getClip) as? ClipData
                    val text = if (clip != null && clip.itemCount > 0) clip.getItemAt(0).text?.toString() else null
                    if (!text.isNullOrEmpty() && text != lastText) {
                        lastText = text
                        // Whatever was already on the clipboard when the watch began is old news.
                        if (!first) println(Base64.encodeToString(text.toByteArray(Charsets.UTF_8), Base64.NO_WRAP))
                    }
                }
            } catch (e: Throwable) {
                System.err.println("clipboard read failed: ${e.cause ?: e}")
            }
            first = false
            Thread.sleep(if (getDescription == null) 1500 else 600)
        }
    }

    private fun clipboardService(): Any {
        val binder = Class.forName("android.os.ServiceManager")
            .getMethod("getService", String::class.java).invoke(null, "clipboard") as IBinder
        return Class.forName("android.content.IClipboard\$Stub")
            .getMethod("asInterface", IBinder::class.java).invoke(null, binder)!!
    }

    /** Fills in the arguments by type: (package, [attribution tag], [user id], [device id], ...). */
    private fun call(service: Any, m: Method): Any? {
        var strings = 0
        val args = m.parameterTypes.map { type ->
            when (type) {
                String::class.java -> if (strings++ == 0) SHELL else null
                Int::class.javaPrimitiveType -> 0 // user 0, default device
                Boolean::class.javaPrimitiveType -> false
                Long::class.javaPrimitiveType -> 0L
                else -> null
            }
        }
        return m.invoke(service, *args.toTypedArray())
    }
}

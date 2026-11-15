package app.andromac

import android.Manifest
import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ColorFilter
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.EditText
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.core.app.NotificationManagerCompat
import androidx.core.graphics.PathParser
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning

/** A 24x24 Material icon path drawn in one colour. Keeps the app free of image resources. */
private class PathIcon(data: String, private val color: Int) : Drawable() {
    private val source: Path = PathParser.createPathFromPathData(data)
    private val scaled = Path()
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = this@PathIcon.color }
    override fun draw(c: Canvas) {
        val m = Matrix().apply { setScale(bounds.width() / 24f, bounds.height() / 24f); postTranslate(bounds.left.toFloat(), bounds.top.toFloat()) }
        source.transform(m, scaled)
        c.drawPath(scaled, paint)
    }
    override fun setAlpha(alpha: Int) { paint.alpha = alpha }
    override fun setColorFilter(f: ColorFilter?) { paint.colorFilter = f }
    @Deprecated("Deprecated in Java") override fun getOpacity() = PixelFormat.TRANSLUCENT
}

private object Icons {
    const val LINK = "M3.9,12c0,-1.71 1.39,-3.1 3.1,-3.1h4V7H7c-2.76,0 -5,2.24 -5,5s2.24,5 5,5h4v-1.9H7c-1.71,0 -3.1,-1.39 -3.1,-3.1zM8,13h8v-2H8v2zM17,7h-4v1.9h4c1.71,0 3.1,1.39 3.1,3.1s-1.39,3.1 -3.1,3.1h-4V17h4c2.76,0 5,-2.24 5,-5s-2.24,-5 -5,-5z"
    const val CHECK = "M9,16.17L4.83,12l-1.42,1.41L9,19 21,7l-1.41,-1.41z"
    const val BELL = "M12,22c1.1,0 2,-0.9 2,-2h-4c0,1.1 0.89,2 2,2zM18,16v-5c0,-3.07 -1.64,-5.64 -4.5,-6.32V4c0,-0.83 -0.67,-1.5 -1.5,-1.5s-1.5,0.67 -1.5,1.5v0.68C7.63,5.36 6,7.92 6,11v5l-2,2v1h16v-1l-2,-2z"
    const val CLIPBOARD = "M19,2h-4.18C14.4,0.84 13.3,0 12,0c-1.3,0 -2.4,0.84 -2.82,2L5,2c-1.1,0 -2,0.9 -2,2v16c0,1.1 0.9,2 2,2h14c1.1,0 2,-0.9 2,-2L21,4c0,-1.1 -0.9,-2 -2,-2zM12,2c0.55,0 1,0.45 1,1s-0.45,1 -1,1 -1,-0.45 -1,-1 0.45,-1 1,-1zM19,20L5,20L5,4h2v3h10L17,4h2v16z"
    const val FILE = "M6,2c-1.1,0 -1.99,0.9 -1.99,2L4,20c0,1.1 0.89,2 1.99,2L18,22c1.1,0 2,-0.9 2,-2L20,8l-6,-6L6,2zM13,9L13,3.5L18.5,9L13,9z"
    const val SHIELD = "M12,1L3,5v6c0,5.55 3.84,10.74 9,12 5.16,-1.26 9,-6.45 9,-12L21,5l-9,-4z"
    const val MOUSE = "M13,1.07L13,9h7c0,-4.08 -3.05,-7.44 -7,-7.93zM4,15c0,4.42 3.58,8 8,8s8,-3.58 8,-8v-4L4,11v4zM11,1.07C7.05,1.56 4,4.92 4,9h7L11,1.07z"
    const val CHEVRON = "M10,6L8.59,7.41 13.17,12l-4.58,4.59L10,18l6,-6z"
    const val CAMERA = "M9,2L7.17,4L4,4c-1.1,0 -2,0.9 -2,2v12c0,1.1 0.9,2 2,2h16c1.1,0 2,-0.9 2,-2L22,6c0,-1.1 -0.9,-2 -2,-2h-3.17L15,2L9,2zM12,17c-2.76,0 -5,-2.24 -5,-5s2.24,-5 5,-5 5,2.24 5,5 -2.24,5 -5,5z"
    const val LAPTOP = "M20,18c1.1,0 1.99,-0.9 1.99,-2L22,6c0,-1.1 -0.9,-2 -2,-2H4c-1.1,0 -2,0.9 -2,2v10c0,1.1 0.9,2 2,2H0v2h24v-2h-4zM4,6h16v10H4V6z"
}

class MainActivity : Activity() {
    private lateinit var root: LinearLayout

    // Colours, picked once per screen build so light and dark both look deliberate.
    private var dark = false
    private val bg get() = if (dark) 0xFF0F1413.toInt() else 0xFFF3F6F5.toInt()
    private val card get() = if (dark) 0xFF1A2120.toInt() else 0xFFFFFFFF.toInt()
    private val ink get() = if (dark) 0xFFECF1EF.toInt() else 0xFF14201D.toInt()
    private val soft get() = if (dark) 0xFF9DAAA6.toInt() else 0xFF5F6F6A.toInt()
    private val line get() = if (dark) 0x22FFFFFF else 0x14000000
    private val brand = 0xFF179E87.toInt()
    private val brandDeep = 0xFF0D6B8C.toInt()
    private val warn = 0xFFE08A1E.toInt()
    private val danger = 0xFFD64545.toInt()

    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        dark = resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
        window.statusBarColor = bg
        window.navigationBarColor = bg
        @Suppress("DEPRECATION")
        window.decorView.systemUiVisibility =
            if (dark) 0 else View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR or View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR
        root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(18), dp(14), dp(18), dp(28)) }
        setContentView(ScrollView(this).apply { setBackgroundColor(bg); isFillViewport = true; addView(root) })
    }

    override fun onResume() {
        super.onResume()
        Link.onStatus = { refresh() }
        if (Link.paired(this)) LinkService.start(this)
        refresh()
    }

    override fun onPause() { Link.onStatus = null; super.onPause() }

    @Deprecated("Deprecated in Java")
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) = refresh()

    // ---- screen ----

    /** Rebuilds the screen from the current state. It is small, so rebuilding is simpler than patching views. */
    private fun refresh() {
        root.removeAllViews()
        val paired = Link.paired(this)
        val mac = Link.peerName ?: Link.prefs(this).getString("name", "your Mac") ?: "your Mac"

        root.addView(text("AndroMac", 15f, soft, bold = true).apply { setPadding(dp(4), 0, 0, dp(10)) })
        root.addView(hero(
            icon = if (Link.connected) Icons.LAPTOP else Icons.LINK,
            title = when { !paired -> "Link this phone to your Mac"; Link.connected -> mac; else -> "Looking for $mac" },
            subtitle = when {
                !paired -> "Open AndroMac on the Mac, then scan the code it shows."
                Link.connected -> "Connected over Wi-Fi"
                else -> "Make sure both are on the same Wi-Fi and AndroMac is open on the Mac."
            },
            live = Link.connected
        ))

        if (!paired) {
            root.addView(primaryButton("Scan the QR code on your Mac", Icons.CAMERA) { scan() }, gap(16))
            root.addView(linkButton("Paste a pairing link instead", brand) { pastePairing() }, gap(4))
            return
        }

        root.addView(section("Set up"))
        val notifOn = NotificationManagerCompat.getEnabledListenerPackages(this).contains(packageName)
        root.addView(cardOf(
            row(Icons.SHIELD, "Permissions", "Messages, photos, contacts, camera", permissionsGranted()) { askPermissions() },
            row(Icons.BELL, "Notification sync", "Show this phone's notifications on the Mac", notifOn) {
                startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
            },
            row(Icons.MOUSE, "Remote control", "Click and type on the cast screen", InputService.instance != null) {
                startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
            }
        ))

        root.addView(section("Send to Mac"))
        root.addView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            addView(tile(Icons.CLIPBOARD, "Clipboard") { startActivity(Intent(this@MainActivity, SendActivity::class.java)) },
                LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply { marginEnd = dp(6) })
            addView(tile(Icons.FILE, "Files") { pickFile() },
                LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply { marginStart = dp(6) })
        })
        root.addView(text("You can also pick Send to Mac from any app's Share menu, or add the Clipboard to Mac tile to Quick Settings.",
            13f, soft).apply { setPadding(dp(4), dp(12), dp(4), 0) })

        root.addView(linkButton("Scan a new code", brand) { scan() }, gap(22))
        root.addView(linkButton("Disconnect and forget this Mac", danger) { confirmForget() }, gap(0))
    }

    private fun permissionsGranted(): Boolean {
        val wanted = mutableListOf(Manifest.permission.READ_CONTACTS, Manifest.permission.CAMERA,
            Manifest.permission.READ_SMS, Manifest.permission.SEND_SMS)
        wanted += if (Build.VERSION.SDK_INT >= 33) Manifest.permission.READ_MEDIA_IMAGES else Manifest.permission.READ_EXTERNAL_STORAGE
        return wanted.all { checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }
    }

    private fun confirmForget() {
        AlertDialog.Builder(this).setTitle("Forget this Mac?")
            .setMessage("The phone stops linking until you scan a code again.")
            .setPositiveButton("Forget") { _, _ -> forget() }.setNegativeButton("Cancel", null).show()
    }

    // ---- building blocks ----

    private fun gap(top: Int) = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
        .apply { topMargin = dp(top) }

    private fun text(s: String, size: Float, color: Int, bold: Boolean = false) = TextView(this).apply {
        text = s; textSize = size; setTextColor(color)
        if (bold) typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
    }

    private fun rounded(color: Int, radius: Int, stroke: Int? = null) = GradientDrawable().apply {
        setColor(color); cornerRadius = dp(radius).toFloat()
        if (stroke != null) setStroke(dp(1), stroke)
    }

    private fun tappable(shape: GradientDrawable): Drawable =
        RippleDrawable(ColorStateList.valueOf(if (dark) 0x33FFFFFF else 0x1F000000), shape, shape)

    private fun icon(data: String, color: Int, size: Int) = ImageView(this).apply {
        setImageDrawable(PathIcon(data, color))
        layoutParams = LinearLayout.LayoutParams(dp(size), dp(size))
    }

    private fun hero(icon: String, title: String, subtitle: String, live: Boolean): View = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(22), dp(22), dp(22), dp(24))
        background = GradientDrawable(GradientDrawable.Orientation.TL_BR,
            if (live) intArrayOf(brand, brandDeep) else intArrayOf(0xFF4B5A57.toInt(), 0xFF2F3B39.toInt()))
            .apply { cornerRadius = dp(26).toFloat() }
        addView(LinearLayout(this@MainActivity).apply {
            gravity = Gravity.CENTER
            background = rounded(0x33FFFFFF, 16)
            layoutParams = LinearLayout.LayoutParams(dp(52), dp(52))
            addView(icon(icon, Color.WHITE, 28))
        })
        addView(text(title, 24f, Color.WHITE, bold = true).apply { setPadding(0, dp(16), 0, dp(4)) })
        addView(LinearLayout(this@MainActivity).apply {
            gravity = Gravity.CENTER_VERTICAL
            if (live) addView(View(this@MainActivity).apply {
                background = rounded(0xFF7CF2C3.toInt(), 5)
                layoutParams = LinearLayout.LayoutParams(dp(8), dp(8)).apply { marginEnd = dp(8) }
            })
            addView(text(subtitle, 15f, 0xDDFFFFFF.toInt()))
        })
    }

    private fun section(title: String) = text(title.uppercase(), 12f, soft, bold = true).apply {
        letterSpacing = 0.08f
        setPadding(dp(6), dp(26), 0, dp(8))
    }

    private fun cardOf(vararg rows: View): View = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        background = rounded(card, 20, line)
        clipToOutline = true
        rows.forEachIndexed { i, r ->
            if (i > 0) addView(View(this@MainActivity).apply { setBackgroundColor(line) },
                LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(1)).apply { marginStart = dp(66) })
            addView(r)
        }
    }

    private fun row(icon: String, title: String, subtitle: String, on: Boolean, action: () -> Unit): View = LinearLayout(this).apply {
        gravity = Gravity.CENTER_VERTICAL
        setPadding(dp(14), dp(14), dp(14), dp(14))
        background = tappable(rounded(Color.TRANSPARENT, 0))
        setOnClickListener { action() }
        addView(LinearLayout(this@MainActivity).apply {
            gravity = Gravity.CENTER
            background = rounded(if (on) 0x22179E87 else if (dark) 0x22FFFFFF else 0x12000000, 12)
            layoutParams = LinearLayout.LayoutParams(dp(40), dp(40))
            addView(icon(icon, if (on) brand else soft, 22))
        })
        addView(LinearLayout(this@MainActivity).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(12), 0, dp(8), 0)
            addView(text(title, 16f, ink, bold = true))
            addView(text(subtitle, 13f, soft))
        }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        if (on) {
            addView(icon(Icons.CHECK, brand, 22))
        } else {
            addView(text("Turn on", 13f, warn, bold = true).apply {
                background = rounded(0x22E08A1E, 12); setPadding(dp(10), dp(5), dp(10), dp(5))
            })
            addView(icon(Icons.CHEVRON, soft, 20))
        }
    }

    private fun tile(icon: String, label: String, action: () -> Unit): View = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(16), dp(18), dp(16), dp(18))
        background = tappable(rounded(card, 20, line))
        setOnClickListener { action() }
        addView(icon(icon, brand, 26))
        addView(text(label, 16f, ink, bold = true).apply { setPadding(0, dp(12), 0, 0) })
    }

    private fun primaryButton(label: String, icon: String, action: () -> Unit): View = LinearLayout(this).apply {
        gravity = Gravity.CENTER
        setPadding(dp(18), dp(16), dp(18), dp(16))
        background = tappable(rounded(brand, 18))
        setOnClickListener { action() }
        addView(icon(icon, Color.WHITE, 22))
        addView(text(label, 16f, Color.WHITE, bold = true).apply { setPadding(dp(10), 0, 0, 0) })
    }

    private fun linkButton(label: String, color: Int, action: () -> Unit): View = text(label, 15f, color, bold = true).apply {
        gravity = Gravity.CENTER
        setPadding(dp(12), dp(14), dp(12), dp(14))
        background = tappable(rounded(Color.TRANSPARENT, 14))
        setOnClickListener { action() }
    }

    // ---- actions ----

    private fun scan() {
        GmsBarcodeScanning.getClient(this).startScan()
            .addOnSuccessListener { code -> pair(code.rawValue ?: "") }
            .addOnFailureListener { e -> toast("Scanner unavailable: ${e.message}") }
    }

    private fun pastePairing() {
        val input = EditText(this).apply { hint = "andromac://pair?..." }
        AlertDialog.Builder(this).setTitle("Pairing link").setView(input)
            .setPositiveButton("Pair") { _, _ -> pair(input.text.toString()) }
            .setNegativeButton("Cancel", null).show()
    }

    private fun pair(text: String) {
        if (Link.savePairing(this, text)) {
            // Restart the service so it picks up the new pairing.
            startService(Intent(this, LinkService::class.java).setAction(LinkService.ACTION_STOP))
            root.postDelayed({ LinkService.start(this); refresh() }, 500)
            toast("Paired")
        } else toast("That is not an AndroMac pairing code")
        refresh()
    }

    private fun forget() {
        startService(Intent(this, LinkService::class.java).setAction(LinkService.ACTION_STOP))
        Link.prefs(this).edit().clear().apply()
        refresh()
    }

    private fun askPermissions() {
        val wanted = mutableListOf(
            Manifest.permission.READ_CONTACTS, Manifest.permission.CAMERA,
            Manifest.permission.READ_SMS, Manifest.permission.SEND_SMS
        )
        if (Build.VERSION.SDK_INT >= 33) {
            wanted += Manifest.permission.POST_NOTIFICATIONS
            wanted += Manifest.permission.READ_MEDIA_IMAGES
        } else wanted += Manifest.permission.READ_EXTERNAL_STORAGE
        requestPermissions(wanted.toTypedArray(), 1)
    }

    private fun pickFile() {
        if (!Link.connected) { toast("Not connected to your Mac"); return }
        @Suppress("DEPRECATION")
        startActivityForResult(
            Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*")
                .putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true), 2
        )
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != 2 || resultCode != RESULT_OK || data == null) return
        val uris = mutableListOf<Uri>()
        data.data?.let { uris += it }
        data.clipData?.let { c -> for (i in 0 until c.itemCount) uris += c.getItemAt(i).uri }
        for (u in uris) {
            val job = try { Media.open(this, u) } catch (_: Exception) { null } ?: continue
            Link.worker.execute { Media.sendStream(job) }
        }
        toast("Sending ${uris.size} file${if (uris.size > 1) "s" else ""}")
    }

    private fun toast(s: String) = Toast.makeText(this, s, Toast.LENGTH_SHORT).show()
}

package app.andromac

import android.annotation.SuppressLint
import android.content.Context
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.projection.MediaProjection
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import android.view.WindowManager
import java.nio.ByteBuffer

/**
 * H.264 hardware encoder fed by a Surface. Each encoded buffer is sent as one frame:
 * flags(1) + pts in microseconds(8) + Annex B data. flags bit0 = SPS/PPS, bit1 = keyframe.
 */
class VideoEncoder(width: Int, height: Int, bitrate: Int, private val frameType: Int) {
    private val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
    val surface: Surface
    @Volatile private var running = true
    private val thread: Thread

    init {
        val f = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height)
        f.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
        f.setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
        f.setInteger(MediaFormat.KEY_FRAME_RATE, 30)
        f.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2)
        // Keep emitting frames while the picture is static, so a new viewer is never left on a blank window.
        f.setLong(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER, 200_000L)
        codec.configure(f, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        surface = codec.createInputSurface()
        codec.start()
        thread = Thread({ drain() }, "andromac-enc-$frameType").also { it.start() }
    }

    private fun drain() {
        val info = MediaCodec.BufferInfo()
        try {
            while (running) {
                val i = codec.dequeueOutputBuffer(info, 100_000)
                if (i < 0) continue
                val buf = codec.getOutputBuffer(i)
                if (buf != null && info.size > 0) {
                    val data = ByteArray(info.size)
                    buf.position(info.offset); buf.get(data)
                    var flags = 0
                    if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) flags = flags or 1
                    if (info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0) flags = flags or 2
                    val head = ByteBuffer.allocate(9).put(flags.toByte()).putLong(info.presentationTimeUs).array()
                    if (!Link.sendNow(frameType, head, data)) running = false
                }
                codec.releaseOutputBuffer(i, false)
            }
        } catch (e: Exception) {
            Log.w(Link.TAG, "encoder stopped: $e")
        }
    }

    fun requestKeyframe() {
        try { codec.setParameters(Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0) }) } catch (_: Exception) {}
    }

    fun stop() {
        running = false
        try { thread.join(500) } catch (_: Exception) {}
        try { codec.stop() } catch (_: Exception) {}
        try { codec.release() } catch (_: Exception) {}
        try { surface.release() } catch (_: Exception) {}
    }
}

/** Captures the screen through MediaProjection into a [VideoEncoder]. */
class ScreenStreamer(ctx: Context, private val mp: MediaProjection, max: Int, bitrate: Int, onStopped: () -> Unit) {
    private val enc: VideoEncoder
    private var display: VirtualDisplay? = null
    private var stopped = false

    init {
        val b = ctx.getSystemService(WindowManager::class.java).maximumWindowMetrics.bounds
        val scale = minOf(1f, max.toFloat() / maxOf(b.width(), b.height()))
        val w = (b.width() * scale).toInt() and 7.inv()
        val h = (b.height() * scale).toInt() and 7.inv()
        enc = VideoEncoder(w, h, bitrate, T.SCREEN)
        // Android 14+ requires a callback to be registered before the virtual display is created.
        mp.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() { if (!stopped) onStopped() }
        }, Link.main)
        display = mp.createVirtualDisplay(
            "AndroMac", w, h, ctx.resources.displayMetrics.densityDpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, enc.surface, null, null
        )
        Link.send(Link.msg("mirror_info") { put("w", w); put("h", h) })
    }

    fun requestKeyframe() = enc.requestKeyframe()

    fun stop() {
        if (stopped) return
        stopped = true
        try { display?.release() } catch (_: Exception) {}
        enc.stop()
        try { mp.stop() } catch (_: Exception) {}
    }
}

/** Streams the phone camera at 1280x720 into a [VideoEncoder]. Hold the phone in landscape. */
class CameraStreamer(ctx: Context, front: Boolean) {
    private val enc = VideoEncoder(1280, 720, 4_000_000, T.CAMERA)
    private val thread = HandlerThread("andromac-cam").also { it.start() }
    private val handler = Handler(thread.looper)
    private var device: CameraDevice? = null
    private var session: CameraCaptureSession? = null

    init { open(ctx, front) }

    @SuppressLint("MissingPermission")
    private fun open(ctx: Context, front: Boolean) {
        val mgr = ctx.getSystemService(CameraManager::class.java)
        val want = if (front) CameraCharacteristics.LENS_FACING_FRONT else CameraCharacteristics.LENS_FACING_BACK
        val id = mgr.cameraIdList.firstOrNull {
            mgr.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING) == want
        } ?: mgr.cameraIdList.first()
        mgr.openCamera(id, object : CameraDevice.StateCallback() {
            override fun onOpened(cam: CameraDevice) {
                device = cam
                try {
                    @Suppress("DEPRECATION")
                    cam.createCaptureSession(listOf(enc.surface), object : CameraCaptureSession.StateCallback() {
                        override fun onConfigured(s: CameraCaptureSession) {
                            session = s
                            try {
                                val req = cam.createCaptureRequest(CameraDevice.TEMPLATE_RECORD)
                                req.addTarget(enc.surface)
                                s.setRepeatingRequest(req.build(), null, handler)
                            } catch (e: Exception) { Link.error("Camera stream failed: ${e.message}") }
                        }
                        override fun onConfigureFailed(s: CameraCaptureSession) { Link.error("Camera could not be configured") }
                    }, handler)
                } catch (e: Exception) { Link.error("Camera session failed: ${e.message}") }
            }
            override fun onDisconnected(cam: CameraDevice) { cam.close() }
            override fun onError(cam: CameraDevice, error: Int) { cam.close(); Link.error("Camera error $error") }
        }, handler)
    }

    fun requestKeyframe() = enc.requestKeyframe()

    fun stop() {
        try { session?.close() } catch (_: Exception) {}
        try { device?.close() } catch (_: Exception) {}
        enc.stop()
        thread.quitSafely()
    }
}

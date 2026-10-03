package com.redmimirroring.companion

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Point
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.media.projection.MediaProjection
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.view.Surface
import android.view.WindowManager
import java.nio.ByteBuffer
import org.json.JSONObject
import kotlin.math.max
import kotlin.math.min

class ScreenCapture(private val context: Context, private val projection: MediaProjection, private val server: MirrorServer, private val withAudio: Boolean, private val stopped: () -> Unit) {
    private val thread = HandlerThread("Mirror hardware encoder").apply { start() }
    private val handler = Handler(thread.looper)
    @Volatile var active = false; private set
    @Volatile var width = 0; private set
    @Volatile var height = 0; private set
    @Volatile var fps = 60; private set
    @Volatile var fullDisplay = true; private set
    @Volatile var audioActive = false; private set
    @Volatile var encoderName = ""; private set
    @Volatile var latencyHintApplied = false; private set
    @Volatile var actualLatencyFrames: Int? = null; private set
    private var statsWindowPhoneMs = 0.0
    private var statsFrameCount = 0
    private var statsAgeTotal = 0.0
    private var statsAgeMax = 0.0
    private var bitrate = 8_000_000
    private var maxDimension = 1920
    private var sourceWidth = 0
    private var sourceHeight = 0
    private var codec: MediaCodec? = null
    private var surface: Surface? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var recorder: AudioRecord? = null
    private var finishing = false
    private var lastKeyRequest = 0L
    private val displayManager = context.getSystemService(DisplayManager::class.java)
    private val displayListener = object : DisplayManager.DisplayListener {
        override fun onDisplayAdded(id: Int) {}
        override fun onDisplayRemoved(id: Int) {}
        override fun onDisplayChanged(id: Int) {
            if (Build.VERSION.SDK_INT < 34 && active) { val p = displaySize(); resize(p.x, p.y) }
        }
    }
    private val callback = object : MediaProjection.Callback() {
        override fun onStop() { stop(false) }
        override fun onCapturedContentResize(w: Int, h: Int) { if (w > 0 && h > 0 && (w != sourceWidth || h != sourceHeight)) resize(w, h) }
    }

    fun start() {
        handler.post {
            try {
                val size = displaySize(); sourceWidth = size.x; sourceHeight = size.y
                active = true
                projection.registerCallback(callback, handler)
                displayManager.registerDisplayListener(displayListener, handler)
                createEncoder()
                // Android 14+: exactly one createVirtualDisplay per consent token. Resize the existing display later.
                virtualDisplay = projection.createVirtualDisplay("Redmi Mirroring", width, height, context.resources.displayMetrics.densityDpi,
                    DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, surface, null, handler)
                if (withAudio && context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) startAudio()
                server.ready()
                MirrorState.update("Screen sharing is active")
            } catch (e: Exception) {
                server.message("captureStopped", "Screen capture could not start. Approve sharing again on the phone.")
                MirrorState.update("Screen sharing failed: ${e.javaClass.simpleName}")
                stop(true)
            }
        }
    }
    private fun displaySize(): Point {
        val manager = context.getSystemService(WindowManager::class.java)
        if (Build.VERSION.SDK_INT >= 30) return manager.maximumWindowMetrics.bounds.let { Point(it.width(), it.height()) }
        return Point().apply { @Suppress("DEPRECATION") manager.defaultDisplay.getRealSize(this) }
    }
    private fun resize(w: Int, h: Int) {
        handler.post {
            if (!active || finishing || (w == sourceWidth && h == sourceHeight)) return@post
            sourceWidth = w; sourceHeight = h
            val actual = displaySize()
            fullDisplay = w == actual.x && h == actual.y
            rebuildEncoder()
        }
    }
    fun quality(newBitrate: Int, newFps: Int, newDimension: Int) {
        handler.post {
            val dimension = newDimension.coerceIn(640, 2560)
            val rate = newFps.coerceIn(15, 60)
            val changed = dimension != maxDimension || rate != fps
            bitrate = newBitrate.coerceIn(1_000_000, 20_000_000)
            maxDimension = dimension
            if (changed && active) { fps = rate; rebuildEncoder() }
            else runCatching { codec?.setParameters(Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_VIDEO_BITRATE, bitrate) }) }
        }
    }
    private fun rebuildEncoder() {
        try {
            val previous = codec
            val previousSurface = surface
            // Pause the producer before changing geometry. Some vendor display
            // pipelines retain the old crop when resized while an old encoder
            // surface is still attached.
            virtualDisplay?.surface = null
            codec = null
            surface = null
            runCatching { previous?.stop() }; runCatching { previous?.release() }; previousSurface?.release()
            createEncoder(startImmediately = false)
            virtualDisplay?.resize(width, height, context.resources.displayMetrics.densityDpi)
            virtualDisplay?.surface = surface
            codec?.start()
            server.ready()
        } catch (_: Exception) { server.message("captureStopped", "Capture configuration failed. Start sharing again on your phone."); stop(true) }
    }
    private fun createEncoder(startImmediately: Boolean = true, requestLatency: Boolean = true) {
        val encoders = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.filter {
            it.isEncoder && it.isHardwareAccelerated && it.supportedTypes.any { type -> type.equals(MediaFormat.MIMETYPE_VIDEO_AVC, true) }
        }
        check(encoders.isNotEmpty()) { "No hardware H.264 encoder" }
        var chosen: MediaCodecInfo? = null
        val scale = min(1.0, maxDimension.toDouble() / max(sourceWidth, sourceHeight))
        for (info in encoders) {
            val caps = info.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_AVC)
            if (!caps.colorFormats.contains(MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)) continue
            val video = caps.videoCapabilities ?: continue
            val w = max(video.widthAlignment, (sourceWidth * scale).toInt() / video.widthAlignment * video.widthAlignment)
            val h = max(video.heightAlignment, (sourceHeight * scale).toInt() / video.heightAlignment * video.heightAlignment)
            if (!video.isSizeSupported(w, h)) continue
            width = w; height = h
            fps = min(fps, video.getSupportedFrameRatesFor(w, h).upper.toInt()).coerceAtLeast(15)
            bitrate = bitrate.coerceIn(video.bitrateRange.lower, video.bitrateRange.upper)
            chosen = info; break
        }
        check(chosen != null) { "No hardware encoder supports this display size" }
        val encoder = MediaCodec.createByCodecName(chosen.name)
        encoderName = chosen.name
        latencyHintApplied = requestLatency
        actualLatencyFrames = null
        codec = encoder
        encoder.setCallback(object : MediaCodec.Callback() {
            override fun onInputBufferAvailable(codec: MediaCodec, index: Int) {}
            override fun onOutputBufferAvailable(sender: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
                if (codec !== sender) { runCatching { sender.releaseOutputBuffer(index, false) }; return }
                val callbackPhoneMs = InputTrace.now()
                try {
                    val output = sender.getOutputBuffer(index)
                    if (output != null && info.size > 0) {
                        output.position(info.offset); output.limit(info.offset + info.size)
                        val bytes = ByteArray(info.size); output.get(bytes)
                        if ((info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) server.config(annexB(bytes))
                        else {
                            encodedTiming(info.presentationTimeUs, callbackPhoneMs)
                            server.video(info.presentationTimeUs, annexB(bytes), (info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0)
                        }
                    }
                } finally { runCatching { sender.releaseOutputBuffer(index, false) } }
            }
            override fun onError(sender: MediaCodec, error: MediaCodec.CodecException) {
                if (codec === sender) { server.message("captureStopped", "Hardware encoder stopped. Start sharing again on the phone."); stop(true) }
            }
            override fun onOutputFormatChanged(sender: MediaCodec, format: MediaFormat) {
                if (codec !== sender) return
                actualLatencyFrames = if (format.containsKey(MediaFormat.KEY_LATENCY)) runCatching { format.getInteger(MediaFormat.KEY_LATENCY) }.getOrNull() else null
                val sps = format.getByteBuffer("csd-0")?.copyBytes() ?: ByteArray(0)
                val pps = format.getByteBuffer("csd-1")?.copyBytes() ?: ByteArray(0)
                server.config(annexB(sps) + annexB(pps))
                server.ready()
            }
        }, handler)
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
            setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            setFloat(MediaFormat.KEY_MAX_FPS_TO_ENCODER, fps.toFloat())
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            setInteger(MediaFormat.KEY_PRIORITY, 0)
            setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
            setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.AVCProfileBaseline)
            if (requestLatency) setInteger(MediaFormat.KEY_LATENCY, 1)
        }
        try { encoder.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE) }
        catch (error: Exception) {
            codec = null
            runCatching { encoder.release() }
            if (!requestLatency) throw error
            // Optional vendor rejection: a fresh codec retries without the hint.
            // Projection and its one virtual display are neither recreated nor reused.
            createEncoder(startImmediately, requestLatency = false)
            return
        }
        surface = encoder.createInputSurface()
        if (startImmediately) encoder.start()
    }
    private fun encodedTiming(ptsUs: Long, callbackPhoneMs: Double) {
        if (!server.wantsStreamStats()) {
            statsWindowPhoneMs = callbackPhoneMs; statsFrameCount = 0; statsAgeTotal = 0.0; statsAgeMax = 0.0
            return
        }
        val age = callbackPhoneMs - ptsUs / 1000.0
        if (age in 0.0..10_000.0) {
            statsFrameCount++; statsAgeTotal += age; statsAgeMax = max(statsAgeMax, age)
        }
        if (callbackPhoneMs - statsWindowPhoneMs < 1000 || statsFrameCount == 0) return
        server.streamStats(JSONObject().put("type", "streamStats").put("phoneTime", callbackPhoneMs)
            .put("encoder", encoderName).put("configuredFps", fps).put("encodedFrames", statsFrameCount)
            .put("encodedPtsAgeMeanMs", statsAgeTotal / statsFrameCount).put("encodedPtsAgeMaxMs", statsAgeMax)
            .put("requestedLatencyFrames", 1).put("latencyHintApplied", latencyHintApplied)
            .apply { actualLatencyFrames?.let { put("actualLatencyFrames", it) } })
        statsWindowPhoneMs = callbackPhoneMs; statsFrameCount = 0; statsAgeTotal = 0.0; statsAgeMax = 0.0
    }
    fun requestKeyframe() {
        handler.post {
            val now = SystemClock.elapsedRealtime()
            if (now - lastKeyRequest < 150) return@post
            lastKeyRequest = now
            runCatching { codec?.setParameters(Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0) }) }
        }
    }
    private fun startAudio() {
        try {
            val config = AudioPlaybackCaptureConfiguration.Builder(projection)
                .addMatchingUsage(AudioAttributes.USAGE_MEDIA).addMatchingUsage(AudioAttributes.USAGE_GAME).addMatchingUsage(AudioAttributes.USAGE_UNKNOWN).build()
            val size = max(9600, AudioRecord.getMinBufferSize(48000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT))
            val audio = AudioRecord.Builder().setAudioFormat(AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT).setSampleRate(48000).setChannelMask(AudioFormat.CHANNEL_IN_MONO).build())
                .setBufferSizeInBytes(size).setAudioPlaybackCaptureConfig(config).build()
            check(audio.state == AudioRecord.STATE_INITIALIZED)
            recorder = audio; audio.startRecording(); audioActive = true
            Thread({
                val buffer = ByteArray(1920)
                try {
                    while (active && audioActive) {
                        val count = audio.read(buffer, 0, buffer.size, AudioRecord.READ_BLOCKING)
                        if (count < 0) break
                        if (count > 0) server.audio(SystemClock.elapsedRealtimeNanos() / 1000, buffer.copyOf(count))
                    }
                } catch (_: Exception) {} finally { audioActive = false; server.ready() }
            }, "Mirror playback audio").start()
        } catch (_: Exception) { audioActive = false; server.message("info", "Playback audio is unavailable; video continues.") }
    }
    fun stop(stopProjection: Boolean = true) {
        handler.post {
            if (finishing) return@post
            finishing = true; active = false; audioActive = false
            runCatching { recorder?.stop() }; runCatching { recorder?.release() }; recorder = null
            runCatching { virtualDisplay?.release() }; virtualDisplay = null
            val old = codec; codec = null
            runCatching { old?.stop() }; runCatching { old?.release() }
            surface?.release(); surface = null
            runCatching { projection.unregisterCallback(callback) }
            runCatching { displayManager.unregisterDisplayListener(displayListener) }
            if (stopProjection) runCatching { projection.stop() }
            server.message("captureStopped", "Approve screen sharing on your phone to resume.")
            server.ready()
            MirrorState.main.post { stopped() }
            thread.quitSafely()
        }
    }
    private fun ByteBuffer.copyBytes(): ByteArray = duplicate().let { copy -> ByteArray(copy.remaining()).also { copy.get(it) } }
    private fun annexB(bytes: ByteArray): ByteArray {
        if (bytes.size >= 3 && bytes[0] == 0.toByte() && bytes[1] == 0.toByte() && (bytes[2] == 1.toByte() || (bytes.size >= 4 && bytes[2] == 0.toByte() && bytes[3] == 1.toByte()))) return bytes
        if (bytes.isEmpty()) return bytes
        val output = java.io.ByteArrayOutputStream()
        var at = 0
        while (at + 4 <= bytes.size) {
            val length = ByteBuffer.wrap(bytes, at, 4).int
            if (length < 1 || at + 4 + length > bytes.size) return byteArrayOf(0, 0, 0, 1) + bytes
            output.write(byteArrayOf(0, 0, 0, 1)); output.write(bytes, at + 4, length); at += 4 + length
        }
        return if (at == bytes.size) output.toByteArray() else byteArrayOf(0, 0, 0, 1) + bytes
    }
}

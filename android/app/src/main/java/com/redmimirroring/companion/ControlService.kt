package com.redmimirroring.companion

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.AccessibilityServiceInfo
import android.accessibilityservice.GestureDescription
import android.accessibilityservice.InputMethod
import android.app.KeyguardManager
import android.graphics.Path
import android.graphics.Point
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.view.KeyEvent
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import org.json.JSONObject
import kotlin.math.abs
import java.util.UUID

class ControlService : AccessibilityService() {
    companion object { @Volatile var current: ControlService? = null; private set }
    private val inputHandler = Handler(Looper.getMainLooper())
    private var pointer: LivePointer? = null
    private var queuedPointer: LivePointer? = null
    private var pointerWatchdogRunning = false
    private class LivePointer(val owner: String, val id: String, var seq: Long, val size: Point,
                              val permitted: () -> Boolean, x: Float, y: Float, trace: InputTrace?) {
        var stroke: GestureDescription.StrokeDescription? = null
        var x = x; var y = y
        var targetX = x; var targetY = y
        var lastMessage = SystemClock.uptimeMillis()
        var dispatchTime = 0L
        var inFlight = false
        var ending = false
        var cancelling = false
        var pendingTrace = trace
    }
    private val pointerWatchdog = object : Runnable {
        override fun run() {
            pointerWatchdogRunning = false
            val active = pointer ?: return
            val now = SystemClock.uptimeMillis()
            val screen = displaySize()
            if (!active.permitted() || getSystemService(KeyguardManager::class.java).isDeviceLocked ||
                !getSystemService(PowerManager::class.java).isInteractive ||
                MirrorState.service?.capture?.active != true || MirrorState.service?.capture?.fullDisplay == false ||
                screen.x != active.size.x || screen.y != active.size.y || now - active.lastMessage > 1250) {
                cancelPointer(active.owner)
            }
            // Recover an absent callback by explicitly ending the continued stroke.
            // This creates no new touchdown, and Android rejects/cancels an invalid continuation.
            if (active.inFlight && now - active.dispatchTime > 350) {
                if (active.stroke?.willContinue() != true) finishPointer(active)
                else {
                    active.inFlight = false; active.ending = true; active.cancelling = true
                    active.targetX = active.x; active.targetY = active.y
                    pumpPointer(active)
                }
            }
            startPointerWatchdog()
        }
    }
    override fun onServiceConnected() {
        super.onServiceConnected(); current = this
        if (Build.VERSION.SDK_INT >= 33) serviceInfo = serviceInfo.apply { flags = flags or AccessibilityServiceInfo.FLAG_INPUT_METHOD_EDITOR }
        MirrorState.service?.server?.ready(); MirrorState.update()
    }
    override fun onCreateInputMethod(): InputMethod = InputMethod(this)
    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}
    override fun onInterrupt() { cancelPointer() }
    override fun onDestroy() {
        cancelPointer(); queuedPointer = null; inputHandler.removeCallbacks(pointerWatchdog)
        current = null; MirrorState.service?.server?.ready(); MirrorState.update(); super.onDestroy()
    }

    fun handle(command: JSONObject, owner: String = "legacy", trace: InputTrace? = null, permitted: () -> Boolean = { true }): String? {
        if (!permitted()) { cancelPointer(owner); return "This control session ended." }
        if (getSystemService(KeyguardManager::class.java).isDeviceLocked) { cancelPointer(); return "Unlock the phone to control it." }
        if (MirrorState.service?.capture?.fullDisplay == false) { cancelPointer(); return "Share the entire phone screen to enable accurate touch control." }
        return try {
            if (command.optString("kind") != "pointer" && pointer != null) {
                cancelPointer(owner)
                if (command.optString("kind") != "action") return "Finish the held touch before sending another gesture or key."
            }
            when (command.optString("kind")) {
                "pointer" -> livePointer(command, owner, permitted, trace)
                "tap" -> {
                    val (x, y) = point(command)
                    gesture(listOf(Path().apply { moveTo(x, y) }), 60)
                }
                "drag" -> {
                    val points = command.optJSONArray("points") ?: return "Drag has no points."
                    if (points.length() !in 1..256) return "Invalid drag."
                    val path = Path()
                    for (index in 0 until points.length()) {
                        val (x, y) = point(points.getJSONObject(index))
                        if (index == 0) path.moveTo(x, y) else path.lineTo(x, y)
                    }
                    gesture(listOf(path), command.optLong("durationMs", 350).coerceIn(60, 5000))
                }
                "scroll" -> {
                    val size = displaySize()
                    val (x, y) = point(command)
                    val dx = finite(command.optDouble("dx", 0.0)).coerceIn(-0.4, 0.4) * size.x
                    val dy = finite(command.optDouble("dy", 0.0)).coerceIn(-0.4, 0.4) * size.y
                    if (abs(dx) + abs(dy) < 2) return null
                    gesture(listOf(Path().apply { moveTo(x, y); lineTo((x + dx).toFloat().coerceIn(1f, size.x - 1f), (y + dy).toFloat().coerceIn(1f, size.y - 1f)) }), 60)
                }
                "pinch" -> {
                    val size = displaySize(); val (x, y) = point(command)
                    val scale = finite(command.optDouble("scale", 1.0)).coerceIn(0.5, 2.0).toFloat()
                    val radius = (minOf(size.x, size.y) * 0.13f).coerceAtMost(minOf(x, size.x - x, y, size.y - y) / 2)
                    if (radius < 4) return "Pinch closer to the screen center."
                    val end = radius * scale
                    gesture(listOf(Path().apply { moveTo(x - radius, y); lineTo(x - end, y) }, Path().apply { moveTo(x + radius, y); lineTo(x + end, y) }), 250)
                }
                "action" -> action(command.optString("action"))
                "text" -> typeText(command.optString("value"))
                "key" -> key(command.optString("key"))
                else -> "Unsupported input."
            }
        } catch (_: Exception) { "Android did not accept this input." }
    }
    private fun livePointer(command: JSONObject, owner: String, permitted: () -> Boolean, trace: InputTrace?): String? {
        val id = command.optString("gestureId")
        if (id.length != 36 || runCatching { UUID.fromString(id).toString() != id.lowercase() }.getOrDefault(true)) return "Invalid touch identity."
        val seq = command.optLong("seq", -1)
        if (seq < 0) return "Invalid touch sequence."
        val phase = command.optString("phase")
        if (phase !in listOf("down", "move", "up", "cancel")) return "Unsupported touch phase."
        if (phase == "cancel") {
            val current = pointer
            val cancelsCurrent = current?.owner == owner && current.id == id && seq > current.seq
            if (cancelsCurrent) {
                current.pendingTrace?.finish(false, "coalesced"); current.pendingTrace = trace
                current.seq = seq; current.ending = true; current.cancelling = true
                current.targetX = current.x; current.targetY = current.y; pumpPointer(current)
            }
            val queued = queuedPointer
            if (queued?.owner == owner && queued.id == id && seq > queued.seq) {
                queued.pendingTrace?.finish(false, "cancelled"); queuedPointer = null
                trace?.finish(false, "cancelled")
            } else if (!cancelsCurrent) trace?.finish(false, "ignored")
            return null
        }
        if (MirrorState.service?.capture?.active != true) { cancelPointer(owner); return "Start screen sharing before controlling the phone." }
        val (x, y) = point(command)
        val size = displaySize()
        if (phase == "down") {
            if (pointer?.id == id || queuedPointer?.id == id) { trace?.finish(false, "ignored"); return null }
            val next = LivePointer(owner, id, seq, size, permitted, x, y, trace)
            if (pointer == null) { pointer = next; pumpPointer(next) }
            else {
                if (queuedPointer != null) return "A touch is already waiting to finish."
                queuedPointer = next
                pointer?.let { it.ending = true; pumpPointer(it) }
            }
            startPointerWatchdog()
            return null
        }
        val current = pointer?.takeIf { it.owner == owner && it.id == id }
            ?: queuedPointer?.takeIf { it.owner == owner && it.id == id } ?: run { trace?.finish(false, "ignored"); return null }
        if (seq <= current.seq || current.ending) { trace?.finish(false, "ignored"); return null }
        current.seq = seq; current.lastMessage = SystemClock.uptimeMillis()
        if (size.x != current.size.x || size.y != current.size.y) { cancelPointer(owner); return "Touch cancelled because the phone rotated." }
        current.pendingTrace?.finish(false, "coalesced"); current.pendingTrace = trace
        current.targetX = x; current.targetY = y
        if (phase == "up") current.ending = true
        if (pointer === current) pumpPointer(current)
        return null
    }
    private fun pumpPointer(active: LivePointer) {
        if (pointer !== active || active.inFlight) return
        val screen = displaySize()
        if (!active.permitted() || getSystemService(KeyguardManager::class.java).isDeviceLocked ||
            !getSystemService(PowerManager::class.java).isInteractive || MirrorState.service?.capture?.active != true ||
            MirrorState.service?.capture?.fullDisplay == false || screen.x != active.size.x || screen.y != active.size.y) {
            if (active.stroke == null) { finishPointer(active); return }
            active.ending = true; active.cancelling = true
            active.targetX = active.x; active.targetY = active.y
        }
        val previous = active.stroke
        if (previous != null && !active.ending && active.targetX == active.x && active.targetY == active.y) {
            active.pendingTrace?.finish(false, "stationary"); active.pendingTrace = null
            return
        }
        val targetX = if (active.cancelling) active.x else active.targetX
        val targetY = if (active.cancelling) active.y else active.targetY
        val path = Path().apply { moveTo(active.x, active.y); if (targetX != active.x || targetY != active.y) lineTo(targetX, targetY) }
        val continuation = !active.ending
        val stroke = if (previous == null) GestureDescription.StrokeDescription(path, 0, 16, continuation)
                     else previous.continueStroke(path, 0, if (active.cancelling) 1 else 16, continuation)
        active.stroke = stroke; active.x = targetX; active.y = targetY
        active.inFlight = true; active.dispatchTime = SystemClock.uptimeMillis()
        val gesture = GestureDescription.Builder().addStroke(stroke).build()
        val trace = active.pendingTrace; active.pendingTrace = null
        trace?.dispatching()
        val accepted = dispatchGesture(gesture, object : GestureResultCallback() {
            override fun onCompleted(gestureDescription: GestureDescription?) {
                trace?.finish(true)
                if (pointer !== active || active.stroke !== stroke) return
                active.inFlight = false
                if (!continuation) finishPointer(active) else pumpPointer(active)
            }
            override fun onCancelled(gestureDescription: GestureDescription?) {
                trace?.finish(false)
                if (pointer === active && active.stroke === stroke) finishPointer(active)
            }
        }, inputHandler)
        trace?.returned(accepted)
        if (!accepted) finishPointer(active)
    }
    private fun finishPointer(active: LivePointer) {
        if (pointer !== active) return
        active.pendingTrace?.finish(false, "cancelled"); active.pendingTrace = null
        pointer = null
        val next = queuedPointer; queuedPointer = null
        if (next != null && next.permitted() && !getSystemService(KeyguardManager::class.java).isDeviceLocked &&
            MirrorState.service?.capture?.active == true && MirrorState.service?.capture?.fullDisplay != false &&
            SystemClock.uptimeMillis() - next.lastMessage <= 1250) {
            pointer = next; pumpPointer(next); startPointerWatchdog()
        }
    }
    fun cancelPointer(owner: String? = null) {
        if (Looper.myLooper() != Looper.getMainLooper()) { inputHandler.post { cancelPointer(owner) }; return }
        if (owner == null || queuedPointer?.owner == owner) queuedPointer = null
        val active = pointer ?: return
        if (owner != null && active.owner != owner) return
        active.ending = true; active.cancelling = true
        active.targetX = active.x; active.targetY = active.y
        pumpPointer(active)
    }
    private fun startPointerWatchdog() {
        if (pointer != null && !pointerWatchdogRunning) {
            pointerWatchdogRunning = true
            inputHandler.postDelayed(pointerWatchdog, 100)
        }
    }
    private fun action(name: String): String? {
        val action = when (name) {
            "back" -> GLOBAL_ACTION_BACK
            "home" -> GLOBAL_ACTION_HOME
            "recents" -> GLOBAL_ACTION_RECENTS
            "lock" -> GLOBAL_ACTION_LOCK_SCREEN
            "volumeUp", "volumeDown" -> {
                getSystemService(AudioManager::class.java).adjustVolume(if (name == "volumeUp") AudioManager.ADJUST_RAISE else AudioManager.ADJUST_LOWER, AudioManager.FLAG_SHOW_UI)
                return null
            }
            else -> return "Unsupported navigation action."
        }
        return if (performGlobalAction(action)) null else "Android refused this navigation action."
    }
    private fun typeText(value: String): String? {
        if (value.length > 8192) return "Text is too long."
        if (Build.VERSION.SDK_INT >= 33) {
            val connection = inputMethod?.currentInputConnection
            if (connection != null) { connection.commitText(value, 1, null); return null }
        }
        val node = findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: return "Select a text field on the phone first."
        try {
            if (!node.isEditable || node.isPassword) return "This text field requires Android keyboard input."
            val old = node.text?.toString() ?: ""
            val start = node.textSelectionStart.coerceIn(0, old.length)
            val end = node.textSelectionEnd.coerceIn(start, old.length)
            val updated = old.substring(0, start) + value + old.substring(end)
            val ok = node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, Bundle().apply { putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, updated) })
            if (ok) node.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, Bundle().apply { putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, start + value.length); putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, start + value.length) })
            return if (ok) null else "This app does not allow accessibility text editing."
        } finally { @Suppress("DEPRECATION") node.recycle() }
    }
    private fun key(name: String): String? {
        if (name == "escape") return action("back")
        val code = when (name) {
            "backspace" -> KeyEvent.KEYCODE_DEL
            "enter" -> KeyEvent.KEYCODE_ENTER
            "tab" -> KeyEvent.KEYCODE_TAB
            "left" -> KeyEvent.KEYCODE_DPAD_LEFT
            "right" -> KeyEvent.KEYCODE_DPAD_RIGHT
            "up" -> KeyEvent.KEYCODE_DPAD_UP
            "down" -> KeyEvent.KEYCODE_DPAD_DOWN
            else -> return "Unsupported key."
        }
        if (Build.VERSION.SDK_INT >= 33) {
            val connection = inputMethod?.currentInputConnection
            if (connection != null) {
                val now = SystemClock.uptimeMillis()
                connection.sendKeyEvent(KeyEvent(now, now, KeyEvent.ACTION_DOWN, code, 0))
                connection.sendKeyEvent(KeyEvent(now, now, KeyEvent.ACTION_UP, code, 0))
                return null
            }
        }
        return "Select a supported text field. Keyboard control requires Android 13 or later."
    }
    private fun gesture(paths: List<Path>, duration: Long): String? {
        val builder = GestureDescription.Builder()
        paths.forEach { builder.addStroke(GestureDescription.StrokeDescription(it, 0, duration)) }
        return if (dispatchGesture(builder.build(), null, null)) null else "Android refused this gesture."
    }
    private fun finite(value: Double): Double { require(value.isFinite()); return value }
    private fun point(value: JSONObject): Pair<Float, Float> {
        val size = displaySize()
        return Pair((finite(value.optDouble("x", 0.5)).coerceIn(0.0, 1.0) * (size.x - 1)).toFloat(), (finite(value.optDouble("y", 0.5)).coerceIn(0.0, 1.0) * (size.y - 1)).toFloat())
    }
    private fun displaySize(): Point {
        val manager = getSystemService(WindowManager::class.java)
        if (Build.VERSION.SDK_INT >= 30) return manager.maximumWindowMetrics.bounds.let { Point(it.width(), it.height()) }
        return Point().apply { @Suppress("DEPRECATION") manager.defaultDisplay.getRealSize(this) }
    }
}

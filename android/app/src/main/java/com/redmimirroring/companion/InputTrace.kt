package com.redmimirroring.companion

import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

/** Opt-in timings only: no coordinates, text, credentials or screen data. */
class InputTrace private constructor(
    private val id: String,
    private val phase: String,
    private val sequence: Long,
    private val source: String?,
    private val receivedPhoneMs: Double,
    private val report: (JSONObject) -> Unit
) {
    companion object {
        fun now(): Double = System.nanoTime() / 1_000_000.0
        fun from(command: JSONObject, receivedPhoneMs: Double, report: (JSONObject) -> Unit): InputTrace? {
            if (command.optString("kind") != "pointer") return null
            val id = command.optString("traceId")
            if (id.length != 36 || runCatching { UUID.fromString(id).toString() != id.lowercase() }.getOrDefault(true)) return null
            val phase = command.optString("phase")
            val seq = command.optLong("seq", -1)
            if (phase !in listOf("down", "move", "up", "cancel") || seq < 0) return null
            val source = command.optString("source").takeIf { it == "mouse" || it == "scroll" }
            return InputTrace(id, phase, seq, source, receivedPhoneMs, report)
        }
    }
    private val ended = AtomicBoolean(false)
    private var mainPhoneMs: Double? = null
    private var dispatchPhoneMs: Double? = null
    private var dispatchReturnPhoneMs: Double? = null
    private var completedPhoneMs: Double? = null
    private var accepted: Boolean? = null

    fun handled() {
        mainPhoneMs = now()
        emit("handled", null)
    }
    fun dispatching() { dispatchPhoneMs = now() }
    fun returned(wasAccepted: Boolean) {
        dispatchReturnPhoneMs = now(); accepted = wasAccepted
        if (!wasAccepted) finish(false, "rejected")
    }
    fun finish(completed: Boolean, stage: String = "completed") {
        if (!ended.compareAndSet(false, true)) return
        completedPhoneMs = now()
        emit(stage, completed)
    }
    private fun emit(stage: String, completed: Boolean?) {
        // A diagnostic failure must never affect gesture delivery or watchdog cleanup.
        runCatching {
            val result = JSONObject().put("type", "inputTrace").put("traceId", id)
                .put("phase", phase).put("seq", sequence).put("stage", stage)
                .put("receivedPhoneMs", receivedPhoneMs)
            source?.let { result.put("source", it) }
            mainPhoneMs?.let { result.put("mainPhoneMs", it) }
            dispatchPhoneMs?.let { result.put("dispatchPhoneMs", it) }
            dispatchReturnPhoneMs?.let { result.put("dispatchReturnPhoneMs", it) }
            completedPhoneMs?.let { result.put("completedPhoneMs", it) }
            accepted?.let { result.put("accepted", it) }
            completed?.let { result.put("completed", it) }
            report(result)
        }
    }
}

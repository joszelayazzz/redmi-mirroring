package com.redmimirroring.companion

import android.app.KeyguardManager
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.net.ConnectivityManager
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.MediaStore
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.OutputStream
import java.net.Inet4Address
import java.net.NetworkInterface
import java.util.UUID
import java.util.concurrent.LinkedBlockingDeque
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.SSLServerSocket
import javax.net.ssl.SSLSocket

object MirrorState {
    val main = Handler(Looper.getMainLooper())
    @Volatile var service: MirrorService? = null
    @Volatile var status = "Ready to pair"
    @Volatile var pending: Approval? = null
    var observer: (() -> Unit)? = null
    data class Approval(val name: String, val address: String, val finish: (Boolean) -> Unit)
    fun update(message: String? = null) { if (message != null) status = message; main.post { service?.refreshNotification(); observer?.invoke() } }
}

class MirrorServer(private val context: Context, val identity: Identity) : AutoCloseable {
    companion object { const val PORT = 39817 }
    private val running = AtomicBoolean(false)
    private var listener: SSLServerSocket? = null
    private val slots = Semaphore(4)
    private val nsd = context.getSystemService(NsdManager::class.java)
    private var registration: NsdManager.RegistrationListener? = null
    @Volatile private var invitationSecret: String? = null
    @Volatile private var invitationExpiry = 0L
    @Volatile private var approved: Connection? = null
    @Volatile private var codecConfig: ByteArray? = null
    private val connections = java.util.concurrent.ConcurrentHashMap.newKeySet<Connection>()

    fun start() {
        if (!running.compareAndSet(false, true)) return
        Thread({
            try {
                val socket = identity.tlsContext().serverSocketFactory.createServerSocket(PORT) as SSLServerSocket
                listener = socket
                socket.enabledProtocols = socket.supportedProtocols.filter { it == "TLSv1.2" || it == "TLSv1.3" }.toTypedArray()
                socket.needClientAuth = false
                register()
                MirrorState.update("Available for your Mac")
                while (running.get()) {
                    val peer = socket.accept() as SSLSocket
                    if (!slots.tryAcquire()) { peer.close(); continue }
                    Thread({
                        val connection = Connection(peer)
                        connections.add(connection)
                        try { connection.run() } catch (e: Exception) {
                            // JSON parser messages may include credentials: log only types and a source location.
                            android.util.Log.w("RedmiMirror", "TLS peer ended: ${e.javaClass.simpleName}, cause=${e.cause?.javaClass?.simpleName ?: "none"}, at=${e.stackTrace.firstOrNull()}")
                        }
                        finally { connection.close(); connections.remove(connection); slots.release() }
                    }, "Mirror TLS peer").start()
                }
            } catch (e: Exception) {
                if (running.get()) MirrorState.update("Cannot listen: ${e.javaClass.simpleName}. Reopen the companion.")
            }
        }, "Mirror TLS listener").start()
    }

    @Synchronized fun invitation(): String {
        val host = addresses().firstOrNull() ?: throw IllegalStateException("Connect your phone to Wi-Fi or a private VPN first.")
        invitationSecret = Identity.secret()
        invitationExpiry = SystemClock.elapsedRealtime() + 300_000
        return Uri.Builder().scheme("redmimirror").authority("pair")
            .appendQueryParameter("host", host).appendQueryParameter("port", PORT.toString())
            .appendQueryParameter("id", identity.id).appendQueryParameter("name", identity.name)
            .appendQueryParameter("fp", identity.fingerprint).appendQueryParameter("secret", invitationSecret).build().toString()
    }

    fun addresses(): List<String> {
        val connectivity = context.getSystemService(ConnectivityManager::class.java)
        val active = connectivity.activeNetwork?.let { connectivity.getLinkProperties(it) }?.linkAddresses?.map { it.address }.orEmpty()
        val remaining = NetworkInterface.getNetworkInterfaces().toList().filter { it.isUp && !it.isLoopback }.flatMap { it.inetAddresses.toList() }
        return (active + remaining).filterIsInstance<Inet4Address>().filter { !it.isLoopbackAddress && !it.isLinkLocalAddress }.map { it.hostAddress!! }.distinct()
    }

    private fun register() {
        val info = NsdServiceInfo().apply {
            serviceName = "Redmi Mirroring ${identity.id.take(8)}"
            serviceType = "_redmimirror._tcp."
            port = PORT
            setAttribute("id", identity.id)
            setAttribute("name", identity.name)
            setAttribute("v", "1")
        }
        val callback = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {}
            override fun onRegistrationFailed(info: NsdServiceInfo, error: Int) { MirrorState.update("Connect using the address in your pairing invitation") }
            override fun onServiceUnregistered(info: NsdServiceInfo) {}
            override fun onUnregistrationFailed(info: NsdServiceInfo, error: Int) {}
        }
        registration = callback
        nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, callback)
    }

    fun ready() {
        val capture = MirrorState.service?.capture
        if (capture?.active != true || capture.fullDisplay == false) ControlService.current?.cancelPointer()
        approved?.json(readyMessage())
    }
    private fun readyMessage(): JSONObject {
        val capture = MirrorState.service?.capture
        return JSONObject().put("type", "ready").put("deviceId", identity.id).put("name", identity.name)
            .put("width", capture?.width ?: 0).put("height", capture?.height ?: 0).put("fps", capture?.fps ?: 0)
            .put("audio", capture?.audioActive == true).put("control", ControlService.current != null && capture?.fullDisplay != false).put("projection", capture?.active == true)
            .put("livePointer", ControlService.current != null && capture?.fullDisplay != false)
            .put("requestedLatencyFrames", 1).put("latencyHintApplied", capture?.latencyHintApplied == true)
            .apply {
                capture?.actualLatencyFrames?.let { put("actualLatencyFrames", it) }
                capture?.encoderName?.takeIf { it.isNotEmpty() }?.let { put("encoder", it) }
            }
    }
    fun config(bytes: ByteArray) { codecConfig = bytes; approved?.switchCodec(bytes) }
    fun video(pts: Long, bytes: ByteArray, key: Boolean) { approved?.video(Wire.Frame(Wire.VIDEO, Wire.timed(pts, bytes)), key) }
    fun audio(pts: Long, bytes: ByteArray) { approved?.send(Wire.Frame(Wire.AUDIO, Wire.timed(pts, bytes))) }
    fun wantsStreamStats(): Boolean = approved?.wantsStreamStats() == true
    fun streamStats(report: JSONObject) { approved?.streamStats(report) }
    fun message(type: String, message: String) {
        if (type == "captureStopped") ControlService.current?.cancelPointer()
        approved?.json(JSONObject().put("type", type).put("message", message))
    }
    fun sendClipboard(text: String): Boolean {
        val client = approved ?: return false
        if (locked() || text.toByteArray(Charsets.UTF_8).size > 1024 * 1024) return false
        client.json(JSONObject().put("type", "clipboard").put("text", text))
        return true
    }
    @Synchronized fun revoke(id: String) { identity.revoke(id); if (approved?.clientId == id) approved?.close(); MirrorState.update() }
    fun locked(): Boolean = context.getSystemService(KeyguardManager::class.java).isDeviceLocked
    override fun close() {
        running.set(false)
        invitationSecret = null
        connections.toList().forEach { it.close() }
        runCatching { listener?.close() }
        registration?.let { runCatching { nsd.unregisterService(it) } }
        registration = null
        MirrorState.pending?.finish?.invoke(false)
    }

    inner class Connection(private val socket: SSLSocket) : AutoCloseable {
        var clientId = ""
        private var clientName = ""
        private val controlOwner = UUID.randomUUID().toString()
        private val open = AtomicBoolean(true)
        private val queue = LinkedBlockingDeque<QueuedFrame>(32)
        @Volatile private var awaitingKey = true
        @Volatile private var authenticated = false
        @Volatile private var closeAfterFrame: Wire.Frame? = null
        private var file: IncomingFile? = null
        private val inputLock = Any()
        private val inputs = java.util.ArrayDeque<PendingInput>()
        private var inputScheduled = false
        private var traceWindowMs = 0.0
        private var tracesInWindow = 0
        @Volatile private var traceUntilPhoneMs = 0.0
        @Volatile private var writerStats = WriterStats()
        private var writerWindowMs = 0.0
        private var writerCount = 0
        private var queueWaitTotal = 0.0
        private var queueWaitMax = 0.0
        private var writeTotal = 0.0
        private var writeMax = 0.0

        fun run() {
            socket.soTimeout = 15_000
            socket.tcpNoDelay = true
            socket.startHandshake()
            val input = DataInputStream(BufferedInputStream(socket.inputStream))
            val output = DataOutputStream(BufferedOutputStream(socket.outputStream))
            val auth = Wire.read(input, 4097)
            if (auth.type != Wire.JSON || auth.bytes.size > 4096) return
            val request = JSONObject(String(auth.bytes, Charsets.UTF_8))
            if (request.optString("type") != "auth" || request.optInt("version") != 1) return
            clientId = request.optString("clientId")
            if (runCatching { UUID.fromString(clientId) }.isFailure) return
            clientName = request.optString("name").filter { !it.isISOControl() }.take(80).ifBlank { "A Mac" }
            val secret = request.optString("secret")
            val paired = identity.clients().optJSONObject(clientId)
            if (!request.optBoolean("pair")) {
                if (paired == null || !Identity.matches(paired.optString("secret"), secret)) {
                    Wire.write(output, jsonFrame(JSONObject().put("type", "error").put("message", "This Mac is not paired. Pair again on the phone."))); return
                }
            } else {
                val expected = invitationSecret
                if (expected == null || SystemClock.elapsedRealtime() > invitationExpiry || !Identity.matches(expected, secret) || locked()) {
                    Wire.write(output, jsonFrame(JSONObject().put("type", "error").put("message", "Invitation expired or phone is locked."))); return
                }
                val decision = java.util.concurrent.CountDownLatch(1)
                val allow = AtomicBoolean(false)
                synchronized(this@MirrorServer) {
                    if (MirrorState.pending != null) return
                    MirrorState.pending = MirrorState.Approval(clientName, socket.inetAddress.hostAddress ?: "Unknown address") {
                        allow.set(it); decision.countDown()
                    }
                }
                Wire.write(output, jsonFrame(JSONObject().put("type", "pending")))
                MirrorState.update("Approve $clientName on this phone")
                val answered = decision.await(120, TimeUnit.SECONDS)
                MirrorState.pending = null
                MirrorState.update()
                if (!answered || !allow.get() || locked() || invitationSecret != expected || SystemClock.elapsedRealtime() > invitationExpiry) {
                    Wire.write(output, jsonFrame(JSONObject().put("type", "error").put("message", "Pairing was not approved on the phone."))); return
                }
                identity.approve(clientId, clientName, secret)
                invitationSecret = null
            }
            synchronized(this@MirrorServer) {
                // Revalidate under the revocation/publication lock, including a revoke racing the first lookup.
                val latest = identity.clients().optJSONObject(clientId)
                if (!running.get() || !open.get() || latest == null || !Identity.matches(latest.optString("secret"), secret)) return
                approved?.close()
                authenticated = true
                approved = this
            }
            socket.soTimeout = 45_000
            Thread({
                try { while (open.get()) {
                    val queued = queue.poll(1, TimeUnit.SECONDS) ?: continue
                    val began = InputTrace.now()
                    Wire.write(output, queued.frame)
                    writerTiming(queued, began, InputTrace.now())
                    if (queued.frame === closeAfterFrame) { close(); break }
                } }
                catch (_: Exception) { close() }
            }, "Mirror TLS writer").start()
            json(readyMessage())
            codecConfig?.let { send(Wire.Frame(Wire.CONFIG, it)) }
            MirrorState.service?.capture?.requestKeyframe()
            MirrorState.update("Connected to $clientName")
            while (open.get()) {
                val frame = Wire.read(input)
                val receivedPhoneMs = InputTrace.now()
                if (!authorized()) { if (closeAfterFrame != null) continue else break }
                if (frame.type == Wire.JSON) {
                    if (frame.bytes.size > 1024 * 1024 + 4096) throw java.io.IOException("Command too large")
                    command(JSONObject(String(frame.bytes, Charsets.UTF_8)), receivedPhoneMs)
                } else if (frame.type == Wire.FILE) {
                    val transfer = file ?: throw java.io.IOException("Unexpected file data")
                    if (frame.bytes.size > 256 * 1024 || transfer.received + frame.bytes.size > transfer.size) throw java.io.IOException("Invalid file size")
                    transfer.stream.write(frame.bytes); transfer.received += frame.bytes.size
                } else throw java.io.IOException("Unexpected client frame")
            }
        }

        private fun command(command: JSONObject, receivedPhoneMs: Double) {
            if (!authorized()) return
            when (command.optString("type")) {
                "ping" -> json(JSONObject().put("type", "pong").put("sent", command.opt("sent")).put("phoneTime", System.nanoTime() / 1_000_000.0))
                "input" -> {
                    val trace = inputTrace(command, receivedPhoneMs)
                    if (locked()) {
                        ControlService.current?.cancelPointer(controlOwner)
                        trace?.finish(false, "rejected")
                        json(JSONObject().put("type", "inputResult").put("ok", false).put("message", "Unlock your phone to control it.")); return
                    }
                    enqueueInput(PendingInput(command, trace))
                }
                "quality" -> MirrorState.service?.capture?.quality(command.optInt("bitrate", 8_000_000), command.optInt("fps", 60), command.optInt("maxDimension", 1920))
                "keyframe" -> MirrorState.service?.capture?.requestKeyframe()
                "clipboard" -> {
                    val text = command.optString("text")
                    if (!locked() && text.toByteArray(Charsets.UTF_8).size <= 1024 * 1024) MirrorState.main.post {
                        if (authorized() && !locked()) context.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("From your Mac", text))
                    }
                }
                "fileStart" -> beginFile(command)
                "fileEnd" -> finishFile(command.optString("id"))
                "unpair" -> {
                    synchronized(this@MirrorServer) {
                        if (!authorized()) return
                        identity.revoke(clientId)
                        ControlService.current?.cancelPointer(controlOwner)
                        val acknowledgement = jsonFrame(JSONObject().put("type", "unpaired"))
                        closeAfterFrame = acknowledgement
                        queue.clear()
                        if (!queue.offerFirst(QueuedFrame(acknowledgement, InputTrace.now()))) close()
                    }
                    MirrorState.update("Mac unpaired")
                }
                else -> json(JSONObject().put("type", "error").put("message", "Unsupported command"))
            }
        }
        private fun inputTrace(command: JSONObject, receivedPhoneMs: Double): InputTrace? {
            if (receivedPhoneMs - traceWindowMs >= 1000) { traceWindowMs = receivedPhoneMs; tracesInWindow = 0 }
            if (tracesInWindow >= 80) return null
            val trace = InputTrace.from(command, receivedPhoneMs) { report ->
                // Tracing is best-effort and cannot disconnect a normal session if its queue is full.
                if (authorized() && queue.size < 8) queue.offer(QueuedFrame(jsonFrame(report), InputTrace.now()))
            }
            if (trace != null) { tracesInWindow++; traceUntilPhoneMs = receivedPhoneMs + 10_000 }
            return trace
        }
        fun wantsStreamStats(): Boolean = authorized() && InputTrace.now() <= traceUntilPhoneMs
        fun streamStats(report: JSONObject) {
            if (!wantsStreamStats() || queue.size >= 8) return
            val stats = writerStats
            report.put("writerSampledFrames", stats.count).put("writerQueueMeanMs", stats.queueMean)
                .put("writerQueueMaxMs", stats.queueMax).put("writerWriteMeanMs", stats.writeMean)
                .put("writerWriteMaxMs", stats.writeMax).put("writerQueueDepth", queue.size)
            queue.offer(QueuedFrame(jsonFrame(report), InputTrace.now()))
        }
        private fun writerTiming(queued: QueuedFrame, began: Double, ended: Double) {
            if (!wantsStreamStats()) {
                writerWindowMs = ended; writerCount = 0; queueWaitTotal = 0.0; queueWaitMax = 0.0; writeTotal = 0.0; writeMax = 0.0
                return
            }
            val wait = maxOf(0.0, began - queued.enqueuedPhoneMs)
            val write = maxOf(0.0, ended - began)
            writerCount++; queueWaitTotal += wait; queueWaitMax = maxOf(queueWaitMax, wait)
            writeTotal += write; writeMax = maxOf(writeMax, write)
            if (ended - writerWindowMs < 1000) return
            writerStats = WriterStats(writerCount, queueWaitTotal / writerCount, queueWaitMax, writeTotal / writerCount, writeMax)
            writerWindowMs = ended; writerCount = 0; queueWaitTotal = 0.0; queueWaitMax = 0.0; writeTotal = 0.0; writeMax = 0.0
        }
        private fun enqueueInput(pending: PendingInput) {
            val command = pending.command
            var schedule = false
            var overflow = false
            var coalesced: InputTrace? = null
            synchronized(inputLock) {
                val last = inputs.peekLast()?.command
                val move = command.optString("kind") == "pointer" && command.optString("phase") == "move"
                if (move && last?.optString("kind") == "pointer" && last.optString("phase") == "move" &&
                    last.optString("gestureId") == command.optString("gestureId") &&
                    command.optLong("seq", -1) > last.optLong("seq", -1)) coalesced = inputs.removeLast().trace
                if (inputs.size >= 64) overflow = true
                else {
                    inputs.addLast(pending)
                    if (!inputScheduled) { inputScheduled = true; schedule = true }
                }
            }
            coalesced?.finish(false, "coalesced")
            if (overflow) { close(); return }
            if (schedule) MirrorState.main.post { drainInputs() }
        }
        private fun drainInputs() {
            repeat(16) {
                val pending = synchronized(inputLock) { inputs.pollFirst().also { if (it == null) inputScheduled = false } } ?: return
                if (!authorized()) { ControlService.current?.cancelPointer(controlOwner); return@repeat }
                val command = pending.command
                pending.trace?.handled()
                val control = ControlService.current
                val result = if (locked()) { control?.cancelPointer(controlOwner); "Unlock your phone to control it." }
                    else if (control == null) "Enable Redmi Mirroring control in Accessibility settings."
                    else control.handle(command, controlOwner, pending.trace) { authorized() }
                if (result != null) pending.trace?.finish(false, "rejected")
                if (result != null) json(JSONObject().put("type", "inputResult").put("ok", false).put("message", result))
            }
            MirrorState.main.post { drainInputs() }
        }
        private fun authorized(): Boolean = open.get() && authenticated && approved === this && closeAfterFrame == null
        private fun beginFile(command: JSONObject) {
            if (locked()) { json(JSONObject().put("type", "fileResult").put("ok", false).put("message", "Unlock your phone to receive files.")); return }
            check(file == null) { "Another file is in progress" }
            val size = command.optLong("size", -1)
            require(size in 0..32L * 1024 * 1024)
            val name = Wire.safeFilename(command.optString("name"))
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, name)
                put(MediaStore.Downloads.MIME_TYPE, "application/octet-stream")
                put(MediaStore.Downloads.RELATIVE_PATH, "Download/Redmi Mirroring")
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val uri = context.contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values) ?: throw java.io.IOException("Cannot create download")
            val stream = try { context.contentResolver.openOutputStream(uri) ?: throw java.io.IOException("Cannot write download") }
                catch (error: Exception) { runCatching { context.contentResolver.delete(uri, null, null) }; throw error }
            file = IncomingFile(command.getString("id"), size, uri, stream)
        }
        private fun finishFile(id: String) {
            val transfer = file ?: return
            check(id == transfer.id && transfer.received == transfer.size) { "File is incomplete" }
            transfer.stream.close()
            context.contentResolver.update(transfer.uri, ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }, null, null)
            file = null
            json(JSONObject().put("type", "fileResult").put("ok", true).put("message", "Saved to Downloads / Redmi Mirroring"))
        }
        fun json(json: JSONObject) { send(jsonFrame(json)) }
        fun switchCodec(bytes: ByteArray) {
            queue.removeIf { it.frame.type == Wire.VIDEO || it.frame.type == Wire.CONFIG }
            awaitingKey = true
            send(Wire.Frame(Wire.CONFIG, bytes))
        }
        fun send(frame: Wire.Frame) {
            if (!open.get() || !authenticated) return
            if (!queue.offer(QueuedFrame(frame, InputTrace.now())) && frame.type != Wire.AUDIO) close()
        }
        fun video(frame: Wire.Frame, key: Boolean) {
            if (!open.get() || !authenticated) return
            if (queue.count { it.frame.type == Wire.VIDEO } >= 4) {
                // Video congestion must not punch holes in continuous PCM playback.
                queue.removeIf { it.frame.type == Wire.VIDEO }
                awaitingKey = true
                MirrorState.service?.capture?.requestKeyframe()
            }
            if (awaitingKey && !key) return
            awaitingKey = false
            send(frame)
        }
        override fun close() {
            var wasApproved = false
            synchronized(this@MirrorServer) {
                if (!open.compareAndSet(true, false)) return
                authenticated = false
                if (approved === this) { approved = null; wasApproved = true }
            }
            runCatching { socket.close() }
            synchronized(inputLock) { inputs.clear() }
            ControlService.current?.cancelPointer(controlOwner)
            file?.let { runCatching { it.stream.close() }; runCatching { context.contentResolver.delete(it.uri, null, null) } }
            file = null
            if (wasApproved) MirrorState.update("Available for your Mac")
        }
    }
    private data class PendingInput(val command: JSONObject, val trace: InputTrace?)
    private data class QueuedFrame(val frame: Wire.Frame, val enqueuedPhoneMs: Double)
    private data class WriterStats(val count: Int = 0, val queueMean: Double = 0.0, val queueMax: Double = 0.0,
                                   val writeMean: Double = 0.0, val writeMax: Double = 0.0)
    private data class IncomingFile(val id: String, val size: Long, val uri: Uri, val stream: OutputStream, var received: Long = 0)
    private fun jsonFrame(json: JSONObject) = Wire.Frame(Wire.JSON, json.toString().toByteArray(Charsets.UTF_8))
}

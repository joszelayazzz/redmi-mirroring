package com.redmimirroring.companion

import android.os.Handler
import android.os.Looper
import org.json.JSONObject
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.security.MessageDigest
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLHandshakeException
import javax.net.ssl.SSLSocket
import javax.net.ssl.X509TrustManager

/**
 * Outbound TLS byte bridge to a provisioned opaque relay. The local socket
 * carries the existing Android TLS server connection without decrypting it.
 * Configuration belongs in Identity's encrypted storage, never plain prefs.
 */
class RemoteTunnel {
    private class Run {
        val cancelled = AtomicBoolean(false)
        val sockets = ConcurrentHashMap.newKeySet<Socket>()
        var thread: Thread? = null
        fun close() {
            cancelled.set(true)
            sockets.forEach { runCatching { it.close() } }
            thread?.interrupt()
        }
    }

    private class PinMismatch : CertificateException("Relay identity does not match")
    private class AdmissionFailure(message: String, val fatal: Boolean) : java.io.IOException(message)
    private val main = Handler(Looper.getMainLooper())
    private var active: Run? = null

    @Synchronized
    fun start(host: String, port: Int, fingerprint: String, room: String,
              localPort: Int = 39817, onError: (String) -> Unit) {
        stop()
        val cleanHost = host.trim()
        val cleanPin = fingerprint.replace(":", "").lowercase(Locale.ROOT)
        val hex = Regex("^[0-9a-f]{64}$")
        if (cleanHost.isBlank() || cleanHost.length > 253 || cleanHost.any { it.isWhitespace() || it == '/' } ||
            port !in 1..65535 || localPort !in 1..65535 || !hex.matches(cleanPin) || !hex.matches(room)) {
            main.post { onError("Enter the relay host, port, certificate fingerprint, and a 256-bit room token.") }
            return
        }
        val run = Run()
        active = run
        val expected = ByteArray(32) { index -> cleanPin.substring(index * 2, index * 2 + 2).toInt(16).toByte() }
        val manager = object : X509TrustManager {
            override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
            override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) {
                throw CertificateException("Client credentials are not accepted here")
            }
            override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) {
                if (chain.isEmpty()) throw PinMismatch()
                val actual = MessageDigest.getInstance("SHA-256").digest(chain[0].encoded)
                if (!MessageDigest.isEqual(actual, expected)) throw PinMismatch()
                chain[0].checkValidity()
            }
        }
        val tls = SSLContext.getInstance("TLS").apply { init(null, arrayOf(manager), null) }
        fun report(message: String) {
            main.post { if (!run.cancelled.get()) onError(message) }
        }
        run.thread = Thread({
            var attempt = 0
            while (!run.cancelled.get()) {
                var outer: SSLSocket? = null
                var local: Socket? = null
                var reverse: Thread? = null
                var fatal = false
                try {
                    outer = tls.socketFactory.createSocket() as SSLSocket
                    run.sockets.add(outer)
                    outer.enabledProtocols = outer.supportedProtocols.filter { it == "TLSv1.2" || it == "TLSv1.3" }.toTypedArray()
                    outer.tcpNoDelay = true
                    outer.keepAlive = true
                    outer.soTimeout = 10_000
                    outer.connect(InetSocketAddress(cleanHost, port), 10_000)
                    outer.startHandshake()
                    val output = DataOutputStream(outer.outputStream)
                    val payload = JSONObject().put("role", "phone").put("room", room).toString().toByteArray(Charsets.UTF_8)
                    output.writeInt(payload.size); output.write(payload); output.flush()
                    outer.soTimeout = 125_000
                    val input = DataInputStream(outer.inputStream)
                    val length = input.readInt()
                    if (length !in 2..4096) throw AdmissionFailure("Invalid relay admission response.", true)
                    val bytes = ByteArray(length)
                    input.readFully(bytes)
                    val reply = runCatching { JSONObject(String(bytes, Charsets.UTF_8)) }.getOrElse {
                        throw AdmissionFailure("Invalid relay admission response.", true)
                    }
                    if (!reply.optBoolean("ok")) {
                        val reason = reply.optString("error", "Relay refused this room.")
                            .filter { !it.isISOControl() }.take(160)
                        val retryable = listOf("timed out", "capacity", "role", "rate").any { reason.contains(it) }
                        throw AdmissionFailure(reason, !retryable)
                    }
                    outer.soTimeout = 45_000
                    local = Socket().apply {
                        tcpNoDelay = true; keepAlive = true; soTimeout = 45_000
                        connect(InetSocketAddress("127.0.0.1", localPort), 5_000)
                    }
                    run.sockets.add(local)
                    if (run.cancelled.get()) break
                    attempt = 0
                    val remoteSocket = outer
                    val localSocket = local
                    reverse = Thread({
                        try { copy(localSocket.inputStream, remoteSocket.outputStream, run) }
                        catch (_: Exception) { /* Neither plaintext nor room credentials are logged. */ }
                        finally { runCatching { localSocket.close() }; runCatching { remoteSocket.close() } }
                    }, "Remote mirror upstream").apply { isDaemon = true; start() }
                    copy(outer.inputStream, local.outputStream, run)
                } catch (error: Exception) {
                    if (!run.cancelled.get()) {
                        fatal = error is AdmissionFailure && error.fatal
                        if (error is SSLHandshakeException) {
                            var cause: Throwable? = error
                            while (cause != null) {
                                if (cause is CertificateException) fatal = true
                                cause = cause.cause
                            }
                        }
                        report(if (fatal && error is SSLHandshakeException)
                            "The relay certificate does not match or is expired. Remote connection refused."
                        else if (error is AdmissionFailure) error.message ?: "Relay admission failed."
                        else "Remote relay interrupted. Reconnecting…")
                    }
                } finally {
                    outer?.let { runCatching { it.close() }; run.sockets.remove(it) }
                    local?.let { runCatching { it.close() }; run.sockets.remove(it) }
                    runCatching { reverse?.join(1000) }
                }
                if (run.cancelled.get() || fatal) break
                attempt = (attempt + 1).coerceAtMost(4)
                try { Thread.sleep((1L shl attempt) * 1000L) }
                catch (_: InterruptedException) { break }
            }
        }, "Remote mirror relay").apply { isDaemon = true; start() }
    }

    private fun copy(input: InputStream, output: OutputStream, run: Run) {
        val buffer = ByteArray(65_536)
        while (!run.cancelled.get()) {
            val length = input.read(buffer)
            if (length < 0) return
            if (length == 0) continue
            output.write(buffer, 0, length)
            output.flush()
        }
    }

    @Synchronized
    fun stop() {
        active?.close()
        active = null
    }
}

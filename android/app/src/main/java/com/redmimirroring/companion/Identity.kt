package com.redmimirroring.companion

import android.content.Context
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONObject
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.SecureRandom
import java.security.cert.X509Certificate
import java.security.spec.ECGenParameterSpec
import java.util.Date
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.net.ssl.KeyManager
import javax.net.ssl.SSLContext
import javax.net.ssl.X509ExtendedKeyManager
import javax.security.auth.x500.X500Principal
import java.net.Socket
import javax.net.ssl.SSLEngine

class Identity(context: Context) {
    private val prefs = context.getSharedPreferences("identity", Context.MODE_PRIVATE)
    private val keys = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
    val id = prefs.getString("id", null) ?: UUID.randomUUID().toString().also { prefs.edit().putString("id", it).commit() }
    val name: String = runCatching { android.provider.Settings.Global.getString(context.contentResolver, "device_name") }
        .getOrNull().orEmpty().filter { !it.isISOControl() }.trim().take(80).ifBlank { Build.MODEL }
    // v2 authorizes prehashed ECDSA signing required by Conscrypt TLS.
    private val tlsAlias = "redmi.mirroring.tls.v2"
    private val storageAlias = "redmi.mirroring.storage.v1"

    init {
        if (!keys.containsAlias(tlsAlias)) {
            KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore").apply {
                initialize(KeyGenParameterSpec.Builder(tlsAlias, KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY)
                    .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                    .setDigests(KeyProperties.DIGEST_NONE, KeyProperties.DIGEST_SHA256, KeyProperties.DIGEST_SHA384, KeyProperties.DIGEST_SHA512)
                    .setCertificateSubject(X500Principal("CN=Redmi Mirroring"))
                    .setCertificateSerialNumber(BigInteger(128, SecureRandom()))
                    .setCertificateNotBefore(Date(0)).setCertificateNotAfter(Date(4102444800000L)).build())
                generateKeyPair()
            }
        }
        if (!keys.containsAlias(storageAlias)) {
            KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
                init(KeyGenParameterSpec.Builder(storageAlias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256).build())
                generateKey()
            }
        }
    }

    val fingerprint: String get() = hex(MessageDigest.getInstance("SHA-256").digest(keys.getCertificate(tlsAlias).encoded))
    fun tlsContext(): SSLContext {
        val manager = object : X509ExtendedKeyManager() {
            override fun getClientAliases(keyType: String?, issuers: Array<java.security.Principal>?): Array<String>? = null
            override fun chooseClientAlias(keyType: Array<String>?, issuers: Array<java.security.Principal>?, socket: Socket?): String? = null
            override fun getServerAliases(keyType: String?, issuers: Array<java.security.Principal>?): Array<String>? = if (keyType?.startsWith("EC") == true) arrayOf(tlsAlias) else null
            override fun chooseServerAlias(keyType: String?, issuers: Array<java.security.Principal>?, socket: Socket?): String? = if (keyType?.startsWith("EC") == true) tlsAlias else null
            override fun chooseEngineServerAlias(keyType: String?, issuers: Array<java.security.Principal>?, engine: SSLEngine?): String? = if (keyType?.startsWith("EC") == true) tlsAlias else null
            override fun getCertificateChain(alias: String?): Array<X509Certificate> = arrayOf(keys.getCertificate(tlsAlias) as X509Certificate)
            override fun getPrivateKey(alias: String?): PrivateKey = keys.getKey(tlsAlias, null) as PrivateKey
        }
        return SSLContext.getInstance("TLS").apply { init(arrayOf<KeyManager>(manager), null, SecureRandom()) }
    }

    @Synchronized fun clients(): JSONObject = encrypted("clients") ?: JSONObject()
    @Synchronized fun remote(): JSONObject? = encrypted("remote")
    @Synchronized fun configureRemote(config: JSONObject?) {
        if (config == null) prefs.edit().remove("remote").commit() else save(config, "remote")
    }
    private fun encrypted(field: String): JSONObject? {
        val stored = prefs.getString(field, null) ?: return null
        val bytes = Base64.decode(stored, Base64.NO_WRAP)
        check(bytes.size >= 28) { "Encrypted pairing store is damaged" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, keys.getKey(storageAlias, null) as SecretKey, GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
        cipher.updateAAD((if (field == "clients") id else "$id:$field").toByteArray(Charsets.UTF_8))
        return JSONObject(String(cipher.doFinal(bytes.copyOfRange(12, bytes.size)), Charsets.UTF_8))
    }

    @Synchronized fun approve(clientId: String, clientName: String, secret: String) {
        val clients = clients().put(clientId, JSONObject().put("name", clientName.take(80)).put("secret", secret))
        save(clients)
    }
    @Synchronized fun revoke(clientId: String) { val clients = clients(); clients.remove(clientId); save(clients) }
    private fun save(clients: JSONObject, field: String = "clients") {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, keys.getKey(storageAlias, null) as SecretKey)
        cipher.updateAAD((if (field == "clients") id else "$id:$field").toByteArray(Charsets.UTF_8))
        val sealed = cipher.iv + cipher.doFinal(clients.toString().toByteArray(Charsets.UTF_8))
        check(prefs.edit().putString(field, Base64.encodeToString(sealed, Base64.NO_WRAP)).commit()) { "Cannot save credentials" }
    }

    companion object {
        fun secret(): String = hex(ByteArray(32).apply { SecureRandom().nextBytes(this) })
        fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it.toInt() and 255) }
        fun matches(a: String, b: String): Boolean = a.matches(Regex("[0-9a-f]{64}")) && b.matches(Regex("[0-9a-f]{64}")) && MessageDigest.isEqual(a.toByteArray(Charsets.US_ASCII), b.toByteArray(Charsets.US_ASCII))
    }
}

package com.redmimirroring.companion

import android.Manifest
import android.app.Activity
import android.app.AlertDialog
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.media.projection.MediaProjectionConfig
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.View
import android.view.WindowInsets
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Switch
import android.widget.TextView
import android.widget.EditText
import android.text.InputType
import android.text.method.PasswordTransformationMethod
import org.json.JSONObject
import android.widget.Toast

class MainActivity : Activity() {
    private lateinit var page: LinearLayout
    private var audioRequested = false
    private var shownApproval: MirrorState.Approval? = null
    private var approvalDialog: AlertDialog? = null
    private val dark get() = resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
    private val textForeground get() = if (dark) Color.rgb(238, 238, 236) else Color.rgb(27, 27, 30)
    private val secondary get() = if (dark) Color.rgb(169, 169, 170) else Color.rgb(105, 105, 109)
    private val accent = Color.rgb(232, 76, 48)

    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        // Invitations and pairing approval never appear in screenshots or the mirrored stream.
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        audioRequested = state?.getBoolean("audio") ?: false
    }
    override fun onResume() { super.onResume(); MirrorState.observer = { render() }; render() }
    override fun onPause() { MirrorState.observer = null; super.onPause() }
    override fun onDestroy() { approvalDialog?.dismiss(); super.onDestroy() }
    override fun onSaveInstanceState(state: Bundle) { state.putBoolean("audio", audioRequested); super.onSaveInstanceState(state) }

    private fun render() {
        if (isFinishing) return
        page = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(28), dp(30), dp(28), dp(32))
            setBackgroundColor(if (dark) Color.rgb(22, 22, 24) else Color.rgb(247, 247, 245))
        }
        val scroll = ScrollView(this).apply { isFillViewport = true; addView(page) }
        scroll.setOnApplyWindowInsetsListener { view, insets ->
            if (Build.VERSION.SDK_INT >= 30) {
                val bars = insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
                view.setPadding(bars.left, bars.top, bars.right, bars.bottom)
            } else {
                @Suppress("DEPRECATION") view.setPadding(insets.systemWindowInsetLeft, insets.systemWindowInsetTop, insets.systemWindowInsetRight, insets.systemWindowInsetBottom)
            }
            insets
        }
        setContentView(scroll)
        label("Redmi", 16, accent, bold = true)
        label("Mirroring", 34, textForeground, bold = true, bottom = 5)
        label("Your phone. At home on your Mac.", 16, secondary, bottom = 28)
        val connected = MirrorState.service != null
        label(MirrorState.status, 16, if (connected) accent else secondary, bold = true, bottom = 8)
        val phoneName = runCatching { Identity(this).name }.getOrDefault(android.os.Build.MODEL)
        label("$phoneName · Android ${android.os.Build.VERSION.RELEASE}", 13, secondary, bottom = 30)

        label("1  Connect your Mac", 19, textForeground, bold = true, bottom = 8)
        label("Pair once with a private invitation. Only a Mac you approve on this phone can connect.", 14, secondary, bottom = 12)
        button(if (connected) "Create pairing invitation" else "Make phone available & pair") { ensureAvailable { showInvitation() } }
        if (connected) {
            val addresses = runCatching { MirrorState.service!!.server.addresses() }.getOrDefault(emptyList())
            label(addresses.joinToString(" · ") { "$it:${MirrorServer.PORT}" }, 12, secondary, bottom = 18)
        }

        divider()
        label("2  Allow phone control", 19, textForeground, bold = true, bottom = 8)
        label(if (ControlService.current != null) "Control is enabled. Your Mac can tap, swipe, scroll and type while this phone is unlocked."
            else "Enable the Redmi Mirroring accessibility service so your paired Mac can tap, swipe and type.", 14, secondary, bottom = 12)
        button(if (ControlService.current != null) "Review control permission" else "Enable control") {
            AlertDialog.Builder(this).setTitle("Allow your Mac to control this phone")
                .setMessage("Redmi Mirroring uses Android Accessibility to read the focused text field, perform touch gestures and send keyboard input. Only explicitly paired Macs can send these commands. Control is refused while this phone is securely locked.\n\nIn the next screen, choose Redmi Mirroring control and enable it. You can revoke this permission at any time. If HyperOS marks this APK as restricted, review Allow restricted settings in this app's App info menu first.")
                .setNegativeButton("Cancel", null).setPositiveButton("Open settings") { _, _ -> startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)) }.show()
        }

        divider()
        label("3  Share your screen", 19, textForeground, bold = true, bottom = 8)
        label("Android asks you to approve each new screen-sharing session. A live session can reconnect to your Mac without another approval.", 14, secondary, bottom = 12)
        val toggle = Switch(this).apply {
            text = "Include supported app audio"
            textSize = 14f; setTextColor(textForeground); isChecked = audioRequested
            setOnCheckedChangeListener { _, checked -> audioRequested = checked }
        }
        page.addView(toggle, LinearLayout.LayoutParams(-1, -2).apply { bottomMargin = dp(10) })
        if (MirrorState.service?.capture?.active == true) {
            button("Stop screen sharing") { MirrorState.service?.capture?.stop() }
            label("${MirrorState.service?.capture?.width} × ${MirrorState.service?.capture?.height} · ${MirrorState.service?.capture?.fps} fps target\nReturn to your Home screen to show it on your Mac. This setup screen is protected from capture.", 12, secondary, bottom = 14)
        } else button("Start screen sharing", primary = true) { requestCapture() }

        val identity = runCatching { Identity(this) }.getOrNull()
        val clients = runCatching { identity?.clients() }.getOrNull()
        if (clients != null && clients.length() > 0) {
            divider(); label("Paired Macs", 19, textForeground, bold = true, bottom = 10)
            clients.keys().forEach { id ->
                val name = clients.getJSONObject(id).optString("name", "Mac")
                button("$name  ·  Unpair") {
                    AlertDialog.Builder(this).setTitle("Unpair $name?").setMessage("This Mac will disconnect immediately and need a new invitation to connect again.")
                        .setNegativeButton("Cancel", null).setPositiveButton("Unpair") { _, _ ->
                            if (MirrorState.service != null) MirrorState.service?.server?.revoke(id) else identity?.revoke(id)
                            render()
                        }.show()
                }
            }
        }
        if (connected) {
            divider()
            button("Send phone clipboard to Mac") {
                val clip = getSystemService(ClipboardManager::class.java).primaryClip
                val text = if (clip != null && clip.itemCount > 0) clip.getItemAt(0).coerceToText(this)?.toString() else null
                if (text == null) toast("Copy some text on your phone first.") else {
                    val sent = MirrorState.service?.server?.sendClipboard(text) == true
                    toast(if (sent) "Clipboard sent. Enable Receive phone clipboard in Mac settings." else "Connect your paired Mac first; clipboard text must be under 1 MiB.")
                }
            }
            button("Stop availability") { stopService(Intent(this, MirrorService::class.java)) }
        }
        divider()
        label("Remote access", 19, textForeground, bold = true, bottom = 8)
        val configured = runCatching { identity?.remote() != null }.getOrDefault(false)
        label(if (configured) "A private relay is configured. Your phone connects outward; the paired Mac still authenticates directly to this phone inside the encrypted tunnel."
            else "Use a private VPN address, or configure a private relay you operate to reach your phone across networks. A relay server must be set up separately; this app does not create a cloud account or subscription.", 13, secondary, bottom = 12)
        button(if (configured) "Review remote relay" else "Configure private relay") { remoteSettings() }
        divider()
        label("A few Android realities", 15, textForeground, bold = true, bottom = 8)
        label("Keep this phone unlocked while mirroring. Locking or turning off the screen stops sharing; secure screens may appear black. Audio depends on each app's capture policy. Files from your Mac are saved in Downloads / Redmi Mirroring.", 13, secondary, bottom = 12)
        label("For reliable reconnection on HyperOS, review this app's Battery saver and Background autostart settings. Restart sharing after the app is force-stopped or the phone restarts. Remote connections require a private VPN or configured relay; never forward this service or ADB to the public Internet.", 13, secondary, bottom = 12)
        button("Open app settings") { startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, android.net.Uri.parse("package:$packageName"))) }
        showPendingApproval()
    }

    private fun ensureAvailable(ready: () -> Unit) {
        if (MirrorState.service != null) { ready(); return }
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED)
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 8)
        startForegroundService(Intent(this, MirrorService::class.java))
        MirrorState.main.postDelayed({ if (MirrorState.service != null) ready() else toast("The companion could not start. Reopen it and try again.") }, 500)
    }
    private fun showInvitation() {
        try {
            val uri = MirrorState.service!!.server.invitation()
            val text = TextView(this).apply {
                this.text = uri; textSize = 12f; setTextColor(textForeground); setTextIsSelectable(true); setPadding(dp(20), dp(16), dp(20), dp(16))
            }
            AlertDialog.Builder(this).setTitle("Pair your Mac")
                .setMessage("In Redmi Mirroring on your Mac, choose Pair a phone and paste this invitation. It expires in 5 minutes. Then approve the Mac here.\n\nKeep this invitation private; it authorizes a pairing request.")
                .setView(ScrollView(this).apply { addView(text) }).setNegativeButton("Done", null)
                .setNeutralButton("Share privately") { _, _ ->
                    startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, uri).putExtra(Intent.EXTRA_SUBJECT, "Private Redmi Mirroring invitation"), "Send only to your Mac"))
                }
                .setPositiveButton("Copy invitation") { _, _ ->
                    val clip = ClipData.newPlainText("Private mirroring invitation", uri)
                    if (Build.VERSION.SDK_INT >= 33) clip.description.extras = android.os.PersistableBundle().apply { putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true) }
                    getSystemService(ClipboardManager::class.java).setPrimaryClip(clip)
                    toast("Invitation copied. Transfer it privately to your Mac.")
                }.show()
        } catch (e: Exception) { toast(e.message ?: "Pairing is unavailable") }
    }
    private fun showPendingApproval() {
        val pending = MirrorState.pending
        if (pending == null) { approvalDialog?.dismiss(); approvalDialog = null; shownApproval = null; return }
        if (shownApproval === pending) return
        approvalDialog?.dismiss(); shownApproval = pending
        approvalDialog = AlertDialog.Builder(this).setTitle("Pair ${pending.name}?")
            .setMessage("This Mac at ${pending.address} has your private invitation. Approving allows it to see your shared screen, receive supported audio, send files and control this unlocked phone when you enable control.\n\nApprove only if you initiated this pairing. Revoke it here at any time.")
            .setNegativeButton("Decline") { _, _ -> pending.finish(false) }
            .setPositiveButton("Approve Mac") { _, _ -> pending.finish(true) }
            .setOnCancelListener { pending.finish(false) }.create().apply { show() }
    }
    private fun remoteSettings() {
        val identity = Identity(this)
        val existing = runCatching { identity.remote() }.getOrNull()
        val form = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(22), dp(12), dp(22), dp(12)) }
        fun field(hint: String, value: String, secret: Boolean = false): EditText {
            return EditText(this).apply {
                this.hint = hint; setText(value); textSize = 13f; setTextColor(textForeground); isSingleLine = true
                inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
                importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO
                if (secret) transformationMethod = PasswordTransformationMethod.getInstance()
                form.addView(this, LinearLayout.LayoutParams(-1, dp(56)))
            }
        }
        val host = field("Relay address", existing?.optString("host") ?: "")
        val port = field("Port", existing?.optInt("port")?.toString() ?: "443").apply { inputType = InputType.TYPE_CLASS_NUMBER }
        val fingerprint = field("Certificate SHA-256 fingerprint", existing?.optString("fingerprint") ?: "")
        val room = field("Private room token (64 hex characters)", existing?.optString("room") ?: "", true)
        AlertDialog.Builder(this).setTitle("Private remote relay")
            .setMessage("Enter the configuration from your private relay administrator, and the same room on your Mac. Verify the certificate fingerprint privately. Credentials stay encrypted in Android Keystore. Pair this Mac locally first. Internet relay deployment and real remote performance require separate testing.")
            .setView(form).setNegativeButton("Cancel", null)
            .setNeutralButton("Disable") { _, _ -> identity.configureRemote(null); MirrorState.service?.startRemote(); render() }
            .setPositiveButton("Save") { _, _ ->
                val cleanHost = host.text.toString().trim()
                val cleanPort = port.text.toString().toIntOrNull() ?: 0
                val pin = fingerprint.text.toString().replace(":", "").lowercase()
                val token = room.text.toString().trim().lowercase()
                if (cleanHost.isBlank() || cleanHost.length > 253 || cleanHost.any { it.isWhitespace() || it == '/' } || cleanPort !in 1..65535 || !pin.matches(Regex("[0-9a-f]{64}")) || !token.matches(Regex("[0-9a-f]{64}"))) {
                    toast("Enter a relay address, valid port, 64-character certificate fingerprint and private room token.")
                } else {
                    identity.configureRemote(JSONObject().put("host", cleanHost).put("port", cleanPort).put("fingerprint", pin).put("room", token))
                    MirrorState.service?.startRemote(); render()
                }
            }.show()
    }
    private fun requestCapture() {
        if (MirrorState.service?.capture?.active == true) return
        if (audioRequested && checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), 9); return
        }
        val manager = getSystemService(MediaProjectionManager::class.java)
        val request = if (Build.VERSION.SDK_INT >= 34) manager.createScreenCaptureIntent(MediaProjectionConfig.createConfigForDefaultDisplay()) else manager.createScreenCaptureIntent()
        @Suppress("DEPRECATION") startActivityForResult(request, 10)
    }
    @Deprecated("Native Activity result API")
    override fun onActivityResult(request: Int, result: Int, data: Intent?) {
        super.onActivityResult(request, result, data)
        if (request == 10 && result == RESULT_OK && data != null) {
            startForegroundService(Intent(this, MirrorService::class.java).putExtra("capture", data).putExtra("result", result).putExtra("audio", audioRequested))
            MirrorState.main.postDelayed({ moveTaskToBack(true) }, 700)
        }
    }
    override fun onRequestPermissionsResult(request: Int, permissions: Array<out String>, results: IntArray) {
        super.onRequestPermissionsResult(request, permissions, results)
        if (request == 9) {
            if (results.firstOrNull() != PackageManager.PERMISSION_GRANTED) { audioRequested = false; toast("Sharing without audio") }
            requestCapture()
        }
    }
    private fun label(text: String, size: Int, color: Int, bold: Boolean = false, bottom: Int = 0) {
        page.addView(TextView(this).apply {
            this.text = text; textSize = size.toFloat(); setTextColor(color); setLineSpacing(dp(3).toFloat(), 1f)
            if (bold) typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        }, LinearLayout.LayoutParams(-1, -2).apply { bottomMargin = dp(bottom) })
    }
    private fun button(text: String, primary: Boolean = false, click: () -> Unit) {
        page.addView(Button(this).apply {
            this.text = text; isAllCaps = false; textSize = 14f; gravity = android.view.Gravity.CENTER
            setTextColor(if (primary) Color.WHITE else textForeground)
            background = GradientDrawable().apply { cornerRadius = dp(12).toFloat(); setColor(if (primary) accent else if (dark) Color.rgb(43, 43, 47) else Color.WHITE); if (!primary) setStroke(dp(1), if (dark) Color.rgb(62, 62, 66) else Color.rgb(226, 226, 223)) }
            setOnClickListener { click() }
        }, LinearLayout.LayoutParams(-1, dp(50)).apply { bottomMargin = dp(10) })
    }
    private fun divider() { page.addView(View(this).apply { setBackgroundColor(if (dark) Color.rgb(59, 59, 63) else Color.rgb(225, 225, 221)) }, LinearLayout.LayoutParams(-1, dp(1)).apply { topMargin = dp(20); bottomMargin = dp(24) }) }
    private fun toast(message: String) { Toast.makeText(this, message, Toast.LENGTH_LONG).show() }
    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
}

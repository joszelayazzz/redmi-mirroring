package com.redmimirroring.companion

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.IBinder

class MirrorService : Service() {
    lateinit var server: MirrorServer; private set
    var capture: ScreenCapture? = null; private set
    private var stopping = false
    private val remote = RemoteTunnel()
    private var remoteStarted = false
    private val lockReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == Intent.ACTION_SCREEN_OFF) { capture?.stop(); MirrorState.update("Phone screen turned off. Unlock and approve sharing to resume.") }
        }
    }
    override fun onCreate() {
        super.onCreate()
        MirrorState.service = this
        getSystemService(NotificationManager::class.java).createNotificationChannel(NotificationChannel("mirror", "Mirroring connection", NotificationManager.IMPORTANCE_LOW))
        server = MirrorServer(this, Identity(this))
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(lockReceiver, IntentFilter(Intent.ACTION_SCREEN_OFF), RECEIVER_NOT_EXPORTED)
        else registerReceiver(lockReceiver, IntentFilter(Intent.ACTION_SCREEN_OFF))
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "stop") { stopSelf(); return START_NOT_STICKY }
        val captureData = if (Build.VERSION.SDK_INT >= 33) intent?.getParcelableExtra("capture", Intent::class.java) else {
            @Suppress("DEPRECATION") intent?.getParcelableExtra<Intent>("capture")
        }
        val types = ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE or if (captureData != null || capture != null) ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION else 0
        startForeground(1, notification(), types)
        server.start()
        if (!remoteStarted) startRemote()
        if (captureData != null && capture == null) {
            try {
                val projection = requireNotNull(getSystemService(MediaProjectionManager::class.java).getMediaProjection(intent!!.getIntExtra("result", -1), captureData))
                val session = ScreenCapture(this, projection, server, intent.getBooleanExtra("audio", false)) {
                    capture = null
                    if (!stopping) startForeground(1, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
                    MirrorState.update()
                }
                capture = session; session.start()
            } catch (e: Exception) { MirrorState.update("Approve screen sharing again: ${e.javaClass.simpleName}") }
        }
        MirrorState.update()
        return START_NOT_STICKY
    }
    private fun notification(): Notification {
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val stop = PendingIntent.getService(this, 1, Intent(this, MirrorService::class.java).setAction("stop"), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        return Notification.Builder(this, "mirror").setSmallIcon(com.redmimirroring.companion.R.drawable.app_icon)
            .setContentTitle("Redmi Mirroring is available")
            .setContentText(if (MirrorState.pending != null) "Tap to approve or decline ${MirrorState.pending?.name}." else "Only Macs you approve can connect. Tap to manage sharing.")
            .setContentIntent(open).setOngoing(true).addAction(Notification.Action.Builder(null, "Stop", stop).build()).build()
    }
    override fun onBind(intent: Intent?): IBinder? = null
    fun refreshNotification() { if (!stopping) getSystemService(NotificationManager::class.java).notify(1, notification()) }
    fun startRemote() {
        remote.stop(); remoteStarted = true
        val config = runCatching { server.identity.remote() }.getOrNull() ?: return
        remote.start(config.getString("host"), config.getInt("port"), config.getString("fingerprint"), config.getString("room")) { message -> MirrorState.update(message) }
    }
    override fun onDestroy() {
        stopping = true
        remote.stop()
        capture?.stop()
        server.close()
        runCatching { unregisterReceiver(lockReceiver) }
        MirrorState.service = null
        MirrorState.update("Mirroring stopped")
        super.onDestroy()
    }
}

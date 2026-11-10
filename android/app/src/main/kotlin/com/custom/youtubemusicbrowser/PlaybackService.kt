package com.custom.youtubemusicbrowser

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import android.os.PowerManager

/**
 * Foreground service that keeps the process (and the WebView's audio) alive in the
 * background and exposes a [MediaSession], so the lock screen, Bluetooth headphones
 * and smartwatches (via the phone's media controls) can play / pause / skip / search.
 */
class PlaybackService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    private var session: MediaSession? = null

    private var playing = false
    private var title = ""
    private var artist = ""

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        title = applicationInfo.loadLabel(packageManager).toString()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).createNotificationChannel(
                NotificationChannel(CHANNEL, "Playback", NotificationManager.IMPORTANCE_LOW)
            )
        }
        session = MediaSession(this, "ytmb").apply {
            setCallback(object : MediaSession.Callback() {
                override fun onPlay() = send("play")
                override fun onPause() = send("pause")
                override fun onStop() = send("pause")
                override fun onSkipToNext() = send("next")
                override fun onSkipToPrevious() = send("previous")
                override fun onPlayFromSearch(query: String?, extras: Bundle?) =
                    if (query.isNullOrBlank()) send("play") else send("search", query)
            })
            isActive = true
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_PLAY, ACTION_PAUSE, ACTION_NEXT, ACTION_PREV -> {
                // Notification button pressed: forward to the page.
                send(intent.action!!.removePrefix("ytmb."))
            }
            else -> {
                playing = intent?.getBooleanExtra("playing", playing) ?: playing
                intent?.getStringExtra("title")?.takeIf { it.isNotBlank() }?.let { title = it }
                intent?.getStringExtra("artist")?.let { artist = it }
            }
        }
        publish()
        return START_NOT_STICKY
    }

    private fun publish() {
        val s = session ?: return
        s.setMetadata(
            MediaMetadata.Builder()
                .putString(MediaMetadata.METADATA_KEY_TITLE, title)
                .putString(MediaMetadata.METADATA_KEY_ARTIST, artist)
                .build()
        )
        val actions = PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or
            PlaybackState.ACTION_PLAY_PAUSE or PlaybackState.ACTION_STOP or
            PlaybackState.ACTION_SKIP_TO_NEXT or PlaybackState.ACTION_SKIP_TO_PREVIOUS or
            PlaybackState.ACTION_PLAY_FROM_SEARCH
        s.setPlaybackState(
            PlaybackState.Builder()
                .setActions(actions)
                .setState(
                    if (playing) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED,
                    PlaybackState.PLAYBACK_POSITION_UNKNOWN, 1f
                )
                .build()
        )

        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            Notification.Builder(this, CHANNEL) else Notification.Builder(this)
        val notification = builder
            .setContentTitle(title)
            .setContentText(artist.ifBlank { if (playing) "Playing" else "Paused" })
            .setSmallIcon(if (playing) android.R.drawable.ic_media_play else android.R.drawable.ic_media_pause)
            .setContentIntent(open)
            .setOngoing(playing)
            .addAction(action(android.R.drawable.ic_media_previous, "Previous", ACTION_PREV))
            .addAction(
                if (playing) action(android.R.drawable.ic_media_pause, "Pause", ACTION_PAUSE)
                else action(android.R.drawable.ic_media_play, "Play", ACTION_PLAY)
            )
            .addAction(action(android.R.drawable.ic_media_next, "Next", ACTION_NEXT))
            .setStyle(
                Notification.MediaStyle()
                    .setMediaSession(s.sessionToken)
                    .setShowActionsInCompactView(0, 1, 2)
            )
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        } else {
            startForeground(ID, notification)
        }

        // Only hold the CPU awake while audio is actually playing.
        if (playing) {
            if (wakeLock == null) {
                val pm = getSystemService(POWER_SERVICE) as PowerManager
                wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "ytmb:playback")
                    .apply { setReferenceCounted(false) }
            }
            wakeLock?.acquire(6 * 60 * 60 * 1000L)
        } else {
            wakeLock?.let { if (it.isHeld) it.release() }
        }
    }

    private fun action(icon: Int, label: String, act: String): Notification.Action {
        val pi = PendingIntent.getService(
            this, act.hashCode(), Intent(this, PlaybackService::class.java).setAction(act),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        return Notification.Action.Builder(Icon.createWithResource(this, icon), label, pi).build()
    }

    private fun send(cmd: String, arg: String? = null) {
        commandSink?.invoke(cmd, arg)
    }

    override fun onDestroy() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        session?.run { isActive = false; release() }
        session = null
        super.onDestroy()
    }

    companion object {
        const val CHANNEL = "playback"
        const val ID = 1
        const val ACTION_PLAY = "ytmb.play"
        const val ACTION_PAUSE = "ytmb.pause"
        const val ACTION_NEXT = "ytmb.next"
        const val ACTION_PREV = "ytmb.previous"

        /** Set by MainActivity; forwards (command, arg) to Dart. */
        @JvmStatic
        var commandSink: ((String, String?) -> Unit)? = null
    }
}

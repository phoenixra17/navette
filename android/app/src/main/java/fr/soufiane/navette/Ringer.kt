package fr.soufiane.navette

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.Handler
import android.os.Looper
import android.os.VibrationAttributes
import android.os.VibrationEffect
import android.os.VibratorManager
import android.util.Log

/**
 * « Faire sonner le téléphone » depuis le Mac : sonnerie d'alarme au volume maximum, même en
 * mode silencieux (le flux alarme n'est pas coupé par le mode silencieux), pendant une minute
 * au plus. Le volume d'alarme d'origine est rétabli à l'arrêt.
 */
object Ringer {
    private const val TAG = "NavetteSonnerie"
    private const val CHANNEL_ID = "sonnerie"
    private const val NOTIF_ID = 2
    private const val MAX_MS = 60_000L

    private val main = Handler(Looper.getMainLooper())
    private var player: MediaPlayer? = null
    private var ringing = false
    private var savedVolume: Int? = null
    private var appContext: Context? = null
    private val autoStop = Runnable { appContext?.let { stop(it) } }

    fun start(context: Context) {
        if (ringing) return
        ringing = true
        val app = context.applicationContext
        appContext = app
        val audio = app.getSystemService(AudioManager::class.java)
        savedVolume = audio.getStreamVolume(AudioManager.STREAM_ALARM)
        runCatching { audio.setStreamVolume(AudioManager.STREAM_ALARM, audio.getStreamMaxVolume(AudioManager.STREAM_ALARM), 0) }

        val uri = RingtoneManager.getActualDefaultRingtoneUri(app, RingtoneManager.TYPE_ALARM)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
        player = runCatching {
            MediaPlayer().apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ALARM)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build(),
                )
                setDataSource(app, uri)
                isLooping = true
                prepare()
                start()
            }
        }.onFailure { Log.w(TAG, "lecture impossible", it) }.getOrNull()

        app.getSystemService(VibratorManager::class.java).defaultVibrator.vibrate(
            VibrationEffect.createWaveform(longArrayOf(0, 800, 500), 0),
            VibrationAttributes.createForUsage(VibrationAttributes.USAGE_ALARM),
        )
        showNotification(app)
        main.postDelayed(autoStop, MAX_MS)
    }

    fun stop(context: Context) {
        if (!ringing) return
        ringing = false
        val app = context.applicationContext
        main.removeCallbacks(autoStop)
        player?.let { runCatching { it.stop() }; it.release() }
        player = null
        app.getSystemService(VibratorManager::class.java).defaultVibrator.cancel()
        savedVolume?.let { volume ->
            runCatching { app.getSystemService(AudioManager::class.java).setStreamVolume(AudioManager.STREAM_ALARM, volume, 0) }
        }
        savedVolume = null
        app.getSystemService(NotificationManager::class.java).cancel(NOTIF_ID)
    }

    private fun showNotification(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Faire sonner", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "Quand le Mac fait sonner le téléphone pour le retrouver"
                setSound(null, null) // le son vient du lecteur, pas de la notification
            },
        )
        val stopIntent = PendingIntent.getBroadcast(
            context, 0, Intent(context, StopRingReceiver::class.java), PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = Notification.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_navette)
            .setContentTitle("Le Mac fait sonner le téléphone")
            .setContentText("Touchez pour arrêter")
            .setContentIntent(stopIntent)
            .setDeleteIntent(stopIntent)
            .addAction(Notification.Action.Builder(null, "Arrêter", stopIntent).build())
            .setCategory(Notification.CATEGORY_ALARM)
            .build()
        manager.notify(NOTIF_ID, notification)
    }
}

/** Bouton « Arrêter » (ou notification balayée) de la sonnerie. */
class StopRingReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) = Ringer.stop(context)
}

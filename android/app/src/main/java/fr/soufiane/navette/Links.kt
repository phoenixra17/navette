package fr.soufiane.navette

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.util.Patterns
import android.widget.Toast
import org.json.JSONObject

/** Liens échangés entre le Mac et le téléphone (façon Handoff). */
object Links {
    private const val CHANNEL_ID = "liens"

    /** Premier lien http(s) trouvé dans un texte partagé (Chrome envoie « titre + lien », par ex.). */
    fun extractUrl(text: String?): String? {
        if (text == null) return null
        val matcher = Patterns.WEB_URL.matcher(text)
        while (matcher.find()) {
            val found = matcher.group()
            val url = if (found.startsWith("http://", true) || found.startsWith("https://", true)) found else "https://$found"
            if (Uri.parse(url).host != null) return url
        }
        return null
    }

    /** Lien envoyé par le Mac : on l'ouvre directement si possible, sinon on propose une notification. */
    fun open(context: Context, url: String) {
        val uri = Uri.parse(url)
        if (uri.scheme != "http" && uri.scheme != "https") return // jamais d'autre schéma venu du réseau
        val view = Intent(Intent.ACTION_VIEW, uri)
        if (BackgroundLauncher.start(context, view)) return

        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Liens du Mac", NotificationManager.IMPORTANCE_HIGH),
        )
        val pending = PendingIntent.getActivity(
            context, url.hashCode(), view.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK), PendingIntent.FLAG_IMMUTABLE,
        )
        manager.notify(
            url.hashCode(),
            Notification.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_navette)
                .setContentTitle("Lien envoyé par le Mac")
                .setContentText(uri.host + (uri.path ?: ""))
                .setContentIntent(pending)
                .setAutoCancel(true)
                .build(),
        )
    }
}

/** « Partager › Ouvrir sur le Mac » : ouvre le lien dans le navigateur du Mac. */
class OpenOnMacActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val url = Links.extractUrl(intent?.getStringExtra(Intent.EXTRA_TEXT))
        val app = applicationContext
        if (url == null) {
            Toast.makeText(app, "Aucun lien à ouvrir", Toast.LENGTH_SHORT).show()
        } else {
            Relay.sendPayload(Settings(app), JSONObject().put("kind", "url").put("url", url), ephemeral = true) { error ->
                Toast.makeText(app, error ?: "Ouvert sur le Mac ✓", Toast.LENGTH_SHORT).show()
            }
        }
        finish()
        overrideActivityTransition(OVERRIDE_TRANSITION_CLOSE, 0, 0)
    }
}

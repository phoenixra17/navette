package fr.soufiane.navette

import android.app.Notification
import android.app.NotificationManager
import android.app.Person
import android.app.RemoteInput
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.Bundle
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.util.Base64

/**
 * Transmet les notifications du téléphone au Mac, et exécute depuis le Mac les réponses rapides
 * (bouton « Répondre » de WhatsApp, Messages…) et les suppressions.
 * L'accès aux notifications s'active dans les réglages Android : c'est une autorisation officielle.
 */
class NotifListener : NotificationListenerService() {
    private lateinit var settings: Settings

    /** Action « Répondre » de chaque notification transmise, par clé. */
    private val replyActions = object : LinkedHashMap<String, Notification.Action>(64, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Notification.Action>?) = size > 200
    }

    /** Empreinte du dernier contenu transmis, pour ne pas renvoyer une mise à jour identique. */
    private val sent = object : LinkedHashMap<String, Int>(64, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Int>?) = size > 500
    }

    /** Heure de la dernière réponse envoyée depuis le Mac, par clé. */
    private val repliedAt = HashMap<String, Long>()

    override fun onCreate() {
        super.onCreate()
        settings = Settings(this)
    }

    override fun onListenerConnected() {
        instance = this
    }

    override fun onListenerDisconnected() {
        if (instance === this) instance = null
    }

    override fun onNotificationPosted(sbn: StatusBarNotification, rankingMap: RankingMap) {
        if (!settings.isPaired || !settings.forwardNotifications) return
        if (sbn.packageName == packageName || sbn.isOngoing) return
        val n = sbn.notification
        if (n.flags and Notification.FLAG_GROUP_SUMMARY != 0) return
        if (n.category in IGNORED_CATEGORIES) return
        // Les notifications silencieuses (importance basse) restent sur le téléphone.
        val ranking = Ranking()
        if (rankingMap.getRanking(sbn.key, ranking) && ranking.importance < NotificationManager.IMPORTANCE_DEFAULT) return

        val extras = n.extras
        val title = (extras.getCharSequence(Notification.EXTRA_CONVERSATION_TITLE)
            ?: extras.getCharSequence(Notification.EXTRA_TITLE))?.toString()?.trim().orEmpty()
        val text = extractText(extras).trim()
        if (title.isEmpty() && text.isEmpty()) return

        val signature = (title + "\u0000" + text).hashCode()
        if (sent[sbn.key] == signature) return
        sent[sbn.key] = signature

        // Après une réponse, WhatsApp & co. mettent à jour la notification avec VOTRE message :
        // ce n'est pas un nouveau message à afficher sur le Mac.
        if (lastMessageIsMine(extras)) return
        repliedAt[sbn.key]?.let { if (System.currentTimeMillis() - it < REPLY_QUIET_MS) return }

        val reply = n.actions?.firstOrNull { action ->
            action.remoteInputs?.any { it.allowFreeFormInput } == true
        }
        if (reply != null) replyActions[sbn.key] = reply else replyActions.remove(sbn.key)

        val payload = JSONObject()
            .put("kind", "notif")
            .put("key", sbn.key)
            .put("pkg", sbn.packageName)
            .put("app", appLabel(sbn.packageName))
            .put("title", title.take(200))
            .put("text", text.take(2000))
            .put("canReply", reply != null)
        appIcon(sbn.packageName)?.let { payload.put("icon", it) }
        Relay.sendPayload(settings, payload, ephemeral = true)
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        replyActions.remove(sbn.key)
        repliedAt.remove(sbn.key)
        if (sent.remove(sbn.key) == null) return // jamais transmise
        Relay.sendPayload(settings, JSONObject().put("kind", "notif-removed").put("key", sbn.key), ephemeral = true)
    }

    /** Réponse tapée sur le Mac. Renvoie false si la notification a disparu entre-temps. */
    fun reply(key: String, text: String): Boolean {
        val action = replyActions[key] ?: return false
        val inputs = action.remoteInputs ?: return false
        val results = Bundle()
        inputs.filter { it.allowFreeFormInput }.forEach { results.putCharSequence(it.resultKey, text) }
        val intent = Intent()
        RemoteInput.addResultsToIntent(inputs, intent, results)
        repliedAt[key] = System.currentTimeMillis()
        return runCatching { action.actionIntent.send(this, 0, intent) }
            .onFailure { Log.w(TAG, "réponse refusée", it) }
            .isSuccess
    }

    /** Notification effacée sur le Mac : on l'efface aussi sur le téléphone. */
    fun dismiss(key: String) {
        sent.remove(key) // pas la peine de prévenir le Mac en retour
        runCatching { cancelNotification(key) }
    }

    /**
     * Dans une conversation (MessagingStyle), les messages de l'utilisateur n'ont pas d'expéditeur,
     * ou ont pour expéditeur la personne « utilisateur » de la notification (EXTRA_MESSAGING_PERSON).
     */
    private fun lastMessageIsMine(extras: Bundle): Boolean {
        @Suppress("DEPRECATION")
        val last = extras.getParcelableArray(Notification.EXTRA_MESSAGES)?.lastOrNull() as? Bundle ?: return false
        val sender = last.getParcelable("sender_person", Person::class.java)
        if (sender == null && last.getCharSequence("sender") == null) return true
        val me = extras.getParcelable(Notification.EXTRA_MESSAGING_PERSON, Person::class.java) ?: return false
        return (sender?.key != null && sender.key == me.key) || (sender?.name != null && sender.name == me.name)
    }

    private fun extractText(extras: Bundle): String {
        // Messagerie (WhatsApp, Messages…) : les derniers messages avec leur expéditeur.
        @Suppress("DEPRECATION")
        val messages = extras.getParcelableArray(Notification.EXTRA_MESSAGES)
        if (!messages.isNullOrEmpty()) {
            return messages.takeLast(3).mapNotNull { item ->
                val bundle = item as? Bundle ?: return@mapNotNull null
                val body = bundle.getCharSequence("text") ?: return@mapNotNull null
                val sender = bundle.getParcelable("sender_person", Person::class.java)?.name
                    ?: bundle.getCharSequence("sender")
                if (sender.isNullOrBlank()) body.toString() else "$sender : $body"
            }.joinToString("\n")
        }
        extras.getCharSequenceArray(Notification.EXTRA_TEXT_LINES)?.takeIf { it.isNotEmpty() }?.let { lines ->
            return lines.takeLast(5).joinToString("\n")
        }
        return (extras.getCharSequence(Notification.EXTRA_BIG_TEXT)
            ?: extras.getCharSequence(Notification.EXTRA_TEXT))?.toString().orEmpty()
    }

    /** Icône de l'app en PNG 96 px (base64), gardée en mémoire : quelques Ko par notification. */
    private val icons = HashMap<String, String?>()

    private fun appIcon(pkg: String): String? = icons.getOrPut(pkg) {
        runCatching {
            val drawable = packageManager.getApplicationIcon(pkg)
            val bitmap = Bitmap.createBitmap(ICON_PX, ICON_PX, Bitmap.Config.ARGB_8888)
            drawable.setBounds(0, 0, ICON_PX, ICON_PX)
            drawable.draw(Canvas(bitmap))
            val out = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
            Base64.getEncoder().encodeToString(out.toByteArray())
        }.getOrNull()
    }

    private fun appLabel(pkg: String): String = runCatching {
        packageManager.getApplicationLabel(packageManager.getApplicationInfo(pkg, 0)).toString()
    }.getOrDefault(pkg)

    companion object {
        private const val TAG = "NavetteNotifs"
        private const val ICON_PX = 96
        private const val REPLY_QUIET_MS = 15_000L

        private val IGNORED_CATEGORIES = setOf(
            Notification.CATEGORY_TRANSPORT, // lecteur de musique
            Notification.CATEGORY_PROGRESS,
            Notification.CATEGORY_SERVICE,
            Notification.CATEGORY_SYSTEM,
            Notification.CATEGORY_NAVIGATION,
        )

        @Volatile var instance: NotifListener? = null
            private set

        fun isEnabled(context: Context): Boolean =
            context.getSystemService(NotificationManager::class.java)
                .isNotificationListenerAccessGranted(ComponentName(context, NotifListener::class.java))
    }
}

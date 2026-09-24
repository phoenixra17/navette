package fr.soufiane.navette

import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.provider.Settings as AndroidSettings
import android.util.Log
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Envoi automatique des copies faites sur le téléphone, malgré le blocage d'Android 10+.
 *
 * 1. Détection : on s'abonne aux changements du presse-papier. Android refuse de nous prévenir
 *    (app en arrière-plan) mais journalise « Denying clipboard access to fr.soufiane.navette ».
 *    Avec READ_LOGS (accordée une fois par ADB), on lit ce refus dans logcat : c'est le signal.
 * 2. Lecture : une activité transparente (ReadClipboardActivity) passe un instant au premier plan,
 *    lit le presse-papier et se ferme (lancée via BackgroundLauncher).
 *
 * Même principe que KDE Connect. Requiert READ_LOGS (ADB) et « Apparaître au-dessus » (réglages).
 */
class AutoCopy(
    private val context: Context,
    private val onAccessChanged: () -> Unit,
    private val onContent: (ClipContent) -> Unit,
) {
    private val main = Handler(Looper.getMainLooper())
    private val clipboard = context.getSystemService(ClipboardManager::class.java)
    private val noopListener = ClipboardManager.OnPrimaryClipChangedListener { }

    @Volatile private var running = false
    @Volatile private var logcat: Process? = null

    /**
     * Android 13+ demande à l'utilisateur d'autoriser chaque nouvelle lecture des journaux, et la
     * refuse d'office si l'app n'est pas au premier plan (ex. service relancé après un redémarrage).
     * Une sonde vérifie qu'on voit bien les journaux du système ; sinon, il faut ouvrir Navette.
     */
    enum class Access { CHECKING, GRANTED, DENIED }

    @Volatile var access = Access.CHECKING
        private set

    /** Ignore les changements provoqués par nos propres écritures (réception depuis le Mac). */
    @Volatile var ignoreUntil = 0L

    fun start() {
        if (running || !isAvailable(context)) return
        running = true
        clipboard.addPrimaryClipChangedListener(noopListener)
        startReader()
    }

    /** À appeler quand Navette passe au premier plan : c'est le seul moment où Android peut
     *  afficher la demande d'accès aux journaux. */
    fun retryIfDenied() {
        // Pas pendant CHECKING : la fermeture de la demande d'accès fait revenir l'écran principal,
        // et relancer à ce moment redemanderait l'accès en boucle.
        if (!running || access != Access.DENIED) return
        logcat?.destroy() // le fil de lecture relance aussitôt un nouveau logcat
    }

    private fun startReader() {
        Thread({ readLogcat() }, "navette-logcat").start()
    }

    private fun setAccess(value: Access) {
        if (access == value) return
        access = value
        main.post(onAccessChanged)
    }

    /** Provoque « Unable to start service … not found » dans les journaux du système. */
    private fun probe() {
        runCatching {
            context.startService(Intent().setComponent(ComponentName(context.packageName, PROBE_CLASS)))
        }
    }

    fun stop() {
        running = false
        logcat?.destroy()
        logcat = null
        clipboard.removePrimaryClipChangedListener(noopListener)
    }

    private fun readLogcat() {
        val since = SimpleDateFormat("MM-dd HH:mm:ss.SSS", Locale.US).format(Date())
        val marker = "Denying clipboard access to ${context.packageName}"
        val probeMarker = "${context.packageName}/.${PROBE_CLASS.substringAfterLast('.')}"
        setAccess(Access.CHECKING)
        try {
            val process = ProcessBuilder("logcat", "-T", since, "-v", "brief", "*:W")
                .redirectErrorStream(true)
                .start()
            logcat = process
            main.postDelayed({ probe() }, 300)
            // Sans réponse (demande refusée ou restée sans réponse), on le signale.
            main.postDelayed({ if (logcat === process && access == Access.CHECKING) setAccess(Access.DENIED) }, 5_000)
            process.inputStream.bufferedReader().useLines { lines ->
                for (line in lines) {
                    if (!running) break
                    when {
                        line.contains(marker) -> main.post { onClipboardChanged() }
                        line.contains(probeMarker) -> setAccess(Access.GRANTED)
                    }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "logcat indisponible", e)
        }
        // logcat s'arrête parfois (ou on l'a arrêté pour redemander l'accès) : on relance.
        if (running) main.postDelayed({ if (running) startReader() }, 500)
    }

    private fun onClipboardChanged() {
        if (System.currentTimeMillis() < ignoreUntil) return
        pending = this
        BackgroundLauncher.start(
            context,
            Intent(context, ReadClipboardActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NO_ANIMATION),
        )
    }

    /** Appelé par ReadClipboardActivity une fois le presse-papier lu. */
    internal fun deliver(clip: ClipData?) {
        // Une image se lit depuis son URI (quelques Mo) : hors du fil principal.
        Thread({
            val content = ClipContent.fromClip(context, clip, skipSensitive = true)
            if (content != null) main.post { onContent(content) }
        }, "navette-lecture").start()
    }

    companion object {
        private const val TAG = "NavetteAuto"

        /** Instance qui attend le résultat de ReadClipboardActivity. */
        @Volatile internal var pending: AutoCopy? = null

        /** Classe volontairement inexistante, visée par la sonde. */
        private const val PROBE_CLASS = "fr.soufiane.navette.SondeJournaux"

        fun hasReadLogs(context: Context) =
            context.checkSelfPermission(Manifest.permission.READ_LOGS) == PackageManager.PERMISSION_GRANTED

        fun hasOverlay(context: Context) = AndroidSettings.canDrawOverlays(context)

        fun isAvailable(context: Context) = hasReadLogs(context) && hasOverlay(context)
    }
}

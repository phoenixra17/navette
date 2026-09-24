package fr.soufiane.navette

import android.app.Activity
import android.content.ClipboardManager
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.widget.Toast

/**
 * Activité invisible qui envoie un texte ou une image au Mac, puis se ferme.
 *
 * - Depuis la tuile ou la notification : Android ne laisse lire le presse-papier qu'à l'app
 *   au premier plan. On attend donc que cette fenêtre (transparente) ait le focus pour le lire.
 * - Depuis « Partager » (texte ou image) ou le menu de sélection de texte : le contenu arrive
 *   dans l'Intent.
 */
class SendActivity : Activity() {
    private var handled = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        when (intent?.action) {
            Intent.ACTION_SEND -> {
                val type = intent.type ?: ""
                if (type.startsWith("image/")) {
                    // Capture d'écran → Partager → Navette. Le droit de lire l'image est lié à cette
                    // activité : on la lit (hors du fil principal) avant de fermer.
                    val uri = intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                    handled = true
                    val app = applicationContext
                    Thread {
                        val content = uri?.let { ClipContent.fromImageUri(this, it, type) }
                        runOnUiThread {
                            deliver(app, content)
                            close()
                        }
                    }.start()
                } else {
                    send(intent.getStringExtra(Intent.EXTRA_TEXT)?.let { ClipContent.Text(it) })
                }
            }
            Intent.ACTION_PROCESS_TEXT ->
                send(intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString()?.let { ClipContent.Text(it) })
            else -> Unit // lu dans onWindowFocusChanged
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!hasFocus || handled) return
        val clip = getSystemService(ClipboardManager::class.java).primaryClip
        handled = true
        val app = applicationContext
        Thread {
            val content = ClipContent.fromClip(app, clip)
            runOnUiThread {
                deliver(app, content)
                close()
            }
        }.start()
    }

    private fun send(content: ClipContent?) {
        if (handled) return
        handled = true
        deliver(applicationContext, content)
        close()
    }

    private fun close() {
        finish()
        overrideActivityTransition(OVERRIDE_TRANSITION_CLOSE, 0, 0)
    }

    private fun deliver(app: android.content.Context, content: ClipContent?) {
        if (content == null) {
            Toast.makeText(app, "Rien à envoyer", Toast.LENGTH_SHORT).show()
            return
        }
        Relay.send(Settings(app), content) { error ->
            Toast.makeText(app, error ?: "Envoyé au Mac ✓", Toast.LENGTH_SHORT).show()
        }
    }
}

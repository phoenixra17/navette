package fr.soufiane.navette

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.widget.Toast

/**
 * Activité invisible : Partager → « Fichier vers le Mac », pour un ou plusieurs fichiers de
 * n'importe quel type. L'envoi continue en arrière-plan (voir [FileTransfers]).
 */
class SendFileActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val uris = when (intent?.action) {
            Intent.ACTION_SEND -> listOfNotNull(intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java))
            Intent.ACTION_SEND_MULTIPLE ->
                intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java).orEmpty()
            else -> emptyList()
        }
        if (uris.isEmpty()) {
            Toast.makeText(this, "Aucun fichier à envoyer", Toast.LENGTH_SHORT).show()
        } else {
            FileTransfers.send(this, uris)
            Toast.makeText(
                this, if (uris.size > 1) "Envoi de ${uris.size} fichiers au Mac…" else "Envoi au Mac…", Toast.LENGTH_SHORT,
            ).show()
        }
        finish()
        overrideActivityTransition(OVERRIDE_TRANSITION_CLOSE, 0, 0)
    }
}

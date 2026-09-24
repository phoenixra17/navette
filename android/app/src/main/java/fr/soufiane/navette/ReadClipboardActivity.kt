package fr.soufiane.navette

import android.app.Activity
import android.content.ClipboardManager
import android.os.Bundle

/** Activité transparente et fugace : lit le presse-papier dès qu'elle a le focus (voir AutoCopy). */
class ReadClipboardActivity : Activity() {
    private var done = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        overrideActivityTransition(OVERRIDE_TRANSITION_OPEN, 0, 0)
        overrideActivityTransition(OVERRIDE_TRANSITION_CLOSE, 0, 0)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!hasFocus || done) return
        done = true
        val clip = getSystemService(ClipboardManager::class.java).primaryClip
        AutoCopy.pending?.deliver(clip)
        AutoCopy.pending = null
        finish()
    }

    override fun onPause() {
        super.onPause()
        if (!done) finish() // l'utilisateur est passé à autre chose : on ne s'impose pas
    }
}

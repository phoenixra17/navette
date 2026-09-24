package fr.soufiane.navette

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Relance l'écoute après un redémarrage du téléphone ou une mise à jour de l'app. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED && intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        if (Settings(context).isPaired) RelayService.start(context)
    }
}

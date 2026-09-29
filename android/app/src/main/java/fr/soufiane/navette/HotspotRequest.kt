package fr.soufiane.navette

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.util.Log

/**
 * Point d'accès demandé par le Mac. Android interdit aux apps de l'allumer ; une routine Samsung
 * le peut, et la condition « Notification reçue › Navette › mot-clé » ne se déclenche que sur
 * cette notification. L'ancienne condition « Appareil Bluetooth › Mac connecté » se déclenchait
 * aussi sur la liaison Bluetooth de secours de Navette : les routines comptent une liaison basse
 * consommation établie comme une connexion (vérifié le 29/09/2026).
 */
object HotspotRequest {
    private const val TAG = "NavettePointAcces"
    private const val CHANNEL_ID = "point-acces"
    private const val NOTIF_ID = 3
    /** Titre de la notification ; mot-clé de la routine : « demandé par le Mac » (sans apostrophe,
     *  la typographique de « accès » ne se tape pas au clavier). */
    private const val TITLE = "Point d’accès demandé par le Mac"

    fun post(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Point d’accès", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Demandes du Mac, pour la routine Samsung qui allume le point d’accès"
            },
        )
        // Supprimée puis reposée : la routine ne voit qu'une nouvelle notification.
        manager.cancel(NOTIF_ID)
        manager.notify(
            NOTIF_ID,
            Notification.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_navette)
                .setContentTitle(TITLE)
                .setContentText("Une routine Samsung peut allumer le point d’accès.")
                .setTimeoutAfter(15_000)
                .build(),
        )
        Log.i(TAG, "demande du Mac : notification affichée")
    }
}

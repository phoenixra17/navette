package fr.soufiane.navette

import android.app.PendingIntent
import android.content.Intent
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

/** Tuile des réglages rapides « Envoyer au Mac ». */
class SendTileService : TileService() {
    override fun onStartListening() {
        qsTile?.apply {
            state = Tile.STATE_ACTIVE
            updateTile()
        }
    }

    override fun onClick() {
        val intent = Intent(this, SendActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val launch = {
            startActivityAndCollapse(PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE))
        }
        if (isLocked) unlockAndRun(launch) else launch()
    }
}

package fr.soufiane.navette

import android.content.Context
import android.content.Intent
import android.graphics.PixelFormat
import android.os.Handler
import android.os.Looper
import android.provider.Settings as AndroidSettings
import android.util.Log
import android.view.Gravity
import android.view.View
import android.view.WindowManager

/**
 * Ouvre une activité depuis l'arrière-plan. Android 15+ ne le permet qu'à une app qui a
 * « Apparaître au-dessus » ET une fenêtre superposée visible : on pose une fenêtre d'un pixel,
 * non focalisable et non touchable, le temps du lancement.
 */
object BackgroundLauncher {
    private const val TAG = "NavetteLanceur"
    private val main = Handler(Looper.getMainLooper())

    fun canLaunch(context: Context) = AndroidSettings.canDrawOverlays(context)

    /** Renvoie false si l'autorisation manque ou si Android a refusé : prévoir une notification. */
    fun start(context: Context, intent: Intent): Boolean {
        if (!canLaunch(context)) return false
        val windows = context.getSystemService(WindowManager::class.java)
        val view = View(context)
        val params = WindowManager.LayoutParams(
            1, 1,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSPARENT,
        ).apply { gravity = Gravity.TOP or Gravity.START }
        val added = runCatching { windows.addView(view, params) }.isSuccess
        val launched = runCatching {
            context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }.onFailure { Log.w(TAG, "lancement refusé", it) }.isSuccess
        if (added) main.postDelayed({ runCatching { windows.removeViewImmediate(view) } }, 1_000)
        return launched
    }
}

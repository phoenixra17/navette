package fr.soufiane.navette

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.telephony.SignalStrength
import android.telephony.TelephonyCallback
import android.telephony.TelephonyDisplayInfo
import android.telephony.TelephonyManager
import android.util.Log

/**
 * Réseau mobile (5G, 4G…) et barres de signal, affichés sur le Mac comme pour un iPhone.
 *
 * Ni le signal ni le type de réseau ne demandent d'autorisation (vérifié sur l'émulateur
 * Android 15 et sur le S24 Android 16). Par prudence, les deux écouteurs sont inscrits séparément :
 * si un constructeur refusait le type de réseau, le signal passerait quand même, et l'écran
 * principal proposerait alors l'autorisation « Téléphone » (READ_PHONE_STATE).
 */
class NetworkStatus(private val context: Context, private val onChange: () -> Unit) {
    private val telephony = context.getSystemService(TelephonyManager::class.java)

    /** « 5G », « 4G+ »… ou vide si inconnu (autorisation manquante, mode avion, pas de SIM). */
    @Volatile var label: String = ""
        private set

    /** Barres de signal, 0 à 4. */
    @Volatile var bars: Int = 0
        private set

    /** Le type de réseau est-il lisible ? Sinon, l'écran principal propose l'autorisation. */
    @Volatile var networkTypeAvailable = false
        private set

    private var displayRegistered = false

    private val signalCallback = object : TelephonyCallback(), TelephonyCallback.SignalStrengthsListener {
        override fun onSignalStrengthsChanged(strength: SignalStrength) {
            val next = strength.level.coerceIn(0, 4)
            if (next != bars) {
                bars = next
                onChange()
            }
        }
    }

    private val displayCallback = object : TelephonyCallback(), TelephonyCallback.DisplayInfoListener {
        override fun onDisplayInfoChanged(info: TelephonyDisplayInfo) {
            val next = labelFor(info.networkType, info.overrideNetworkType)
            if (next != label) {
                label = next
                onChange()
            }
        }
    }

    fun start() {
        runCatching { telephony.registerTelephonyCallback(Runnable::run, signalCallback) }
            .onFailure { Log.w(TAG, "signal indisponible", it) }
        registerDisplayInfo()
    }

    /** À rappeler une fois l'autorisation « Téléphone » accordée. */
    @SuppressLint("MissingPermission") // dataNetworkType n'est lu qu'après hasPhonePermission()
    fun registerDisplayInfo() {
        if (displayRegistered) return
        runCatching { telephony.registerTelephonyCallback(Runnable::run, displayCallback) }
            .onSuccess {
                displayRegistered = true
                networkTypeAvailable = true
            }
            .onFailure {
                Log.w(TAG, "type de réseau refusé sans autorisation", it)
                networkTypeAvailable = false
                // Repli : lecture directe, possible si l'autorisation a été accordée entre-temps.
                if (hasPhonePermission(context)) {
                    runCatching { labelFor(telephony.dataNetworkType, TelephonyDisplayInfo.OVERRIDE_NETWORK_TYPE_NONE) }
                        .onSuccess { label = it; networkTypeAvailable = true; onChange() }
                }
            }
    }

    fun stop() {
        runCatching { telephony.unregisterTelephonyCallback(signalCallback) }
        if (displayRegistered) runCatching { telephony.unregisterTelephonyCallback(displayCallback) }
        displayRegistered = false
    }

    private fun labelFor(networkType: Int, override: Int): String {
        // Ce qu'affiche la barre d'état : la 5G « non autonome » est annoncée par override.
        when (override) {
            TelephonyDisplayInfo.OVERRIDE_NETWORK_TYPE_NR_NSA,
            TelephonyDisplayInfo.OVERRIDE_NETWORK_TYPE_NR_ADVANCED -> return "5G"
            TelephonyDisplayInfo.OVERRIDE_NETWORK_TYPE_LTE_ADVANCED_PRO,
            TelephonyDisplayInfo.OVERRIDE_NETWORK_TYPE_LTE_CA -> return "4G+"
        }
        return when (networkType) {
            TelephonyManager.NETWORK_TYPE_NR -> "5G"
            TelephonyManager.NETWORK_TYPE_LTE, TelephonyManager.NETWORK_TYPE_IWLAN -> "4G"
            TelephonyManager.NETWORK_TYPE_HSPAP, TelephonyManager.NETWORK_TYPE_HSPA,
            TelephonyManager.NETWORK_TYPE_HSDPA, TelephonyManager.NETWORK_TYPE_HSUPA,
            TelephonyManager.NETWORK_TYPE_UMTS -> "3G"
            TelephonyManager.NETWORK_TYPE_EDGE, TelephonyManager.NETWORK_TYPE_GPRS -> "E"
            else -> ""
        }
    }

    companion object {
        private const val TAG = "NavetteReseau"

        /** Dernière instance active, pour l'écran principal (diagnostic et autorisation). */
        @Volatile var current: NetworkStatus? = null

        fun hasPhonePermission(context: Context) =
            context.checkSelfPermission(Manifest.permission.READ_PHONE_STATE) == PackageManager.PERMISSION_GRANTED
    }
}

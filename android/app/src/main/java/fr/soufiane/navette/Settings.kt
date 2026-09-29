package fr.soufiane.navette

import android.content.Context
import android.net.Uri

/** Réglages de l'appairage, dans le stockage privé de l'app. */
class Settings(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences("navette", Context.MODE_PRIVATE)


    var secret: String
        get() = prefs.getString("secret", "") ?: ""
        set(value) = prefs.edit().putString("secret", value.trim()).apply()

    val device: String get() = "s24"

    /** Envoi automatique des copies (quand les autorisations le permettent). */
    var autoSend: Boolean
        get() = prefs.getBoolean("autoSend", true)
        set(value) = prefs.edit().putBoolean("autoSend", value).apply()

    /** Transmettre les notifications du téléphone au Mac (si l'accès est accordé). */
    var forwardNotifications: Boolean
        get() = prefs.getBoolean("forwardNotifications", true)
        set(value) = prefs.edit().putBoolean("forwardNotifications", value).apply()

    /** Horodatage du dernier presse-papier reçu du Mac : « Récupérer » n'applique rien de plus ancien. */
    var lastClipAt: Long
        get() = prefs.getLong("lastClipAt", 0L)
        set(value) = prefs.edit().putLong("lastClipAt", value).apply()

    val isPaired: Boolean get() = secret.isNotEmpty()

    /** Clés dérivées du secret, ou null si pas encore appairé. */
    fun keys(): NavetteCrypto.Keys? =
        if (isPaired) runCatching { NavetteCrypto.deriveKeys(secret) }.getOrNull() else null

    /** Lit le QR affiché par l'app Mac : navette://pair?s=<secret>. */
    fun applyPairingUri(raw: String): Boolean {
        val uri = Uri.parse(raw)
        if (uri.scheme != "navette" || uri.host != "pair") return false
        if (runCatching { NavetteCrypto.deriveKeys(secret) }.isFailure) return false
        if (secret != this.secret) lastClipAt = 0L
        this.secret = secret
        return true
    }
}

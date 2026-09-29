package fr.soufiane.navette

import android.os.Handler
import android.os.Looper
import org.json.JSONObject

/** Envoi vers le Mac par la meilleure liaison, et changements d'état observés par l'interface. */
object Transport {
    private val main = Handler(Looper.getMainLooper())
    private val listeners = mutableSetOf<() -> Unit>()

    fun addListener(l: () -> Unit) { listeners += l }
    fun removeListener(l: () -> Unit) { listeners -= l }

    fun notifyListeners() = main.post { listeners.toList().forEach { it() } }


    /** Envoie un contenu au Mac. `done` est appelé sur le fil principal avec un message d'erreur ou null. */
    fun send(settings: Settings, content: ClipContent, done: (String?) -> Unit) =
        sendPayload(settings, content.toPayload(), ephemeral = false, done = done)

    /** Envoie un message quelconque (voir PROTOCOL.md). [allowBluetooth] : null = oui. */
    fun sendPayload(
        settings: Settings, payload: JSONObject, ephemeral: Boolean,
        allowBluetooth: Boolean? = null, done: (String?) -> Unit = {},
    ) {
        val keys = settings.keys() ?: return done("Navette n’est pas appairée")
        val json = NavetteCrypto.seal(keys.encKey, payload).toJson()
        if (ephemeral) json.put("ephemeral", true)
        val frame = JSONObject(json.toString()).put("type", "clip")
        val bluetooth = allowBluetooth ?: true
        val fallback: () -> Unit = { done("liaison directe avec le Mac perdue") }
        val direct = LocalLink.send(frame, bluetooth) { ok ->
            if (ok) main.post { done(null) } else main.post(fallback)
        }
        if (!ephemeral) {
            val route = LocalLink.description ?: "aucune liaison"
            android.util.Log.i("NavetteLocal", "envoi par $route (${json.optString("data").length / 1024} Ko)")
        }
        if (!direct) fallback()
    }

    /** Morceau de fichier : trame binaire sur une liaison directe. */
    fun sendChunk(
        settings: Settings, meta: JSONObject, bytes: ByteArray, allowBluetooth: Boolean,
        done: (String?) -> Unit,
    ) {
        val keys = settings.keys() ?: return done("Navette n’est pas appairée")
        val chunk = NavetteCrypto.sealChunk(keys.encKey, meta, bytes)
        val fallback: () -> Unit = { done("liaison directe avec le Mac perdue") }
        val direct = LocalLink.sendChunk(chunk, allowBluetooth) { ok ->
            if (ok) main.post { done(null) } else main.post(fallback)
        }
        if (!direct) fallback()
    }
}

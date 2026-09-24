package fr.soufiane.navette

import android.os.Handler
import android.os.Looper
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONObject
import java.io.IOException
import java.util.concurrent.TimeUnit

/** Client HTTP partagé (pool de connexions) et état de connexion observable. */
object Relay {
    val http: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.MILLISECONDS) // WebSocket : pas de délai de lecture
        .writeTimeout(60, TimeUnit.SECONDS) // une image peut prendre du temps en 4G
        .pingInterval(20, TimeUnit.SECONDS)
        .build()

    private val main = Handler(Looper.getMainLooper())

    // --- État affiché par l'écran principal et la notification ---

    enum class State { OFF, CONNECTING, CONNECTED, UNAUTHORIZED, ERROR }

    @Volatile var state: State = State.OFF
        private set
    @Volatile var detail: String = ""
        private set
    private val listeners = mutableSetOf<() -> Unit>()

    fun addListener(l: () -> Unit) { listeners += l }
    fun removeListener(l: () -> Unit) { listeners -= l }

    fun notifyListeners() = main.post { listeners.toList().forEach { it() } }

    fun setState(state: State, detail: String = "") = main.post {
        this.state = state
        this.detail = detail
        listeners.toList().forEach { it() }
    }

    // --- Requêtes ---

    private fun request(settings: Settings, keys: NavetteCrypto.Keys, path: String) =
        Request.Builder()
            .url(settings.server + path)
            .header("Authorization", "Bearer ${keys.token}")
            .header("X-Navette-Device", settings.device)

    /** WebSocket ouvert par RelayService, utilisé en priorité pour envoyer (plus rapide que HTTP). */
    @Volatile var socket: WebSocket? = null

    /** Envoie un contenu au Mac. `done` est appelé sur le fil principal avec un message d'erreur ou null. */
    fun send(settings: Settings, content: ClipContent, done: (String?) -> Unit) =
        sendPayload(settings, content.toPayload(), ephemeral = false, done)

    /**
     * Envoie un message quelconque (voir « Protocole » dans le README). Un message éphémère
     * (notification, batterie…) n'écrase pas le dernier presse-papier gardé par le serveur.
     */
    fun sendPayload(settings: Settings, payload: JSONObject, ephemeral: Boolean, done: (String?) -> Unit = {}) {
        val keys = settings.keys() ?: return done("Navette n’est pas appairée")
        val json = NavetteCrypto.seal(keys.encKey, payload).toJson()
        if (ephemeral) json.put("ephemeral", true)
        val ws = socket
        if (ws != null && ws.send(JSONObject(json.toString()).put("type", "clip").toString())) {
            main.post { done(null) }
            return
        }
        val body = json.toString().toRequestBody("application/json".toMediaType())
        http.newCall(request(settings, keys, "/api/clip").post(body).build()).enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                main.post { done("Serveur injoignable") }
            }

            override fun onResponse(call: Call, response: Response) {
                response.use {
                    val error = when {
                        it.code == 401 -> "Jeton refusé par le serveur"
                        !it.isSuccessful -> "Erreur serveur ${it.code}"
                        else -> null
                    }
                    main.post { done(error) }
                }
            }
        })
    }

    /** Récupère le dernier élément passé par le serveur (après une coupure, par exemple). */
    fun fetchLast(settings: Settings, done: (content: ClipContent?, error: String?) -> Unit) {
        val keys = settings.keys() ?: return done(null, "Navette n’est pas appairée")
        http.newCall(request(settings, keys, "/api/clip/last").get().build()).enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                main.post { done(null, "Serveur injoignable") }
            }

            override fun onResponse(call: Call, response: Response) {
                response.use {
                    val result: Pair<ClipContent?, String?> = when {
                        it.code == 204 -> null to "Rien à récupérer pour l’instant"
                        !it.isSuccessful -> null to "Erreur serveur ${it.code}"
                        else -> runCatching {
                            val clip = NavetteCrypto.Clip.fromJson(JSONObject(it.body!!.string()))
                            // Le dernier élément peut venir du Mac ou de ce téléphone.
                            val payload = runCatching { NavetteCrypto.open(keys.encKey, clip, NavetteCrypto.MAC) }
                                .getOrElse { NavetteCrypto.open(keys.encKey, clip, NavetteCrypto.PHONE) }
                            val t = payload.optLong("t")
                            // Le serveur pourrait resservir un ancien élément : on n'applique que du plus récent.
                            if (t <= settings.lastClipAt) {
                                null to "Rien de plus récent que le dernier élément reçu"
                            } else {
                                settings.lastClipAt = t
                                ClipContent.fromPayload(payload) to null
                            }
                        }.getOrElse { null to "Élément illisible (secret différent ?)" }
                    }
                    main.post { done(result.first, result.second) }
                }
            }
        })
    }

    /** Ouvre le WebSocket de réception ; le service gère la reconnexion. */
    fun openSocket(settings: Settings, keys: NavetteCrypto.Keys, listener: WebSocketListener): WebSocket {
        val url = settings.server.replaceFirst(Regex("^http"), "ws") + "/ws"
        val req = Request.Builder()
            .url(url)
            .header("Authorization", "Bearer ${keys.token}")
            .header("X-Navette-Device", settings.device)
            .build()
        return http.newWebSocket(req, listener)
    }
}

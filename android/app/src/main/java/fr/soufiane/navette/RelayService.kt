package fr.soufiane.navette

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.os.BatteryManager
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONObject

/**
 * Service de premier plan qui garde le WebSocket ouvert et écrit dans le presse-papier
 * ce qui arrive du Mac. Android autorise l'écriture en arrière-plan (seule la lecture est bloquée).
 */
class RelayService : Service() {
    private val main = Handler(Looper.getMainLooper())
    private lateinit var settings: Settings
    private var socket: WebSocket? = null
    private var retryDelayMs = 1_000L
    private var lastEvent: String? = null
    private var lastReceived: ClipContent? = null
    private var lastReceivedAt = 0L
    private var lastSent: ClipContent? = null
    private var lastSentAt = 0L
    private var autoCopy: AutoCopy? = null
    private val retry = Runnable { connect() }

    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            // Nouveau réseau (Wi-Fi ↔ 4G) : inutile d'attendre la fin du délai de reconnexion.
            main.post { if (Relay.state != Relay.State.CONNECTED) reconnectNow() }
        }
    }

    private val stateListener: () -> Unit = { updateNotification() }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        settings = Settings(this)
        network = NetworkStatus(this) { main.post { onNetworkChanged() } }
        NetworkStatus.current = network
        createChannel()
        startForeground(NOTIF_ID, buildNotification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        Relay.addListener(stateListener)
        getSystemService(ConnectivityManager::class.java).registerDefaultNetworkCallback(networkCallback)
        connect()
        refreshAutoCopy()
        registerReceiver(batteryReceiver, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        network.start()
    }

    /** Démarre l'envoi automatique si les deux autorisations sont là (voir AutoCopy). */
    private fun refreshAutoCopy() {
        if (AutoCopy.isAvailable(this) && settings.autoSend) {
            if (autoCopy == null) {
                autoCopy = AutoCopy(this, onAccessChanged = { onAutoAccessChanged() }) { content -> autoSend(content) }
                    .also { it.start() }
            } else {
                autoCopy?.retryIfDenied()
            }
        } else {
            autoCopy?.stop()
            autoCopy = null
        }
        onAutoAccessChanged()
    }

    private fun onAutoAccessChanged() {
        autoAccess = autoCopy?.access
        updateNotification()
        Relay.notifyListeners()
    }

    private fun autoSend(content: ClipContent) {
        // Ce qui vient d'arriver du Mac, ou ce qu'on vient d'envoyer, ne repart pas aussitôt.
        val now = System.currentTimeMillis()
        if (content == lastReceived && now - lastReceivedAt < DEDUP_MS) return
        if (content == lastSent && now - lastSentAt < DEDUP_MS) return
        lastSent = content
        lastSentAt = now
        Relay.send(settings, content) { error ->
            lastEvent = if (error == null) "Envoyé : ${content.preview}" else "Échec d’envoi : $error"
            updateNotification()
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_RECONNECT -> reconnectNow()
            ACTION_REFRESH -> {
                refreshAutoCopy()
                network.registerDisplayInfo() // l'autorisation « Téléphone » vient peut-être d'être accordée
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        main.removeCallbacks(retry)
        autoCopy?.stop()
        runCatching { unregisterReceiver(batteryReceiver) }
        network.stop()
        if (NetworkStatus.current === network) NetworkStatus.current = null
        main.removeCallbacks(sendStatusLater)
        Relay.socket = null
        socket?.close(1000, "arrêt")
        socket = null
        Relay.removeListener(stateListener)
        runCatching { getSystemService(ConnectivityManager::class.java).unregisterNetworkCallback(networkCallback) }
        Relay.setState(Relay.State.OFF)
        super.onDestroy()
    }

    private fun reconnectNow() {
        retryDelayMs = 1_000L
        connect()
    }

    private fun connect() {
        main.removeCallbacks(retry)
        socket?.cancel()
        socket = null
        Relay.socket = null
        val keys = settings.keys()
        if (keys == null) {
            Relay.setState(Relay.State.OFF, "pas encore appairé")
            return
        }
        Relay.setState(Relay.State.CONNECTING)
        socket = Relay.openSocket(settings, keys, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                main.post {
                    if (webSocket !== socket) return@post
                    retryDelayMs = 1_000L
                    Relay.socket = webSocket
                    Relay.setState(Relay.State.CONNECTED)
                    sendBattery()
                }
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                val received = runCatching {
                    val msg = JSONObject(text)
                    if (msg.optString("type") != "clip") return
                    NavetteCrypto.open(keys.encKey, NavetteCrypto.Clip.fromJson(msg))
                }
                main.post {
                    received.onSuccess { handle(it) }
                    received.onFailure { lastEvent = "Élément illisible (secret différent ?)"; updateNotification() }
                }
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                main.post { if (webSocket === socket) lost("connexion fermée") }
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                main.post {
                    if (webSocket !== socket) return@post
                    if (response?.code == 401) {
                        socket = null
                        Relay.socket = null
                        Relay.setState(Relay.State.UNAUTHORIZED, "jeton refusé par le serveur")
                        main.postDelayed(retry, 60_000L)
                    } else {
                        lost(t.message ?: "serveur injoignable")
                    }
                }
            }
        })
    }

    private fun lost(reason: String) {
        socket = null
        Relay.socket = null
        Relay.setState(Relay.State.ERROR, reason)
        main.postDelayed(retry, retryDelayMs)
        retryDelayMs = (retryDelayMs * 2).coerceAtMost(30_000L)
    }

    /** Message venu du Mac : presse-papier, ou commande (réponse, sonnerie, lien…). */
    private fun handle(payload: JSONObject) {
        when (payload.optString("kind")) {
            "text", "image" -> ClipContent.fromPayload(payload)?.let { writeClipboard(it) }
            "reply" -> {
                val key = payload.optString("key")
                val ok = NotifListener.instance?.reply(key, payload.optString("text")) == true
                Relay.sendPayload(
                    settings, JSONObject().put("kind", "reply-result").put("key", key).put("ok", ok), ephemeral = true,
                )
            }
            "notif-dismiss" -> NotifListener.instance?.dismiss(payload.optString("key"))
            "ring" -> Ringer.start(this)
            "ring-stop" -> Ringer.stop(this)
            "url" -> Links.open(this, payload.optString("url"))
            "sync" -> sendBattery()
        }
    }

    // --- Batterie et réseau, affichés dans le menu du Mac (comme un iPhone en point d'accès) ---

    // Créé dans onCreate : avant, le service n'a pas encore accès aux services système.
    private lateinit var network: NetworkStatus
    private var sentNetwork = ""
    private var sentAt = 0L
    private val sendStatusLater = Runnable { sendBattery() }

    private fun onNetworkChanged() {
        Relay.notifyListeners() // diagnostic de l'écran principal
        // Le type de réseau part aussitôt ; le signal, qui bouge sans cesse, au plus une fois par minute.
        main.removeCallbacks(sendStatusLater)
        val wait = if (network.label != sentNetwork) 0L else (sentAt + 60_000L - System.currentTimeMillis())
        if (wait <= 0) sendBattery() else main.postDelayed(sendStatusLater, wait)
    }

    private var batteryLevel = -1
    private var batteryCharging = false

    private val batteryReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
            val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, 100)
            val percent = if (level < 0 || scale <= 0) -1 else level * 100 / scale
            val charging = intent.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) != 0
            // ACTION_BATTERY_CHANGED arrive souvent (température, tension) : on n'envoie que les vrais changements.
            if (percent == batteryLevel && charging == batteryCharging) return
            batteryLevel = percent
            batteryCharging = charging
            sendBattery()
        }
    }

    private fun sendBattery() {
        if (batteryLevel < 0 || socket == null) return
        sentNetwork = network.label
        sentAt = System.currentTimeMillis()
        Relay.sendPayload(
            settings,
            JSONObject()
                .put("kind", "battery")
                .put("level", batteryLevel)
                .put("charging", batteryCharging)
                .put("net", network.label)
                .put("signal", network.bars),
            ephemeral = true,
        )
    }

    private fun writeClipboard(content: ClipContent) {
        autoCopy?.ignoreUntil = System.currentTimeMillis() + 2_000
        lastReceived = content
        lastReceivedAt = System.currentTimeMillis()
        Clipboard.write(this, content)
        lastEvent = "Reçu : ${content.preview}"
        updateNotification()
    }

    // --- Notification permanente (obligatoire pour un service de premier plan) ---

    private fun createChannel() {
        val channel = NotificationChannel(CHANNEL_ID, "Connexion Navette", NotificationManager.IMPORTANCE_LOW)
        channel.description = "Reste affichée tant que Navette écoute le Mac"
        channel.setShowBadge(false)
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val title = when (Relay.state) {
            Relay.State.CONNECTED -> "Connecté au Mac"
            Relay.State.CONNECTING -> "Connexion…"
            Relay.State.UNAUTHORIZED -> "Jeton refusé par le serveur"
            Relay.State.ERROR -> "Hors ligne — nouvelle tentative"
            Relay.State.OFF -> "Navette"
        }
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE,
        )
        val send = PendingIntent.getActivity(
            this, 1,
            Intent(this, SendActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE,
        )
        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_navette)
            .setContentTitle(title)
            .setContentText(
                when {
                    autoCopy?.access == AutoCopy.Access.DENIED -> "Envoi auto en pause : touchez pour le réactiver"
                    lastEvent != null -> lastEvent
                    autoCopy != null -> "Envoi automatique actif"
                    else -> "Touchez « Envoyer » après avoir copié"
                },
            )
            .setContentIntent(open)
            .addAction(Notification.Action.Builder(null, "Envoyer au Mac", send).build())
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }

    private fun updateNotification() {
        getSystemService(NotificationManager::class.java).notify(NOTIF_ID, buildNotification())
    }

    companion object {
        private const val CHANNEL_ID = "navette"
        private const val NOTIF_ID = 1
        private const val DEDUP_MS = 5_000L
        const val ACTION_RECONNECT = "fr.soufiane.navette.RECONNECT"
        const val ACTION_REFRESH = "fr.soufiane.navette.REFRESH"

        /** État de l'accès aux journaux, affiché par l'écran principal (null = envoi auto inactif). */
        @Volatile var autoAccess: AutoCopy.Access? = null
            private set

        fun refresh(context: Context) {
            context.startForegroundService(Intent(context, RelayService::class.java).setAction(ACTION_REFRESH))
        }

        fun start(context: Context, reconnect: Boolean = false) {
            val intent = Intent(context, RelayService::class.java)
            if (reconnect) intent.action = ACTION_RECONNECT
            context.startForegroundService(intent)
        }

    }
}

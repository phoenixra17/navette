package fr.soufiane.navette

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.Inet4Address
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.Socket
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/**
 * Liaison directe avec le Mac, sans serveur (voir « Liaison locale » dans PROTOCOL.md).
 * Wi-Fi : le téléphone écoute sur [PORT] et s'annonce en Bonjour (`_navette._tcp`) ; le Mac s'y
 * connecte. Bluetooth : même protocole sur une liaison BLE (voir [BleLink]). Dans les deux cas, les
 * deux appareils prouvent qu'ils détiennent le secret, puis les éléments chiffrés passent comme par
 * le relais. Démarrée et arrêtée par [RelayService].
 */
object LocalLink {
    enum class Via(val label: String) { WIFI("Wi-Fi"), BLUETOOTH("Bluetooth") }

    /** Flux d'octets vers un Mac : connexion TCP ou liaison BLE. */
    interface Channel {
        val input: InputStream
        val output: OutputStream
        val address: String
        /** Délai de lecture en millisecondes (0 = aucun). */
        fun setReadTimeout(ms: Int)
        fun close()
    }

    const val PORT = 3201
    private const val SERVICE_TYPE = "_navette._tcp"
    private const val TAG = "NavetteLocal"
    private const val MAX_FRAME = 24 * 1024 * 1024
    private const val MAX_HANDSHAKE_FRAME = 4096

    private class Peer(val channel: Channel, val via: Via) {
        val output = DataOutputStream(channel.output.buffered())
        /** Écritures hors du fil principal, dans l'ordre ; une file par liaison (le BLE est lent). */
        val writer: ExecutorService = Executors.newSingleThreadExecutor()
        fun close() {
            runCatching { channel.close() }
            writer.shutdown()
        }
    }

    /** Un Mac au plus par moyen de liaison : la connexion la plus récente remplace l'ancienne. */
    private val peers = ConcurrentHashMap<Via, Peer>()
    @Volatile private var server: ServerSocket? = null
    private var nsd: NsdManager? = null
    private var registration: NsdManager.RegistrationListener? = null
    private val handshakes = AtomicInteger()
    @Volatile private var keys: NavetteCrypto.Keys? = null
    @Volatile private var onMessage: ((JSONObject) -> Unit)? = null

    val isConnected: Boolean get() = peers.isNotEmpty()
    fun isConnected(via: Via): Boolean = peers.containsKey(via)
    /** Pour l'écran principal : « Wi-Fi (10.0.0.4) », « Bluetooth »… */
    val description: String?
        get() = (peers[Via.WIFI] ?: peers[Via.BLUETOOTH])?.let {
            "${it.via.label} (${it.channel.address})"
        }
    /** Port réellement ouvert (0 si arrêté). */
    val port: Int get() = server?.localPort ?: 0

    /** [onMessage] reçoit chaque trame `clip` du Mac, sur le fil de la connexion. */
    @Synchronized
    fun start(context: Context, keys: NavetteCrypto.Keys, onMessage: (JSONObject) -> Unit) {
        if (server != null) return
        this.keys = keys
        this.onMessage = onMessage
        val socket = runCatching { ServerSocket(PORT) }
            .getOrElse { ServerSocket(0) } // port pris : n'importe lequel, Bonjour et l'annonce le donnent
        server = socket
        Thread({ acceptLoop(socket) }, "navette-local").start()
        register(context, keys.localId, socket.localPort)
        Log.i(TAG, "à l’écoute sur le port ${socket.localPort}")
        BleLink.start(context)
    }

    @Synchronized
    fun stop() {
        BleLink.stop()
        registration?.let { runCatching { nsd?.unregisterService(it) } }
        registration = null
        runCatching { server?.close() }
        server = null
        peers.values.forEach { it.close() }
        peers.clear()
        keys = null
        onMessage = null
        Relay.notifyListeners()
    }

    /**
     * Envoie une trame au Mac si une liaison directe est établie (Wi-Fi d'abord) ; `done(false)` si
     * l'écriture échoue (l'appelant passe alors par le relais). Renvoie false si pas de liaison.
     * [bluetooth] : false pour éviter le BLE (grosse image alors que le relais est joignable).
     */
    fun send(message: JSONObject, bluetooth: Boolean = true, done: (Boolean) -> Unit): Boolean {
        val target = peers[Via.WIFI] ?: peers[Via.BLUETOOTH]?.takeIf { bluetooth } ?: return false
        runCatching {
            target.writer.execute {
                val result = runCatching { write(target, message) }
                result.exceptionOrNull()?.let { Log.w(TAG, "envoi impossible (${target.via.label}) : ${it.message}") }
                val ok = result.isSuccess
                if (!ok) drop(target)
                done(ok)
            }
        }.onFailure { return false } // liaison fermée entre-temps
        return true
    }

    /** Session sur une liaison BLE qui vient de s'ouvrir (appelé par [BleLink], sur un fil dédié). */
    fun serveBluetooth(channel: Channel) {
        if (!admit()) return channel.close()
        serve(channel, Via.BLUETOOTH)
    }

    /** Message `local` envoyé au Mac par le relais : où joindre le téléphone quand Bonjour ne passe pas. */
    fun announcement(): JSONObject? {
        val port = port.takeIf { it > 0 } ?: return null
        return JSONObject().put("kind", "local").put("port", port).put("addrs", JSONArray(addresses()))
    }

    /** Wi-Fi et point d'accès d'abord, puis le reste (Tailscale) ; jamais le réseau mobile. */
    private fun addresses(): List<String> = runCatching {
        NetworkInterface.getNetworkInterfaces().toList()
            .filter { it.isUp && !it.isLoopback && !it.name.startsWith("rmnet") && !it.name.contains("dummy") }
            .sortedBy { if (it.name.startsWith("wlan") || it.name.startsWith("swlan") || it.name.startsWith("ap")) 0 else 1 }
            .flatMap { iface -> iface.inetAddresses.toList().filterIsInstance<Inet4Address>() }
            .filter { !it.isLinkLocalAddress && !it.isLoopbackAddress }
            .mapNotNull { it.hostAddress }
    }.getOrDefault(emptyList())

    // --- Bonjour ---

    private fun register(context: Context, id: String, port: Int) {
        val manager = context.getSystemService(NsdManager::class.java) ?: return
        val info = NsdServiceInfo().apply {
            serviceName = "Navette-$id"
            serviceType = SERVICE_TYPE
            setPort(port)
            setAttribute("id", id)
        }
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {
                Log.i(TAG, "annoncé : ${info.serviceName}")
            }

            override fun onRegistrationFailed(info: NsdServiceInfo, code: Int) {
                Log.w(TAG, "annonce refusée ($code)")
            }

            override fun onServiceUnregistered(info: NsdServiceInfo) {}
            override fun onUnregistrationFailed(info: NsdServiceInfo, code: Int) {}
        }
        runCatching { manager.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener) }
            .onFailure { Log.w(TAG, "Bonjour indisponible", it) }
        nsd = manager
        registration = listener
    }

    // --- Connexions ---

    private fun acceptLoop(server: ServerSocket) {
        while (!server.isClosed) {
            val socket = runCatching { server.accept() }.getOrNull() ?: break
            if (!admit()) {
                runCatching { socket.close() }
                continue
            }
            socket.tcpNoDelay = true
            Thread({ serve(TcpChannel(socket), Via.WIFI) }, "navette-local-mac").start()
        }
    }

    /** Quelques poignées de main à la fois au plus : un inconnu ne peut pas épuiser le téléphone. */
    private fun admit(): Boolean {
        if (handshakes.incrementAndGet() <= 4) return true
        handshakes.decrementAndGet()
        return false
    }

    private class TcpChannel(private val socket: Socket) : Channel {
        override val input: InputStream = socket.getInputStream()
        override val output: OutputStream = socket.getOutputStream()
        override val address: String = socket.inetAddress?.hostAddress ?: "?"
        override fun setReadTimeout(ms: Int) { socket.soTimeout = ms }
        override fun close() = socket.close()
    }

    private fun serve(channel: Channel, via: Via) {
        var me: Peer? = null
        try {
            val keys = keys ?: throw IOException("liaison arrêtée")
            // Le BLE est plus lent à établir (découverte des services, abonnement) : délai plus large.
            channel.setReadTimeout(if (via == Via.WIFI) 6_000 else 20_000)
            val input = DataInputStream(channel.input.buffered())

            // Poignée de main : hello (Mac) → hello + preuve (téléphone) → auth (Mac) → ready.
            val hello = read(input, MAX_HANDSHAKE_FRAME)
            val macNonce = hello.optString("nonce")
            if (hello.optString("type") != "hello" || macNonce.length < 16) {
                // En Bluetooth, Android ne coupe pas toujours la liaison : le Mac écrit encore dans une
                // session close de notre côté. On lui dit de recommencer la poignée de main.
                if (via == Via.BLUETOOTH) runCatching { write(Peer(channel, via), JSONObject().put("type", "reset")) }
                throw IOException("hello attendu")
            }
            val phoneNonce = nonce()
            val candidate = Peer(channel, via)
            write(candidate, JSONObject()
                .put("type", "hello").put("v", 1).put("nonce", phoneNonce)
                .put("proof", NavetteCrypto.localProof(keys.localKey, NavetteCrypto.PHONE, macNonce, phoneNonce)))
            val auth = read(input, MAX_HANDSHAKE_FRAME)
            val expected = NavetteCrypto.localProof(keys.localKey, NavetteCrypto.MAC, macNonce, phoneNonce)
            if (auth.optString("type") != "auth" ||
                !MessageDigest.isEqual(auth.optString("proof").toByteArray(), expected.toByteArray())
            ) throw IOException("Mac non reconnu")
            write(candidate, JSONObject().put("type", "ready"))
            handshakes.decrementAndGet()
            me = candidate

            peers.put(via, candidate)?.close()
            Log.i(TAG, "Mac connecté (${via.label}, ${channel.address})")
            Relay.notifyListeners()

            channel.setReadTimeout(90_000) // le Mac envoie un ping toutes les 15 s
            while (true) {
                val message = read(input, MAX_FRAME)
                when (message.optString("type")) {
                    "clip" -> {
                        Log.i(TAG, "élément reçu (${via.label}, ${message.optString("data").length / 1024} Ko)")
                        onMessage?.invoke(message)
                    }
                    "ping" -> runCatching {
                        candidate.writer.execute { runCatching { write(candidate, JSONObject().put("type", "pong")) } }
                    }
                }
            }
        } catch (e: Exception) {
            if (me == null) handshakes.decrementAndGet()
            Log.i(TAG, "connexion fermée (${via.label}) : ${e.message}")
        } finally {
            runCatching { channel.close() }
            if (me != null) drop(me)
        }
    }

    private fun drop(target: Peer) {
        target.close()
        if (peers.remove(target.via, target)) {
            Log.i(TAG, "Mac déconnecté (${target.via.label})")
            Relay.notifyListeners()
        }
    }

    // --- Trames : longueur sur 4 octets (gros-boutiste) puis JSON en UTF-8 ---

    private fun read(input: DataInputStream, limit: Int): JSONObject {
        val length = input.readInt()
        if (length <= 0 || length > limit) throw IOException("trame de $length octets")
        val bytes = ByteArray(length)
        input.readFully(bytes)
        return JSONObject(String(bytes, Charsets.UTF_8))
    }

    private fun write(target: Peer, message: JSONObject) {
        val bytes = message.toString().toByteArray(Charsets.UTF_8)
        synchronized(target) {
            target.output.writeInt(bytes.size)
            target.output.write(bytes)
            target.output.flush()
        }
    }

    private fun nonce(): String = ByteArray(16).also { SecureRandom().nextBytes(it) }
        .let { Base64.getEncoder().encodeToString(it) }
}

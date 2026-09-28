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
import java.net.Inet4Address
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.Socket
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/**
 * Liaison directe avec le Mac, sans serveur (voir « Liaison locale » dans PROTOCOL.md).
 * Le téléphone écoute sur [PORT] et s'annonce en Bonjour (`_navette._tcp`) ; le Mac s'y connecte,
 * les deux prouvent qu'ils détiennent le secret, puis les éléments chiffrés passent comme par le relais.
 * Démarrée et arrêtée par [RelayService].
 */
object LocalLink {
    const val PORT = 3201
    private const val SERVICE_TYPE = "_navette._tcp"
    private const val TAG = "NavetteLocal"
    private const val MAX_FRAME = 24 * 1024 * 1024
    private const val MAX_HANDSHAKE_FRAME = 4096

    private class Peer(val socket: Socket, val output: DataOutputStream) {
        val address: String = socket.inetAddress?.hostAddress ?: "?"
        fun close() = runCatching { socket.close() }
    }

    @Volatile private var peer: Peer? = null
    @Volatile private var server: ServerSocket? = null
    private var nsd: NsdManager? = null
    private var registration: NsdManager.RegistrationListener? = null
    /** Écritures hors du fil principal, dans l'ordre. */
    private val writer = Executors.newSingleThreadExecutor()
    private val handshakes = AtomicInteger()

    val isConnected: Boolean get() = peer != null
    /** Adresse du Mac connecté, pour l'écran principal. */
    val peerAddress: String? get() = peer?.address
    /** Port réellement ouvert (0 si arrêté). */
    val port: Int get() = server?.localPort ?: 0

    /** [onMessage] reçoit chaque trame `clip` du Mac, sur le fil de la connexion. */
    @Synchronized
    fun start(context: Context, keys: NavetteCrypto.Keys, onMessage: (JSONObject) -> Unit) {
        if (server != null) return
        val socket = runCatching { ServerSocket(PORT) }
            .getOrElse { ServerSocket(0) } // port pris : n'importe lequel, Bonjour et l'annonce le donnent
        server = socket
        Thread({ acceptLoop(socket, keys, onMessage) }, "navette-local").start()
        register(context, keys.localId, socket.localPort)
        Log.i(TAG, "à l’écoute sur le port ${socket.localPort}")
    }

    @Synchronized
    fun stop() {
        registration?.let { runCatching { nsd?.unregisterService(it) } }
        registration = null
        runCatching { server?.close() }
        server = null
        peer?.close()
        peer = null
        Relay.notifyListeners()
    }

    /**
     * Envoie une trame au Mac si la liaison est établie ; `done(false)` si l'écriture échoue
     * (l'appelant passe alors par le relais). Renvoie false si pas de liaison.
     */
    fun send(message: JSONObject, done: (Boolean) -> Unit): Boolean {
        val target = peer ?: return false
        writer.execute {
            val ok = runCatching { write(target, message) }.isSuccess
            if (!ok) drop(target)
            done(ok)
        }
        return true
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

    private fun acceptLoop(server: ServerSocket, keys: NavetteCrypto.Keys, onMessage: (JSONObject) -> Unit) {
        while (!server.isClosed) {
            val socket = runCatching { server.accept() }.getOrNull() ?: break
            // Quelques poignées de main à la fois au plus : un inconnu du réseau ne peut pas épuiser le téléphone.
            if (handshakes.incrementAndGet() > 4) {
                handshakes.decrementAndGet()
                runCatching { socket.close() }
                continue
            }
            Thread({ serve(socket, keys, onMessage) }, "navette-local-mac").start()
        }
    }

    private fun serve(socket: Socket, keys: NavetteCrypto.Keys, onMessage: (JSONObject) -> Unit) {
        var me: Peer? = null
        try {
            socket.tcpNoDelay = true
            socket.soTimeout = 6_000
            val input = DataInputStream(socket.getInputStream().buffered())
            val output = DataOutputStream(socket.getOutputStream().buffered())

            // Poignée de main : hello (Mac) → hello + preuve (téléphone) → auth (Mac) → ready.
            val hello = read(input, MAX_HANDSHAKE_FRAME)
            val macNonce = hello.optString("nonce")
            if (hello.optString("type") != "hello" || macNonce.length < 16) throw IOException("hello attendu")
            val phoneNonce = nonce()
            val candidate = Peer(socket, output)
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

            // Un seul Mac à la fois : la connexion la plus récente remplace l'ancienne.
            peer?.close()
            peer = candidate
            Log.i(TAG, "Mac connecté depuis ${candidate.address}")
            Relay.notifyListeners()

            socket.soTimeout = 45_000 // le Mac envoie un ping toutes les 15 s
            while (true) {
                val message = read(input, MAX_FRAME)
                when (message.optString("type")) {
                    "clip" -> onMessage(message)
                    "ping" -> writer.execute { runCatching { write(candidate, JSONObject().put("type", "pong")) } }
                }
            }
        } catch (e: Exception) {
            if (me == null) handshakes.decrementAndGet()
            Log.i(TAG, "connexion fermée : ${e.message}")
        } finally {
            runCatching { socket.close() }
            if (me != null) drop(me)
        }
    }

    private fun drop(target: Peer) {
        target.close()
        if (peer === target) {
            peer = null
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

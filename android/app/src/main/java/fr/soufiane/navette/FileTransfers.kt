package fr.soufiane.navette

import android.app.DownloadManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Environment
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.util.Log
import android.webkit.MimeTypeMap
import org.json.JSONObject
import java.io.File
import java.io.InputStream
import java.io.RandomAccessFile
import java.util.Base64
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Fichiers quelconques, découpés en morceaux chiffrés un à un (messages `file`, voir « Files » dans
 * PROTOCOL.md), comme l'app Mac (FileTransfer.swift). Après le dernier morceau, `file-end` ;
 * le destinataire répond `file-ack` avec les plages manquantes, renvoyées. Reçus dans
 * Téléchargements/Navette.
 */
object FileTransfers {
    private const val TAG = "NavetteFichier"
    /** Wi-Fi. */
    const val CHUNK = 512 * 1024
    /** Bluetooth : une trame doit passer bien avant le délai de 40 s du Mac. */
    const val BLUETOOTH_CHUNK = 32 * 1024
    /** Au-delà, pas de Bluetooth (environ 50 Ko/s). */
    const val MAX_BLUETOOTH_BYTES = 2L * 1024 * 1024
    const val MAX_BYTES = 4L * 1024 * 1024 * 1024
    /** Une liaison morte met 40 s à se révéler côté Mac. */
    private const val STALE_MS = 120_000L
    private const val ACK_TIMEOUT_S = 20L
    private const val MAX_END_ATTEMPTS = 4
    private const val MAX_ROUNDS = 10
    private const val MAX_RETRIES = 20
    private const val MAX_MISSING_RANGES = 1000
    private const val MAX_CONCURRENT = 4

    private const val CHANNEL_PROGRESS = "transferts"
    private const val CHANNEL_DONE = "fichiers"
    const val ACTION_CANCEL = "fr.soufiane.navette.ANNULER_ENVOI"
    private const val NOTIF_SEND = 40

    // --- Envoi : un fichier à la fois, sur un fil dédié ---

    private val sender = Executors.newSingleThreadExecutor()
    @Volatile private var cancelled = false
    @Volatile private var pending = 0
    /** Réponses du Mac (`file-ack`, `file-cancel`) à l'envoi en cours. */
    private val replies = java.util.concurrent.ConcurrentHashMap<String, java.util.concurrent.LinkedBlockingQueue<JSONObject>>()

    /**
     * Envoie ces fichiers au Mac. Les URI viennent d'un partage : l'appelant (une activité) doit
     * encore y avoir accès ; on s'accorde un accès durable pour les lire après sa fermeture.
     */
    fun send(context: Context, uris: List<Uri>) {
        val app = context.applicationContext
        for (uri in uris) {
            runCatching { context.grantUriPermission(app.packageName, uri, Intent.FLAG_GRANT_READ_URI_PERMISSION) }
        }
        cancelled = false
        pending += uris.size
        sender.execute {
            var sent = 0
            var lastName = ""
            for (uri in uris) {
                pending--
                if (cancelled) continue
                val result = runCatching { sendOne(app, uri) { lastName = it } }
                val error = result.getOrElse { it.message ?: "erreur" }
                runCatching { app.revokeUriPermission(app.packageName, uri, Intent.FLAG_GRANT_READ_URI_PERMISSION) }
                if (error != null) {
                    Log.w(TAG, "envoi impossible : $error")
                    notifyDone(app, "Fichier non envoyé", if (lastName.isEmpty()) error else "$lastName : $error", null)
                } else {
                    sent++
                }
            }
            app.getSystemService(NotificationManager::class.java).cancel(NOTIF_SEND)
            if (sent > 0 && !cancelled) {
                notifyDone(app, if (sent > 1) "$sent fichiers envoyés au Mac" else "Fichier envoyé au Mac", lastName, null)
            }
        }
    }

    fun cancel() {
        cancelled = true
    }

    /** null si envoyé, sinon la raison. */
    private fun sendOne(context: Context, uri: Uri, onName: (String) -> Unit): String? {
        val settings = Settings(context)
        val keys = settings.keys() ?: return "Navette n’est pas appairée"
        val resolver = context.contentResolver
        var name = "fichier"
        var size = -1L
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { c ->
            if (c.moveToFirst()) {
                c.getString(0)?.let { name = safeName(it) }
                if (!c.isNull(1)) size = c.getLong(1)
            }
        }
        onName(name)
        if (size < 0) size = resolver.openAssetFileDescriptor(uri, "r")?.use { it.length } ?: -1
        if (size < 0) return "taille inconnue"
        if (size > MAX_BYTES) return "trop gros (plus de 4 Go)"
        val mime = resolver.getType(uri)

        val (chunk, _) = route(size) ?: return if (LocalLink.isConnected) {
            "trop gros sans liaison Wi-Fi avec le Mac (${formatSize(size)})"
        } else "Mac injoignable"
        Log.i(TAG, "envoi de « $name » (${formatSize(size)}, morceaux de ${chunk / 1024} Ko)")
        val fid = UUID.randomUUID().toString()
        val inbox = java.util.concurrent.LinkedBlockingQueue<JSONObject>()
        replies[fid] = inbox
        try {
            val link = Link(context, settings, uri, fid, name, size, mime)
            var ranges = listOf(0L to size)
            var rounds = 0
            while (true) {
                for ((start, end) in ranges) link.sendRange(start, end)?.let { return it }
                // Tout est parti : le Mac dit ce qui lui manque (morceaux perdus sur une liaison morte).
                var answer: JSONObject? = null
                for (attempt in 1..MAX_END_ATTEMPTS) {
                    if (cancelled) return link.cancel()
                    // Même chemin que les morceaux : il arrive après eux. `n` identifie la réponse.
                    val n = rounds * 100 + attempt
                    Transport.sendPayload(settings, JSONObject().put("kind", "file-end").put("fid", fid)
                        .put("name", name).put("size", size).put("n", n), ephemeral = true,
                        allowBluetooth = route(size)?.second ?: true)
                    val deadline = System.currentTimeMillis() + ACK_TIMEOUT_S * 1000
                    while (answer == null) {
                        val wait = deadline - System.currentTimeMillis()
                        if (wait <= 0) break
                        val reply = inbox.poll(wait, TimeUnit.MILLISECONDS) ?: break
                        // Réponse à un `file-end` précédent (morceaux encore en route) : ignorée, sauf « tout reçu ».
                        val complete = reply.optJSONArray("missing")?.length() == 0
                        if (reply.optString("kind") == "file-cancel" || complete || !reply.has("n") || reply.optInt("n") == n) {
                            answer = reply
                        }
                    }
                    if (answer != null) break
                }
                answer ?: return "pas de confirmation du Mac"
                if (answer.optString("kind") == "file-cancel") return "refusé par le Mac"
                val missing = answer.optJSONArray("missing") ?: return "réponse du Mac illisible"
                ranges = (0 until missing.length()).mapNotNull { i ->
                    val pair = missing.optJSONArray(i) ?: return@mapNotNull null
                    val a = pair.optLong(0, -1)
                    val b = pair.optLong(1, -1)
                    if (a in 0..b && b <= size) a to b else null
                }
                if (missing.length() == 0) return null
                if (ranges.isEmpty()) return "réponse du Mac illisible"
                if (++rounds > MAX_ROUNDS) return "trop de morceaux perdus"
                Log.i(TAG, "« $name » : ${ranges.size} plage(s) à renvoyer")
                inbox.clear()
            }
        } finally {
            replies.remove(fid)
        }
    }

    /**
     * Wi-Fi direct pour tout ; sinon le Bluetooth jusqu'à 2 Mo. Taille des morceaux et Bluetooth
     * permis ou non ; null = aucun chemin pour l'instant. Réévalué à chaque morceau : Wi-Fi perdu
     * en route → Bluetooth, Wi-Fi retrouvé…
     */
    private fun route(size: Long): Pair<Int, Boolean>? = when {
        LocalLink.isConnected(LocalLink.Via.WIFI) -> CHUNK to false
        LocalLink.isConnected(LocalLink.Via.BLUETOOTH) && size <= MAX_BLUETOOTH_BYTES -> BLUETOOTH_CHUNK to true
        else -> null
    }

    /** Envoi des morceaux d'un fichier (et renvoi des plages perdues). */
    private class Link(
        val context: Context, val settings: Settings, val uri: Uri, val fid: String, val name: String,
        val size: Long, val mime: String?,
    ) {
        private var sent = 0L
        private var lastNotified = 0L

        fun cancel(): String {
            Transport.sendPayload(settings, JSONObject().put("kind", "file-cancel").put("fid", fid), ephemeral = true)
            return "annulé"
        }

        /** Envoie [start, end) ; null si tout est parti, sinon la raison. */
        fun sendRange(start: Long, end: Long): String? {
            val input = context.contentResolver.openInputStream(uri) ?: return "fichier illisible"
            input.use {
                var skipped = 0L
                while (skipped < start) {
                    val n = input.skip(start - skipped)
                    if (n <= 0) return "fichier modifié pendant l’envoi"
                    skipped += n
                }
                var offset = start
                val buffer = ByteArray(CHUNK)
                do { // un fichier vide part quand même en un morceau vide
                    if (cancelled) return cancel()
                    var retries = 0
                    var path = route(size)
                    while (path == null) {
                        // Liaison qui change (Wi-Fi perdu, Bluetooth en cours de connexion) : on attend un moment.
                        if (++retries > MAX_RETRIES || cancelled) return "liaison perdue"
                        Thread.sleep(2_000)
                        path = route(size)
                    }
                    val wanted = minOf(path.first.toLong(), end - offset).toInt()
                    val n = readFully(input, buffer, wanted)
                    if (n < wanted) return "fichier modifié pendant l’envoi"
                    val meta = JSONObject()
                        .put("kind", "file").put("fid", fid).put("name", name).put("size", size).put("off", offset)
                    if (mime != null) meta.put("mime", mime)
                    // Chiffré aussitôt (copie) : le tampon peut resservir au morceau suivant.
                    val bytes = if (n == buffer.size) buffer else buffer.copyOf(n)
                    while (true) {
                        val error = sendAndWait(settings, meta, bytes, path!!.second) ?: break
                        if (++retries > MAX_RETRIES || cancelled) return error
                        Thread.sleep(2_000)
                        path = route(size) ?: path
                    }
                    offset += n
                    sent = minOf(size, sent + n)
                    val now = System.currentTimeMillis()
                    if (now - lastNotified > 500) {
                        lastNotified = now
                        notifyProgress(context, "Envoi au Mac : $name", sent, size)
                    }
                } while (offset < end)
            }
            return null
        }
    }

    /** `file-ack` ou `file-cancel` du Mac pour un envoi du téléphone. false si ce n'en est pas un. */
    private fun replyToSender(payload: JSONObject): Boolean {
        val inbox = replies[payload.optString("fid")] ?: return payload.optString("kind") == "file-ack"
        inbox.offer(payload)
        return true
    }

    /** Envoie un morceau et attend qu'il soit parti : pas de file d'attente de plusieurs Go. */
    private fun sendAndWait(settings: Settings, meta: JSONObject, bytes: ByteArray, bluetooth: Boolean): String? {
        val latch = CountDownLatch(1)
        var error: String? = null
        Transport.sendChunk(settings, meta, bytes, allowBluetooth = bluetooth) {
            error = it
            latch.countDown()
        }
        if (!latch.await(120, TimeUnit.SECONDS)) return "délai dépassé"
        return error
    }

    private fun readFully(input: InputStream, buffer: ByteArray, wanted: Int): Int {
        var total = 0
        while (total < wanted) {
            val n = input.read(buffer, total, wanted - total)
            if (n < 0) break
            total += n
        }
        return total
    }

    // --- Réception : fichiers réassemblés dans le cache, puis copiés dans Téléchargements ---

    /**
     * Plages d'octets reçues, fusionnées : des morceaux de tailles différentes (le chemin, donc la
     * taille des morceaux, peut changer en cours d'envoi) qui se chevauchent ne comptent qu'une fois.
     */
    class Coverage {
        /** Début → fin, plages disjointes [début, fin). */
        private val ranges = java.util.TreeMap<Long, Long>()
        var total = 0L
            private set

        /** Ajoute [start, end) ; renvoie le nombre d'octets nouveaux. */
        fun add(start: Long, end: Long): Long {
            if (end <= start) return 0
            var lower = start
            var upper = end
            var overlap = 0L
            // Plages qui chevauchent ou touchent [start, end).
            val touching = ranges.subMap(ranges.floorKey(start) ?: start, true, end, true)
                .entries.filter { it.value >= start }.map { it.key to it.value }
            for ((a, b) in touching) {
                overlap += maxOf(0L, minOf(b, end) - maxOf(a, start))
                lower = minOf(lower, a)
                upper = maxOf(upper, b)
                ranges.remove(a)
            }
            ranges[lower] = upper
            val added = (end - start) - overlap
            total += added
            return added
        }

        fun missing(size: Long): List<List<Long>> {
            val gaps = mutableListOf<List<Long>>()
            var cursor = 0L
            for ((a, b) in ranges) {
                if (a > cursor) gaps += listOf(cursor, a)
                cursor = maxOf(cursor, b)
            }
            if (cursor < size) gaps += listOf(cursor, size)
            return gaps
        }
    }

    private class Incoming(val name: String, val size: Long, val mime: String?, val file: File, val out: RandomAccessFile) {
        val coverage = Coverage()
        /** Pour un fichier vide : son unique morceau (vide) est arrivé. */
        var sawEmpty = false
        val received: Long get() = coverage.total
        var lastChunk = System.currentTimeMillis()
        var lastNotified = 0L
        val notifId = 100 + (file.name.hashCode() and 0xffff)

        /** Plages [début, fin) pas encore reçues. */
        fun missing(): List<List<Long>> {
            if (size == 0L) return if (sawEmpty) emptyList() else listOf(listOf(0L, 0L))
            return coverage.missing(size).take(MAX_MISSING_RANGES)
        }
    }

    private val receiver = Executors.newSingleThreadScheduledExecutor()
    private val incoming = HashMap<String, Incoming>()
    /** Transferts finis (true) ou abandonnés (false) : un morceau en retard ne rouvre rien, et un
     *  `file-end` répété reçoit la même réponse. */
    private val closed = HashMap<String, Boolean>()
    @Volatile private var expiryStarted = false

    /** Message `file…` du Mac, déjà déchiffré : pour la réception, ou réponse à un envoi. */
    fun receive(context: Context, payload: JSONObject) {
        if (replyToSender(payload)) return
        val app = context.applicationContext
        if (!expiryStarted) {
            expiryStarted = true
            receiver.scheduleWithFixedDelay({ expire(app) }, 15, 15, TimeUnit.SECONDS)
        }
        receiver.execute { runCatching { accept(app, payload) }.onFailure { Log.w(TAG, "morceau refusé", it) } }
    }

    private fun reply(context: Context, fid: String, missing: List<List<Long>>?, n: Any? = null) {
        val payload = if (missing == null) JSONObject().put("kind", "file-cancel").put("fid", fid)
            else JSONObject().put("kind", "file-ack").put("fid", fid).put("missing", org.json.JSONArray(missing.map { org.json.JSONArray(it) }))
        if (n != null && missing != null) payload.put("n", n)
        Transport.sendPayload(Settings(context), payload, ephemeral = true)
    }

    private fun accept(context: Context, payload: JSONObject) {
        val fid = payload.optString("fid")
        if (fid.length !in 8..64 || !fid.all { it.isLetterOrDigit() || it == '-' }) return
        when (payload.optString("kind")) {
            "file-cancel" -> {
                incoming[fid]?.let { fail(context, fid, it, "annulé sur le Mac", tellSender = false) }
                return
            }
            "file-end" -> {
                val done = closed[fid]
                val transfer = incoming[fid]
                val size = payload.optLong("size", -1)
                val n = payload.opt("n") // renvoyé tel quel : l'expéditeur ignore les réponses périmées
                when {
                    done != null -> reply(context, fid, if (done) emptyList() else null, n)
                    transfer != null -> {
                        transfer.lastChunk = System.currentTimeMillis()
                        reply(context, fid, transfer.missing(), n)
                    }
                    size in 0..MAX_BYTES -> reply(context, fid, listOf(listOf(0L, size)), n) // rien reçu
                }
                return
            }
            "file" -> if (fid in closed) return
            else -> return
        }
        val size = payload.optLong("size", -1)
        val offset = payload.optLong("off", -1)
        // Octets bruts (morceau binaire) ou base64.
        val data = payload.opt("data") as? ByteArray
            ?: runCatching { Base64.getDecoder().decode(payload.getString("data")) }.getOrNull()
        val known = incoming[fid]
        if (size !in 0..MAX_BYTES || offset < 0 || data == null || offset + data.size > size || (known != null && known.size != size)) {
            known?.let { fail(context, fid, it, "morceau invalide") }
            return
        }
        val transfer = known ?: run {
            if (incoming.size >= MAX_CONCURRENT) return
            val dir = File(context.cacheDir, "fichiers-en-cours").apply { mkdirs() }
            val file = File(dir, "$fid.part")
            Incoming(safeName(payload.optString("name")), size, payload.optString("mime").ifEmpty { null },
                file, RandomAccessFile(file, "rw")).also {
                incoming[fid] = it
                Log.i(TAG, "réception de « ${it.name} » (${formatSize(size)})")
            }
        }
        transfer.lastChunk = System.currentTimeMillis()
        transfer.out.seek(offset)
        transfer.out.write(data) // un chevauchement réécrit les mêmes octets
        val added = transfer.coverage.add(offset, offset + data.size)
        if (size == 0L) transfer.sawEmpty = true
        if (added == 0L && size > 0) return // doublon (renvoi d'un morceau arrivé en retard)
        if (transfer.received < size) {
            val now = System.currentTimeMillis()
            if (now - transfer.lastNotified > 500) {
                transfer.lastNotified = now
                notifyProgress(context, "Réception du Mac : ${transfer.name}", transfer.received, size, transfer.notifId, cancel = false)
            }
            return
        }
        incoming.remove(fid)
        closed[fid] = true
        transfer.out.close()
        reply(context, fid, emptyList())
        context.getSystemService(NotificationManager::class.java).cancel(transfer.notifId)
        val uri = runCatching { publish(context, transfer) }
            .onFailure { Log.w(TAG, "enregistrement impossible", it) }
            .getOrNull()
        transfer.file.delete()
        if (uri == null) {
            notifyDone(context, "Fichier non reçu", "${transfer.name} : impossible de l’enregistrer", null)
        } else {
            Log.i(TAG, "fichier reçu : ${transfer.name}")
            notifyDone(context, "Fichier reçu du Mac", "${transfer.name} · Téléchargements/Navette", uri to mimeOf(transfer))
        }
    }

    /** Copie dans Téléchargements/Navette (Android renomme en cas de doublon). */
    private fun publish(context: Context, transfer: Incoming): Uri? {
        val resolver = context.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, transfer.name)
            put(MediaStore.Downloads.MIME_TYPE, mimeOf(transfer))
            put(MediaStore.Downloads.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/Navette")
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values) ?: return null
        try {
            resolver.openOutputStream(uri)?.use { out -> transfer.file.inputStream().use { it.copyTo(out, 256 * 1024) } }
                ?: throw IllegalStateException("écriture refusée")
            resolver.update(uri, ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }, null, null)
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            throw e
        }
        return uri
    }

    private fun mimeOf(transfer: Incoming): String =
        transfer.mime?.takeIf { it.contains('/') }
            ?: MimeTypeMap.getSingleton().getMimeTypeFromExtension(transfer.name.substringAfterLast('.', "").lowercase())
            ?: "application/octet-stream"

    private fun fail(context: Context, fid: String, transfer: Incoming, reason: String, tellSender: Boolean = true) {
        incoming.remove(fid)
        closed[fid] = false
        if (tellSender) reply(context, fid, null)
        runCatching { transfer.out.close() }
        transfer.file.delete()
        context.getSystemService(NotificationManager::class.java).cancel(transfer.notifId)
        Log.i(TAG, "« ${transfer.name} » : $reason")
        notifyDone(context, "Fichier non reçu", "${transfer.name} : $reason", null)
    }

    private fun expire(context: Context) {
        val now = System.currentTimeMillis()
        incoming.filterValues { now - it.lastChunk > STALE_MS }.forEach { (fid, t) -> fail(context, fid, t, "interrompu") }
    }

    // --- Noms et tailles ---

    /** Nom de fichier sûr : ni chemin, ni fichier caché, ni caractère de contrôle (comme sur le Mac). */
    fun safeName(raw: String): String {
        var name = raw.split('/', '\\').last().filter { !it.isISOControl() }.replace(':', '-').trim().trimStart('.')
        if (name.toByteArray().size > 200) {
            val ext = name.substringAfterLast('.', "")
            val base = name.substringBeforeLast('.').take(150)
            name = if (ext.isEmpty() || ext.length > 20) base else "$base.$ext"
        }
        return name.ifEmpty { "fichier" }
    }

    fun formatSize(bytes: Long): String = when {
        bytes >= 1024L * 1024 * 1024 -> String.format("%.1f Go", bytes / (1024.0 * 1024 * 1024))
        bytes >= 1024L * 1024 -> String.format("%.1f Mo", bytes / (1024.0 * 1024))
        bytes >= 1024 -> "${bytes / 1024} Ko"
        else -> "$bytes octets"
    }

    // --- Notifications ---

    private fun channels(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_PROGRESS, "Transferts en cours", NotificationManager.IMPORTANCE_LOW),
        )
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_DONE, "Fichiers reçus et envoyés", NotificationManager.IMPORTANCE_DEFAULT),
        )
    }

    private fun notifyProgress(context: Context, title: String, done: Long, total: Long, id: Int = NOTIF_SEND, cancel: Boolean = true) {
        channels(context)
        val percent = if (total > 0) (done * 100 / total).toInt() else 100
        val builder = Notification.Builder(context, CHANNEL_PROGRESS)
            .setSmallIcon(R.drawable.ic_navette)
            .setContentTitle(title)
            .setContentText("${formatSize(done)} sur ${formatSize(total)}")
            .setProgress(100, percent, false)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
        if (cancel) {
            val intent = PendingIntent.getBroadcast(
                context, 0, Intent(context, CancelTransferReceiver::class.java), PendingIntent.FLAG_IMMUTABLE,
            )
            builder.addAction(Notification.Action.Builder(null, "Annuler", intent).build())
            if (pending > 0) builder.setSubText("+$pending en attente")
        }
        context.getSystemService(NotificationManager::class.java).notify(id, builder.build())
    }

    /** [file] : fichier reçu, ouvert au toucher (ou Téléchargements si aucune app ne sait l'ouvrir). */
    private fun notifyDone(context: Context, title: String, text: String, file: Pair<Uri, String>?) {
        channels(context)
        val builder = Notification.Builder(context, CHANNEL_DONE)
            .setSmallIcon(R.drawable.ic_navette)
            .setContentTitle(title)
            .setContentText(text)
            .setAutoCancel(true)
        if (file != null) {
            val view = Intent(Intent.ACTION_VIEW).setDataAndType(file.first, file.second)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            val open = if (view.resolveActivity(context.packageManager) != null) view
                else Intent(DownloadManager.ACTION_VIEW_DOWNLOADS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            builder.setContentIntent(
                PendingIntent.getActivity(context, file.first.hashCode(), open, PendingIntent.FLAG_IMMUTABLE),
            )
        }
        context.getSystemService(NotificationManager::class.java)
            .notify(1000 + (System.nanoTime() and 0xffff).toInt(), builder.build())
    }
}

/** Bouton « Annuler » de la notification d'envoi. */
class CancelTransferReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) = FileTransfers.cancel()
}

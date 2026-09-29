package fr.soufiane.navette

import org.json.JSONObject
import java.security.SecureRandom
import java.util.Base64
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Protocole Navette v2 — identique à l'app Mac (vecteurs de test communs).
 * v2 : les données associées lient chaque élément à son expéditeur (« mac » ou « phone ») ; les
 * messages reçus en direct passent par [ReplayGuard].
 */
object NavetteCrypto {
    /**
     * [fingerprint] : code à 6 chiffres affiché aussi par le Mac, pour vérifier l'appairage.
     * [localKey] et [localId] : liaison directe sur le réseau local (voir [LocalLink]).
     */
    class Keys(
        val token: String,
        val encKey: ByteArray,
        val fingerprint: String,
        val localKey: ByteArray,
        val localId: String,
    )

    const val MAC = "mac"
    const val PHONE = "phone"

    private fun aad(from: String, id: String) = "navette/v2|$from|$id".toByteArray(Charsets.UTF_8)

    /** Élément chiffré tel qu'il circule entre les appareils. */
    data class Clip(val id: String, val iv: String, val data: String) {
        fun toJson(): JSONObject = JSONObject().put("id", id).put("iv", iv).put("data", data)

        companion object {
            fun fromJson(o: JSONObject) = Clip(o.getString("id"), o.getString("iv"), o.getString("data"))
        }
    }

    fun deriveKeys(secret: String): Keys {
        val secretBytes = Base64.getUrlDecoder().decode(secret.trim())
        require(secretBytes.size >= 16) { "secret trop court" }
        fun hmac(label: String): ByteArray = Mac.getInstance("HmacSHA256").run {
            init(SecretKeySpec(secretBytes, "HmacSHA256"))
            doFinal(label.toByteArray(Charsets.UTF_8))
        }
        val digest = hmac("navette/fingerprint/v1")
        val n = ((digest[0].toLong() and 0xff) shl 24 or ((digest[1].toLong() and 0xff) shl 16) or
            ((digest[2].toLong() and 0xff) shl 8) or (digest[3].toLong() and 0xff)) % 1_000_000
        val digits = n.toString().padStart(6, '0')
        return Keys(
            token = Base64.getUrlEncoder().withoutPadding().encodeToString(hmac("navette/auth/v1")),
            encKey = hmac("navette/enc/v1"),
            fingerprint = "${digits.take(3)} ${digits.takeLast(3)}",
            localKey = hmac("navette/local/v1"),
            localId = hmac("navette/local-id/v1").take(6).joinToString("") { "%02x".format(it) },
        )
    }

    /** Preuve de la poignée de main de la liaison locale : chacun signe les deux nonces avec son rôle. */
    fun localProof(localKey: ByteArray, role: String, macNonce: String, phoneNonce: String): String {
        val mac = Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(localKey, "HmacSHA256")) }
        val digest = mac.doFinal("navette/local/v1|$role|$macNonce|$phoneNonce".toByteArray(Charsets.UTF_8))
        return Base64.getEncoder().encodeToString(digest)
    }

    /** Chiffre un contenu (voir ClipContent.toPayload pour le format en clair). Le téléphone chiffre en tant que « phone ». */
    fun seal(key: ByteArray, payload: JSONObject, id: String = UUID.randomUUID().toString(), from: String = PHONE): Clip {
        payload.put("t", System.currentTimeMillis())
        val iv = ByteArray(12).also { SecureRandom().nextBytes(it) }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, iv))
        cipher.updateAAD(aad(from, id))
        val data = cipher.doFinal(payload.toString().toByteArray(Charsets.UTF_8)) // chiffré ‖ tag
        val b64 = Base64.getEncoder()
        return Clip(id, b64.encodeToString(iv), b64.encodeToString(data))
    }

    /**
     * Déchiffre un élément venu de [from] (le Mac, par défaut). Lève une exception s'il a été altéré,
     * vient d'un autre secret, ou a été renvoyé à son propre expéditeur.
     */
    fun open(key: ByteArray, clip: Clip, from: String = MAC): JSONObject {
        val b64 = Base64.getDecoder()
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, b64.decode(clip.iv)))
        cipher.updateAAD(aad(from, clip.id))
        return JSONObject(String(cipher.doFinal(b64.decode(clip.data)), Charsets.UTF_8))
    }

    // --- Morceaux de fichier binaires (voir « Binary chunks » dans PROTOCOL.md) ---
    // En clair : 4 octets de longueur, les métadonnées en JSON, puis les octets bruts (sans base64).

    private fun aadBinary(from: String, id: String) = "navette/v2b|$from|$id".toByteArray(Charsets.UTF_8)

    /** [box] : chiffré ‖ tag, tel quel sur une liaison directe. */
    class Chunk(val id: String, val iv: ByteArray, val box: ByteArray) {
        fun toClip(): Clip {
            val b64 = Base64.getEncoder()
            return Clip(id, b64.encodeToString(iv), b64.encodeToString(box))
        }

        companion object {
            /** Un [Clip] qui ne se lit pas en JSON est peut-être un morceau binaire. */
            fun fromClip(clip: Clip): Chunk? = runCatching {
                val b64 = Base64.getDecoder()
                Chunk(clip.id, b64.decode(clip.iv), b64.decode(clip.data))
            }.getOrNull()
        }
    }

    fun sealChunk(key: ByteArray, meta: JSONObject, bytes: ByteArray, id: String = UUID.randomUUID().toString(), from: String = PHONE): Chunk {
        meta.put("t", System.currentTimeMillis())
        val json = meta.toString().toByteArray(Charsets.UTF_8)
        val plaintext = java.nio.ByteBuffer.allocate(4 + json.size + bytes.size).putInt(json.size).put(json).put(bytes).array()
        val iv = ByteArray(12).also { SecureRandom().nextBytes(it) }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, iv))
        cipher.updateAAD(aadBinary(from, id))
        return Chunk(id, iv, cipher.doFinal(plaintext))
    }

    /** Métadonnées et octets ; lève une exception si le morceau a été altéré ou vient d'ailleurs. */
    fun openChunk(key: ByteArray, chunk: Chunk, from: String = MAC): Pair<JSONObject, ByteArray> {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, chunk.iv))
        cipher.updateAAD(aadBinary(from, chunk.id))
        val plaintext = cipher.doFinal(chunk.box)
        val length = java.nio.ByteBuffer.wrap(plaintext, 0, 4).int
        require(length >= 0 && 4 + length <= plaintext.size) { "métadonnées tronquées" }
        val meta = JSONObject(String(plaintext, 4, length, Charsets.UTF_8))
        return meta to plaintext.copyOfRange(4 + length, plaintext.size)
    }

    fun sealText(key: ByteArray, text: String, id: String = UUID.randomUUID().toString(), from: String = PHONE): Clip =
        seal(key, JSONObject().put("kind", "text").put("text", text), id, from)

    /** Renvoie le texte, ou null si l'élément n'est pas du texte. */
    fun openText(key: ByteArray, clip: Clip, from: String = MAC): String? {
        val payload = open(key, clip, from)
        return if (payload.optString("kind") == "text") payload.optString("text") else null
    }
}

/**
 * Refuse les messages reçus qui sont périmés ou déjà vus : un intermédiaire ne peut pas rejouer
 * une réponse ou une sonnerie.
 */
class ReplayGuard(private val capacity: Int = 4096) {
    private val seen = LinkedHashSet<String>()

    @Synchronized
    fun accept(id: String, t: Long, now: Long = System.currentTimeMillis()): Boolean {
        if (t <= 0 || kotlin.math.abs(now - t) > MAX_AGE_MS || !seen.add(id)) return false
        if (seen.size > capacity) seen.remove(seen.first())
        return true
    }

    companion object {
        /** Horloges du Mac et du téléphone comprises. */
        const val MAX_AGE_MS = 5 * 60 * 1000L
    }
}

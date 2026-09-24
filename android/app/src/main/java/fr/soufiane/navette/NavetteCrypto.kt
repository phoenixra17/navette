package fr.soufiane.navette

import org.json.JSONObject
import java.security.SecureRandom
import java.util.Base64
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** Protocole Navette v1 — identique à server/tests/protocol.js et à l'app Mac. */
object NavetteCrypto {
    class Keys(val token: String, val encKey: ByteArray)

    /** Élément chiffré tel qu'il circule par le serveur. */
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
        return Keys(
            token = Base64.getUrlEncoder().withoutPadding().encodeToString(hmac("navette/auth/v1")),
            encKey = hmac("navette/enc/v1"),
        )
    }

    /** Chiffre un contenu (voir ClipContent.toPayload pour le format en clair). */
    fun seal(key: ByteArray, payload: JSONObject, id: String = UUID.randomUUID().toString()): Clip {
        payload.put("t", System.currentTimeMillis())
        val iv = ByteArray(12).also { SecureRandom().nextBytes(it) }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, iv))
        cipher.updateAAD(id.toByteArray(Charsets.UTF_8))
        val data = cipher.doFinal(payload.toString().toByteArray(Charsets.UTF_8)) // chiffré ‖ tag
        val b64 = Base64.getEncoder()
        return Clip(id, b64.encodeToString(iv), b64.encodeToString(data))
    }

    /** Déchiffre un élément. Lève une exception s'il a été altéré ou vient d'un autre secret. */
    fun open(key: ByteArray, clip: Clip): JSONObject {
        val b64 = Base64.getDecoder()
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, b64.decode(clip.iv)))
        cipher.updateAAD(clip.id.toByteArray(Charsets.UTF_8))
        return JSONObject(String(cipher.doFinal(b64.decode(clip.data)), Charsets.UTF_8))
    }

    fun sealText(key: ByteArray, text: String, id: String = UUID.randomUUID().toString()): Clip =
        seal(key, JSONObject().put("kind", "text").put("text", text), id)

    /** Renvoie le texte, ou null si l'élément n'est pas du texte. */
    fun openText(key: ByteArray, clip: Clip): String? {
        val payload = open(key, clip)
        return if (payload.optString("kind") == "text") payload.optString("text") else null
    }
}

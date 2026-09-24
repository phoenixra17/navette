package fr.soufiane.navette

import android.content.ClipData
import android.content.ClipDescription
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.util.Base64

/** Ce qui passe d'un appareil à l'autre : du texte ou une image (PNG / JPEG). */
sealed class ClipContent {
    data class Text(val text: String) : ClipContent()

    class Image(val bytes: ByteArray, val mime: String) : ClipContent() {
        override fun equals(other: Any?) = other is Image && other.mime == mime && other.bytes.contentEquals(bytes)
        override fun hashCode() = bytes.contentHashCode()
    }

    /** Format en clair, identique à l'app Mac : {kind, text} ou {kind, mime, data (base64)}. */
    fun toPayload(): JSONObject = when (this) {
        is Text -> JSONObject().put("kind", "text").put("text", text)
        is Image -> JSONObject().put("kind", "image").put("mime", mime)
            .put("data", Base64.getEncoder().encodeToString(bytes))
    }

    val preview: String
        get() = when (this) {
            is Text -> {
                val oneLine = text.lines().joinToString(" ").trim()
                if (oneLine.length > 40) "« ${oneLine.take(40)}… »" else "« $oneLine »"
            }
            is Image -> {
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
                "image ${bounds.outWidth}×${bounds.outHeight}"
            }
        }

    companion object {
        /** Contenu d'un élément reçu, ou null pour un type inconnu. */
        fun fromPayload(payload: JSONObject): ClipContent? = when (payload.optString("kind")) {
            "text" -> Text(payload.optString("text"))
            "image" -> runCatching {
                Image(Base64.getDecoder().decode(payload.getString("data")), payload.getString("mime"))
            }.getOrNull()
            else -> null
        }

        /**
         * Contenu du presse-papier ou d'un partage. À appeler quand on a le droit de le lire
         * (activité au premier plan). Les contenus marqués sensibles sont ignorés si `skipSensitive`.
         */
        fun fromClip(context: Context, clip: ClipData?, skipSensitive: Boolean = false): ClipContent? {
            if (clip == null || clip.itemCount == 0) return null
            if (skipSensitive && clip.description?.extras?.getBoolean(ClipDescription.EXTRA_IS_SENSITIVE) == true) {
                return null
            }
            val item = clip.getItemAt(0)
            item.uri?.let { uri ->
                val mime = context.contentResolver.getType(uri) ?: clip.description?.getMimeType(0)
                if (mime != null && mime.startsWith("image/")) return fromImageUri(context, uri, mime)
            }
            val text = item.coerceToText(context)?.toString()
            return if (text.isNullOrEmpty()) null else Text(text)
        }

        fun fromImageUri(context: Context, uri: Uri, mime: String): ClipContent? = runCatching {
            val bytes = context.contentResolver.openInputStream(uri)?.use { input ->
                val out = ByteArrayOutputStream()
                val buffer = ByteArray(64 * 1024)
                var total = 0
                while (true) {
                    val n = input.read(buffer)
                    if (n < 0) break
                    total += n
                    if (total > 50 * 1024 * 1024) return null // photo démesurée : on renonce
                    out.write(buffer, 0, n)
                }
                out.toByteArray()
            } ?: return null
            ImageCodec.prepare(bytes, mime)
        }.getOrNull()
    }
}

/** Préparation des images à l'envoi : PNG ou JPEG uniquement, et taille raisonnable (comme sur le Mac). */
object ImageCodec {
    const val MAX_BYTES = 3 * 1024 * 1024
    private const val MAX_SIDE = 2560

    fun prepare(bytes: ByteArray, mime: String): ClipContent.Image? {
        if ((mime == "image/png" || mime == "image/jpeg") && bytes.size <= MAX_BYTES) {
            return ClipContent.Image(bytes, mime)
        }
        // Décodage réduit dès la lecture pour ne pas charger une photo de 200 Mpx en mémoire.
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0) return null
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= MAX_SIDE) sample *= 2
        val decoded = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample })
            ?: return null
        val longest = maxOf(decoded.width, decoded.height)
        val bitmap = if (longest > MAX_SIDE) {
            val ratio = MAX_SIDE.toFloat() / longest
            Bitmap.createScaledBitmap(decoded, (decoded.width * ratio).toInt(), (decoded.height * ratio).toInt(), true)
        } else decoded

        val png = ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
        if (png.size <= MAX_BYTES) return ClipContent.Image(png, "image/png")
        val jpeg = ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.JPEG, 85, it) }.toByteArray()
        return ClipContent.Image(jpeg, "image/jpeg")
    }
}

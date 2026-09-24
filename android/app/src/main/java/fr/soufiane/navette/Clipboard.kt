package fr.soufiane.navette

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.core.content.FileProvider
import java.io.File

/** Écriture dans le presse-papier du téléphone. Les images passent par un fichier partagé
 *  (FileProvider) : le presse-papier Android ne transporte que des URI, pas des octets. */
object Clipboard {
    private const val KEEP_IMAGES = 5

    fun write(context: Context, content: ClipContent) {
        val clipboard = context.getSystemService(ClipboardManager::class.java)
        val clip = when (content) {
            is ClipContent.Text -> ClipData.newPlainText("Navette", content.text)
            is ClipContent.Image -> {
                val dir = File(context.cacheDir, "recus").apply { mkdirs() }
                val ext = if (content.mime == "image/jpeg") "jpg" else "png"
                val file = File(dir, "navette-${System.currentTimeMillis()}.$ext")
                file.writeBytes(content.bytes)
                // On garde les dernières images : une app peut coller une image un peu plus tard.
                dir.listFiles()?.sortedByDescending { it.lastModified() }?.drop(KEEP_IMAGES)?.forEach { it.delete() }
                val uri = FileProvider.getUriForFile(context, "${context.packageName}.images", file)
                ClipData.newUri(context.contentResolver, "Navette", uri)
            }
        }
        clipboard.setPrimaryClip(clip)
    }
}

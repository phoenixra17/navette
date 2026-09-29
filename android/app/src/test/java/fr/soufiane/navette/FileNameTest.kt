package fr.soufiane.navette

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Mêmes cas que FileTransferTests.testSafeName côté Mac. */
class FileNameTest {
    @Test fun safeName() {
        assertEquals("passwd", FileTransfers.safeName("../../etc/passwd"))
        assertEquals("bashrc", FileTransfers.safeName(".bashrc"))
        assertEquals("ab-c.pdf", FileTransfers.safeName("a\u0000b:c.pdf"))
        assertEquals("fichier", FileTransfers.safeName(""))
        assertEquals("photo.jpg", FileTransfers.safeName("C:\\Users\\x\\photo.jpg"))
        val long = FileTransfers.safeName("é".repeat(300) + ".mp4")
        assertTrue(long.endsWith(".mp4"))
        assertTrue(long.length <= 160)
    }
}

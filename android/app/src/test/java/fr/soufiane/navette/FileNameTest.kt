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

/** Mêmes cas que FileTransferTests.testCoverageMergesOverlaps côté Mac. */
class CoverageTest {
    @Test fun mergesOverlaps() {
        val coverage = FileTransfers.Coverage()
        assertEquals(512L, coverage.add(0, 512))
        assertEquals(0L, coverage.add(32, 64))
        assertEquals(32L, coverage.add(1000, 1032))
        assertEquals(488L, coverage.add(500, 1010))
        assertEquals(1032L, coverage.total)
        assertEquals(listOf(listOf(1032L, 1100L)), coverage.missing(1100))
        assertEquals(0L, coverage.add(0, 1032))
        assertEquals(68L, coverage.add(1032, 1100))
        assertEquals(emptyList<List<Long>>(), coverage.missing(1100))
    }
}

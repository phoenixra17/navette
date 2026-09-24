package fr.soufiane.navette

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/** Vecteurs produits par l'implémentation de référence (server/tests/protocol.js). */
class NavetteCryptoTest {
    private val secret = "q3l2m9d1Xv0kPZ3n4wYtR8sE5uA7bC6fGhJiKlMnOpQ"

    @Test
    fun tokenMatchesReference() {
        assertEquals("Jv5bGo1CghHCCO7ugYKeymbfe7oZz08o42kCTc3GPWY", NavetteCrypto.deriveKeys(secret).token)
    }

    @Test
    fun opensReferenceClip() {
        val clip = NavetteCrypto.Clip(
            "vecteur-1",
            "G3DGSVHNStIj6sw0",
            "tkYokwJQ6Ss286YQJcJoDQSQ+T7ZvfF949kD7b/UJDrWJbKbD9baLUvZK/yME58xFs/r7zZ1Pd1hbG6Pyib13Y8P5NlT4jL2/CpIeIhG",
        )
        assertEquals("Héllo 👋 Navette", NavetteCrypto.openText(NavetteCrypto.deriveKeys(secret).encKey, clip))
    }

    @Test
    fun roundTripAndTamper() {
        val key = NavetteCrypto.deriveKeys(secret).encKey
        val clip = NavetteCrypto.sealText(key, "aller-retour / \"guillemets\"")
        assertEquals("aller-retour / \"guillemets\"", NavetteCrypto.openText(key, clip))
        assertThrows(Exception::class.java) { NavetteCrypto.openText(key, clip.copy(id = "autre")) }
    }

    @Test
    fun opensReferenceImageClip() {
        val clip = NavetteCrypto.Clip(
            "vecteur-image",
            "5G7uvcIcISK58T6A",
            "RPpFgEB6GIIItnnzU+papdb5A7OJphlsiLtTu2nmi1FSc10zfxOBluOvonWQvhnqed5CrgN2USz86eR4QI2CBBe4iY4AzXBmEFkGtRXAdq710y031RvYqgPUuLRV2wsAQ+ZBbwPLgC2E2wSzB6ExLO4CyVUXgvSZRnnrRFBFSwOZsQ6rDgOgza3d4Pe6n+ZZXz5Q8znvTQG0YLtYX6yiEvPY/pbb3aFZ3gAUyN2+0w==",
        )
        val content = ClipContent.fromPayload(NavetteCrypto.open(NavetteCrypto.deriveKeys(secret).encKey, clip))
        assertTrue(content is ClipContent.Image)
        content as ClipContent.Image
        assertEquals("image/png", content.mime)
        // Signature PNG
        assertEquals(0x89.toByte(), content.bytes[0])
        assertEquals('P'.code.toByte(), content.bytes[1])
    }

    @Test
    fun imageRoundTrip() {
        val key = NavetteCrypto.deriveKeys(secret).encKey
        val image = ClipContent.Image(ByteArray(300_000) { (it % 251).toByte() }, "image/jpeg")
        val back = ClipContent.fromPayload(NavetteCrypto.open(key, NavetteCrypto.seal(key, image.toPayload())))
        assertEquals(image, back)
    }
}

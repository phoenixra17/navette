package fr.soufiane.navette

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/** Vecteurs produits par l'implémentation de référence (server/tests/protocol.js). */
class NavetteCryptoTest {
    private val secret = "q3l2m9d1Xv0kPZ3n4wYtR8sE5uA7bC6fGhJiKlMnOpQ"

    @Test
    fun tokenMatchesReference() {
        assertEquals("Jv5bGo1CghHCCO7ugYKeymbfe7oZz08o42kCTc3GPWY", NavetteCrypto.deriveKeys(secret).token)
        assertEquals("887 085", NavetteCrypto.deriveKeys(secret).fingerprint)
    }

    @Test
    fun opensReferenceClip() {
        val clip = NavetteCrypto.Clip(
            "vecteur-1",
            "WYec3cCDeuT2QEv+",
            "WWWKLCs6C7yifCeuctCL41nkxLSQvDBYeOZhdBnPrWwBx98p4NxmyX78NkrngiM550nlv9CGxgSD9DxlNzEhIjUV9FCqGgMNWvMCA7BO",
        )
        assertEquals("Héllo 👋 Navette", NavetteCrypto.openText(NavetteCrypto.deriveKeys(secret).encKey, clip))
    }

    @Test
    fun roundTripAndTamper() {
        val key = NavetteCrypto.deriveKeys(secret).encKey
        val clip = NavetteCrypto.sealText(key, "aller-retour / \"guillemets\"")
        assertEquals("aller-retour / \"guillemets\"", NavetteCrypto.openText(key, clip, NavetteCrypto.PHONE))
        assertThrows(Exception::class.java) { NavetteCrypto.openText(key, clip.copy(id = "autre"), NavetteCrypto.PHONE) }
    }

    @Test
    fun opensReferenceImageClip() {
        val clip = NavetteCrypto.Clip(
            "vecteur-image",
            "pIwk3VD5IaJBJLXd",
            "bWIZlo1bY35CFlZqyB3qooc5GTR+b84KCCleiAart2Qjg9wPwbXM7YHblO8/fZ7YZzmBzbvB/Uva9m52b9wCU8Nxbepe6UnIQDYebPxxEPyrPoJNrFGKIFRO6ZuGMqMZ5Ure7LTDVI4wZOeoDsjoST94xytwmuQpYvGivZmgprk/9MW7lE/7nNGd/bcvCKaIkhIuSM9tbak4+Un95MT3M7+n/Etc0GYVFfNvsi9Vsg==",
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
        val back = ClipContent.fromPayload(NavetteCrypto.open(key, NavetteCrypto.seal(key, image.toPayload()), NavetteCrypto.PHONE))
        assertEquals(image, back)
    }

    /** v2 : un élément du téléphone renvoyé au téléphone (par le serveur, par exemple) ne se déchiffre pas. */
    @Test
    fun reflectedClipIsRejected() {
        val key = NavetteCrypto.deriveKeys(secret).encKey
        val mine = NavetteCrypto.sealText(key, "renvoyé")
        assertThrows(Exception::class.java) { NavetteCrypto.openText(key, mine) }
        val fromPhone = NavetteCrypto.Clip("vecteur-1", "giZdjdbUFijiLaTs", "hOnL6bx+Xs/mP7P9vfMTHfmPVoSrMLOyEH0TVDqwwu2trPtOdIpUWv6dhwExdsNQ/tkjXzBHVx7uloS3npgE88PF0+b4t5G3KxVpRtLy")
        assertThrows(Exception::class.java) { NavetteCrypto.openText(key, fromPhone) }
        assertEquals("Héllo 👋 Navette", NavetteCrypto.openText(key, fromPhone, NavetteCrypto.PHONE))
    }

    @Test
    fun replayGuard() {
        val guard = ReplayGuard()
        val now = System.currentTimeMillis()
        assertTrue(guard.accept("a", now, now))
        assertFalse("rejeu", guard.accept("a", now, now))
        assertFalse("périmé", guard.accept("b", now - ReplayGuard.MAX_AGE_MS - 1, now))
        assertFalse("sans horodatage", guard.accept("c", -1L, now))
        assertTrue("décalage d’horloge d’une minute", guard.accept("d", now - 60_000, now))
    }
}

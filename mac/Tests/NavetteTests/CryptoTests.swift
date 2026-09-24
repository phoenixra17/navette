import XCTest
import AppKit
@testable import NavetteCore

/// Vecteurs produits par l'implémentation de référence (server/tests/protocol.js).
final class CryptoTests: XCTestCase {
    let secret = "q3l2m9d1Xv0kPZ3n4wYtR8sE5uA7bC6fGhJiKlMnOpQ"

    func testTokenMatchesReference() throws {
        let keys = try NavetteCrypto.deriveKeys(secret: secret)
        XCTAssertEqual(keys.token, "Jv5bGo1CghHCCO7ugYKeymbfe7oZz08o42kCTc3GPWY")
        XCTAssertEqual(keys.fingerprint, "887 085")
    }

    func testOpensReferenceClip() throws {
        let keys = try NavetteCrypto.deriveKeys(secret: secret)
        let clip = NavetteCrypto.Clip(
            id: "vecteur-1",
            iv: "giZdjdbUFijiLaTs",
            data: "hOnL6bx+Xs/mP7P9vfMTHfmPVoSrMLOyEH0TVDqwwu2trPtOdIpUWv6dhwExdsNQ/tkjXzBHVx7uloS3npgE88PF0+b4t5G3KxVpRtLy")
        XCTAssertEqual(try NavetteCrypto.open(clip, key: keys.encKey).text, "Héllo 👋 Navette")
    }

    func testRoundTripAndTamper() throws {
        let keys = try NavetteCrypto.deriveKeys(secret: secret)
        let clip = try NavetteCrypto.seal(.text("aller-retour"), key: keys.encKey, as: .phone)
        XCTAssertEqual(try NavetteCrypto.open(clip, key: keys.encKey, from: .phone).text, "aller-retour")
        let tampered = NavetteCrypto.Clip(id: "autre", iv: clip.iv, data: clip.data)
        XCTAssertThrowsError(try NavetteCrypto.open(tampered, key: keys.encKey, from: .phone))
    }

    /// v2 : un message du Mac renvoyé au Mac (par le serveur, par exemple) ne se déchiffre pas.
    func testReflectedClipIsRejected() throws {
        let keys = try NavetteCrypto.deriveKeys(secret: secret)
        let mine = try NavetteCrypto.seal(json: ["kind": "url", "url": "https://example.invalid"], key: keys.encKey)
        XCTAssertThrowsError(try NavetteCrypto.openJSON(mine, key: keys.encKey))
        let refMac = NavetteCrypto.Clip(id: "vecteur-1", iv: "WYec3cCDeuT2QEv+",
            data: "WWWKLCs6C7yifCeuctCL41nkxLSQvDBYeOZhdBnPrWwBx98p4NxmyX78NkrngiM550nlv9CGxgSD9DxlNzEhIjUV9FCqGgMNWvMCA7BO")
        XCTAssertThrowsError(try NavetteCrypto.open(refMac, key: keys.encKey))
        XCTAssertEqual(try NavetteCrypto.open(refMac, key: keys.encKey, from: .mac).text, "Héllo 👋 Navette")
    }

    func testReplayGuard() {
        let guardian = ReplayGuard()
        let now = Date().timeIntervalSince1970 * 1000
        XCTAssertTrue(guardian.accept(id: "a", t: now, now: now))
        XCTAssertFalse(guardian.accept(id: "a", t: now, now: now), "rejeu")
        XCTAssertFalse(guardian.accept(id: "b", t: now - ReplayGuard.maxAgeMs - 1, now: now), "périmé")
        XCTAssertFalse(guardian.accept(id: "c", t: nil, now: now), "sans horodatage")
        XCTAssertTrue(guardian.accept(id: "d", t: now - 60_000, now: now), "décalage d’horloge d’une minute")
    }

    func testOpensReferenceImageClip() throws {
        let keys = try NavetteCrypto.deriveKeys(secret: secret)
        let clip = NavetteCrypto.Clip(
            id: "vecteur-image",
            iv: "5SQhR3YcBGcFxQJ2",
            data: "Ou0pUGb60z5rVX1mF89qwurHXFtIeo1R5SrjLRZwb4zftjt/Dq2CLPQaTO7nE1SDzPxsl0ajk0Wd6+eP6ac0hDLEPuW3g5O41W7e2EeVhO7GxpP2V97oLjryFnstLlwUy5Gai0tuXB2qt8Ga5ou4trh1rn98o2k5fHs+AJrzY3S11mHMUatbgkGdXuJaP0SsJmNzscQrKYDFx9wdt+FKiibMDSqLDVnrsSauXU+PZA==")
        guard case .image(let data, let mime)? = try NavetteCrypto.open(clip, key: keys.encKey).content else {
            return XCTFail("pas une image")
        }
        XCTAssertEqual(mime, "image/png")
        XCTAssertEqual(NSBitmapImageRep(data: data)?.pixelsWide, 1)
    }

    func testImageCodecConvertsAndShrinks() throws {
        // TIFF → PNG
        let small = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 10, pixelsHigh: 10, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        guard case .image(_, let mime)? = ImageCodec.prepare(small.tiffRepresentation!, mime: "image/tiff") else {
            return XCTFail("conversion TIFF")
        }
        XCTAssertEqual(mime, "image/png")

        // Grande image bruitée (PNG > 3 Mo) → JPEG réduit à 2560 px
        let big = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4000, pixelsHigh: 3000, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        arc4random_buf(big.bitmapData!, big.bytesPerRow * big.pixelsHigh)
        let png = big.representation(using: .png, properties: [:])!
        XCTAssertGreaterThan(png.count, ImageCodec.maxBytes)
        guard case .image(let out, let outMime)? = ImageCodec.prepare(png, mime: "image/png") else {
            return XCTFail("compression")
        }
        XCTAssertEqual(outMime, "image/jpeg")
        XCTAssertEqual(NSBitmapImageRep(data: out)?.pixelsWide, 2560)
    }
}

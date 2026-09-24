import XCTest
import AppKit
@testable import NavetteCore

/// Vecteurs produits par l'implémentation de référence (server/tests/protocol.js).
final class CryptoTests: XCTestCase {
    let secret = "q3l2m9d1Xv0kPZ3n4wYtR8sE5uA7bC6fGhJiKlMnOpQ"

    func testTokenMatchesReference() throws {
        let keys = try NavetteCrypto.deriveKeys(secret: secret)
        XCTAssertEqual(keys.token, "Jv5bGo1CghHCCO7ugYKeymbfe7oZz08o42kCTc3GPWY")
    }

    func testOpensReferenceClip() throws {
        let keys = try NavetteCrypto.deriveKeys(secret: secret)
        let clip = NavetteCrypto.Clip(
            id: "vecteur-1",
            iv: "G3DGSVHNStIj6sw0",
            data: "tkYokwJQ6Ss286YQJcJoDQSQ+T7ZvfF949kD7b/UJDrWJbKbD9baLUvZK/yME58xFs/r7zZ1Pd1hbG6Pyib13Y8P5NlT4jL2/CpIeIhG")
        XCTAssertEqual(try NavetteCrypto.open(clip, key: keys.encKey).text, "Héllo 👋 Navette")
    }

    func testRoundTripAndTamper() throws {
        let keys = try NavetteCrypto.deriveKeys(secret: secret)
        let clip = try NavetteCrypto.seal(.text("aller-retour"), key: keys.encKey)
        XCTAssertEqual(try NavetteCrypto.open(clip, key: keys.encKey).text, "aller-retour")
        let tampered = NavetteCrypto.Clip(id: "autre", iv: clip.iv, data: clip.data)
        XCTAssertThrowsError(try NavetteCrypto.open(tampered, key: keys.encKey))
    }

    func testOpensReferenceImageClip() throws {
        let keys = try NavetteCrypto.deriveKeys(secret: secret)
        let clip = NavetteCrypto.Clip(
            id: "vecteur-image",
            iv: "5G7uvcIcISK58T6A",
            data: "RPpFgEB6GIIItnnzU+papdb5A7OJphlsiLtTu2nmi1FSc10zfxOBluOvonWQvhnqed5CrgN2USz86eR4QI2CBBe4iY4AzXBmEFkGtRXAdq710y031RvYqgPUuLRV2wsAQ+ZBbwPLgC2E2wSzB6ExLO4CyVUXgvSZRnnrRFBFSwOZsQ6rDgOgza3d4Pe6n+ZZXz5Q8znvTQG0YLtYX6yiEvPY/pbb3aFZ3gAUyN2+0w==")
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

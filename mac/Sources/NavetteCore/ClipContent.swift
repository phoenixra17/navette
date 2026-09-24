import AppKit

/// Ce qui passe d'un appareil à l'autre.
public enum ClipContent: Equatable {
    case text(String)
    case image(Data, mime: String)

    /// Aperçu d'une ligne pour le menu.
    public var preview: String {
        switch self {
        case .text(let text):
            let oneLine = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            return oneLine.count > 40 ? "« \(oneLine.prefix(40))… »" : "« \(oneLine) »"
        case .image(let data, _):
            guard let rep = NSBitmapImageRep(data: data) else { return "image" }
            return "image \(rep.pixelsWide)×\(rep.pixelsHigh) (\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)))"
        }
    }

    public var byteCount: Int {
        switch self {
        case .text(let text): return text.utf8.count
        case .image(let data, _): return data.count
        }
    }
}

/// Préparation des images à l'envoi : PNG ou JPEG uniquement, et taille raisonnable.
public enum ImageCodec {
    /// Au-delà, on réduit (côté le plus long) et on passe en JPEG.
    public static let maxBytes = 3 * 1024 * 1024
    public static let maxSide = 2560

    public static func prepare(_ data: Data, mime: String) -> ClipContent? {
        if (mime == "image/png" || mime == "image/jpeg") && data.count <= maxBytes {
            return .image(data, mime: mime)
        }
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        if data.count <= maxBytes, let png = rep.representation(using: .png, properties: [:]), png.count <= maxBytes {
            return .image(png, mime: "image/png") // TIFF, HEIC… convertis tels quels
        }
        let scaled = downscale(rep)
        guard let jpeg = scaled.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return nil }
        return .image(jpeg, mime: "image/jpeg")
    }

    private static func downscale(_ rep: NSBitmapImageRep) -> NSBitmapImageRep {
        let longest = max(rep.pixelsWide, rep.pixelsHigh)
        guard longest > maxSide else { return rep }
        let ratio = CGFloat(maxSide) / CGFloat(longest)
        let width = Int(CGFloat(rep.pixelsWide) * ratio), height = Int(CGFloat(rep.pixelsHigh) * ratio)
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return rep }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        NSGraphicsContext.current?.imageInterpolation = .high
        rep.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return out
    }
}

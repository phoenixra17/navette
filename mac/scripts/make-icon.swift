// Génère Resources/Navette.icns : flèches blanches (même symbole que l'app Android) sur fond bleu.
// Usage : swift scripts/make-icon.swift
import AppKit

func render(_ size: CGFloat) -> Data {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        // Marge et coins de la grille d'icônes macOS (824/1024 de côté, rayon ≈ 22 %).
        let inset = size * 100 / 1024
        let card = rect.insetBy(dx: inset, dy: inset)
        let path = NSBezierPath(roundedRect: card, xRadius: card.width * 0.225, yRadius: card.width * 0.225)
        NSGradient(starting: NSColor(red: 0.20, green: 0.47, blue: 0.80, alpha: 1),
                   ending: NSColor(red: 0.08, green: 0.26, blue: 0.52, alpha: 1))!.draw(in: path, angle: -90)
        let config = NSImage.SymbolConfiguration(pointSize: card.width * 0.48, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        if let symbol = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            let s = symbol.size
            symbol.draw(in: NSRect(x: card.midX - s.width / 2, y: card.midY - s.height / 2, width: s.width, height: s.height))
        }
        return true
    }
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: "build/Navette.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(CGFloat(base)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(CGFloat(base * 2)).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
print("iconset prêt")

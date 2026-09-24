import AppKit

/// Ligne « téléphone » du menu, calquée sur l'iPhone dans le menu Wi-Fi de macOS :
/// icône de point d'accès, nom, puis « 5G ▂▄▆ 76 % 🔋 » en petit.
enum PhoneMenuItem {
    static func make(name: String, battery: PhoneBridge.Battery?, target: AnyObject, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: name, action: action, keyEquivalent: "")
        item.target = target
        item.image = NSImage(systemSymbolName: "personalhotspot", accessibilityDescription: "Point d’accès")
        item.toolTip = "Activer le point d’accès du téléphone"

        let title = NSMutableAttributedString(string: name, attributes: [.font: NSFont.menuFont(ofSize: 0)])
        title.append(NSAttributedString(string: "\n"))
        title.append(details(battery))
        item.attributedTitle = title
        return item
    }

    private static let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    private static let secondary: [NSAttributedString.Key: Any] = [.font: small, .foregroundColor: NSColor.secondaryLabelColor]

    private static func details(_ battery: PhoneBridge.Battery?) -> NSAttributedString {
        guard let battery else {
            return NSAttributedString(string: "Cliquer pour activer le point d’accès", attributes: secondary)
        }
        let line = NSMutableAttributedString()
        if !battery.network.isEmpty {
            line.append(NSAttributedString(string: battery.network + " ", attributes: secondary))
        }
        line.append(symbol("cellularbars", value: Double(battery.signal) / 4))
        line.append(NSAttributedString(string: "   \(battery.level) % ", attributes: secondary))
        line.append(symbol(batterySymbol(battery)))
        let age = Date().timeIntervalSince(battery.date)
        if age > 15 * 60 {
            line.append(NSAttributedString(string: "  · il y a \(Int(age / 60)) min", attributes: secondary))
        }
        return line
    }

    private static func batterySymbol(_ battery: PhoneBridge.Battery) -> String {
        if battery.charging { return "battery.100percent.bolt" }
        switch battery.level {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    /// Symbole système intégré au texte, à la taille et dans la couleur du texte secondaire.
    private static func symbol(_ name: String, value: Double? = nil) -> NSAttributedString {
        let config = NSImage.SymbolConfiguration(pointSize: small.pointSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.secondaryLabelColor]))
        let base = value.map { NSImage(systemSymbolName: name, variableValue: $0, accessibilityDescription: nil) }
            ?? NSImage(systemSymbolName: name, accessibilityDescription: nil)
        guard let image = base?.withSymbolConfiguration(config) else { return NSAttributedString() }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: -1.5, width: image.size.width, height: image.size.height)
        return NSAttributedString(attachment: attachment)
    }
}

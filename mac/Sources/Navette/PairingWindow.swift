import AppKit
import CoreImage.CIFilterBuiltins
import NavetteCore

/// Fenêtre d'appairage : le QR (adresse + secret) à scanner avec l'app Android,
/// et le jeton à donner au serveur.
final class PairingWindow: NSWindowController {
    private let onCopyToken: () -> Void

    init(config: Config, token: String, onCopyToken: @escaping () -> Void) {
        self.onCopyToken = onCopyToken
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Appairer Navette"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let title = NSTextField(labelWithString: "Scannez ce code avec Navette sur le téléphone")
        title.font = .boldSystemFont(ofSize: 14)
        title.alignment = .center

        let qr = NSImageView(image: Self.qrImage(config.pairingURI, size: 300))
        qr.imageScaling = .scaleNone

        let warning = NSTextField(wrappingLabelWithString:
            "Ce code contient la clé de chiffrement : ne le montrez à personne d’autre.")
        warning.textColor = .secondaryLabelColor
        warning.alignment = .center

        let serverHelp = NSTextField(wrappingLabelWithString:
            "Serveur : \(config.server)\nLe serveur a besoin du jeton ci-dessous dans sa variable NAVETTE_TOKEN.")
        serverHelp.alignment = .center

        let copy = NSButton(title: "Copier le jeton du serveur", target: self, action: #selector(copyToken))
        copy.bezelStyle = .rounded

        let stack = NSStackView(views: [title, qr, warning, serverHelp, copy])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for label in [warning, serverHelp] {
            label.widthAnchor.constraint(equalToConstant: 360).isActive = true
        }

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        window.contentView = content
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("non utilisé") }

    @objc private func copyToken(_ sender: NSButton) {
        onCopyToken()
        sender.title = "Jeton copié ✓"
    }

    private static func qrImage(_ string: String, size: CGFloat) -> NSImage {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return NSImage() }
        let scale = floor(size / output.extent.width)
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

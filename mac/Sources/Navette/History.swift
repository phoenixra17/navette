import AppKit
import NavetteCore

/// Derniers éléments échangés, en mémoire seulement : rien n'est écrit sur le disque.
final class History {
    enum Direction { case sent, received }

    struct Entry {
        let content: ClipContent
        let direction: Direction
        let date: Date
        let thumbnail: NSImage?
    }

    private(set) var entries: [Entry] = []
    private let limit = 10

    func add(_ content: ClipContent, direction: Direction) {
        // Un même contenu qui repasse remonte en tête au lieu d'apparaître deux fois.
        entries.removeAll { $0.content == content }
        entries.insert(Entry(content: content, direction: direction, date: Date(), thumbnail: Self.thumbnail(content)), at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
    }

    func clear() {
        entries.removeAll()
    }

    private static func thumbnail(_ content: ClipContent) -> NSImage? {
        guard case .image(let data, _) = content, let image = NSImage(data: data) else { return nil }
        let side: CGFloat = 32
        let ratio = min(side / max(image.size.width, 1), side / max(image.size.height, 1))
        let size = NSSize(width: image.size.width * ratio, height: image.size.height * ratio)
        return NSImage(size: size, flipped: false) { rect in
            image.draw(in: rect)
            return true
        }
    }
}

import Foundation

/// Format commun aux liaisons directes (Wi-Fi et Bluetooth) : trames de 4 octets de longueur
/// (gros-boutiste) suivis de JSON en UTF-8. Voir PROTOCOL.md.
enum LinkWire {
    /// Taille maximale d'une trame (image de 16 Mo en base64 comprise), et avant authentification.
    static let maxFrame = 24 * 1024 * 1024
    static let maxHandshakeFrame = 4096

    static func encode(_ message: [String: Any]) -> Data? {
        guard let json = try? JSONSerialization.data(withJSONObject: message) else { return nil }
        var frame = Data(count: 4)
        frame.withUnsafeMutableBytes { $0.storeBytes(of: UInt32(json.count).bigEndian, as: UInt32.self) }
        frame.append(json)
        return frame
    }

    static func nonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }

    /// Comparaison en temps constant.
    static func same(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// Reconstitue les trames d'un flux reçu par morceaux (notifications BLE).
    struct Parser {
        private var buffer = Data()
        var limit = LinkWire.maxHandshakeFrame

        enum Failure: Error { case tooLarge, badJSON }

        /// Ajoute des octets et renvoie les messages complets.
        mutating func append(_ bytes: Data) throws -> [[String: Any]] {
            buffer.append(bytes)
            var messages: [[String: Any]] = []
            while buffer.count >= 4 {
                let length = Int(buffer.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
                guard length > 0, length <= limit else { throw Failure.tooLarge }
                guard buffer.count >= 4 + length else { break }
                let body = buffer.subdata(in: buffer.startIndex + 4 ..< buffer.startIndex + 4 + length)
                buffer = Data(buffer.dropFirst(4 + length))
                guard let message = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                    throw Failure.badJSON
                }
                messages.append(message)
            }
            return messages
        }
    }
}

import Foundation

/// Format commun aux liaisons directes (Wi-Fi et Bluetooth) : trames de 4 octets de longueur
/// (gros-boutiste) suivis de JSON en UTF-8. Bit de poids fort de la longueur à 1 : trame binaire
/// (morceau de fichier : 2 octets de longueur, en-tête JSON {id, iv}, puis le chiffré brut).
/// Voir PROTOCOL.md.
enum LinkWire {
    static let binaryFlag: UInt32 = 0x8000_0000

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

    /// Trame binaire d'un morceau de fichier (seulement si l'autre côté l'a annoncé : `bin` dans `hello`).
    static func encode(_ chunk: NavetteCrypto.Chunk) -> Data? {
        guard let header = try? JSONSerialization.data(withJSONObject: ["id": chunk.id, "iv": chunk.iv.base64EncodedString()]),
              header.count <= 0xFFFF else { return nil }
        let length = UInt32(2 + header.count + chunk.box.count)
        var frame = Data(capacity: 4 + Int(length))
        withUnsafeBytes(of: (length | binaryFlag).bigEndian) { frame.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(header.count).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(header)
        frame.append(chunk.box)
        return frame
    }

    /// En-tête de trame : longueur du corps et trame binaire ou non.
    static func header(_ bytes: Data) -> (length: Int, binary: Bool) {
        let raw = bytes.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return (Int(raw & ~binaryFlag), raw & binaryFlag != 0)
    }

    /// Corps de trame → message. Trame binaire : `["type": "chunk", "chunk": NavetteCrypto.Chunk]`.
    static func message(_ body: Data, binary: Bool) -> [String: Any]? {
        guard binary else { return try? JSONSerialization.jsonObject(with: body) as? [String: Any] }
        guard body.count >= 2 else { return nil }
        let start = body.startIndex
        let headerLength = Int(body[start]) << 8 | Int(body[start + 1])
        guard 2 + headerLength <= body.count,
              let header = try? JSONSerialization.jsonObject(with: body.subdata(in: start + 2 ..< start + 2 + headerLength)) as? [String: Any],
              let id = header["id"] as? String, let iv = (header["iv"] as? String).flatMap({ Data(base64Encoded: $0) })
        else { return nil }
        return ["type": "chunk", "chunk": NavetteCrypto.Chunk(id: id, iv: iv, box: body.subdata(in: start + 2 + headerLength ..< body.endIndex))]
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
                let (length, binary) = LinkWire.header(buffer)
                guard length > 0, length <= limit else { throw Failure.tooLarge }
                guard buffer.count >= 4 + length else { break }
                let body = buffer.subdata(in: buffer.startIndex + 4 ..< buffer.startIndex + 4 + length)
                buffer = Data(buffer.dropFirst(4 + length))
                guard let message = LinkWire.message(body, binary: binary) else { throw Failure.badJSON }
                messages.append(message)
            }
            return messages
        }
    }
}

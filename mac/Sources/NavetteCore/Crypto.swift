import CryptoKit
import Foundation

/// Protocole Navette v2 — doit rester identique à l'app Android (vecteurs de test communs).
/// v2 : les données associées lient chaque élément à son expéditeur, et les messages reçus en
/// direct passent par `ReplayGuard` (voir PROTOCOL.md).
public enum NavetteCrypto {
    public struct Keys {
        public let token: String
        public let encKey: SymmetricKey
        /// Code à 6 chiffres, affiché aussi par le téléphone, pour vérifier l'appairage.
        public let fingerprint: String
        /// Liaison directe sur le réseau local : clé de la poignée de main et identifiant annoncé.
        public let localKey: SymmetricKey
        public let localID: String
    }

    /// Expéditeur d'un élément : un élément renvoyé à son propre expéditeur ne se déchiffre pas.
    public enum Role: String { case mac, phone }

    /// Élément chiffré tel qu'il circule entre les appareils.
    public struct Clip: Codable, Equatable {
        public let id: String
        public let iv: String
        public let data: String
    }

    /// Contenu en clair, visible seulement du Mac et du téléphone.
    /// Texte : `text`. Image : `mime` (image/png, image/jpeg) et `data` (octets en base64).
    public struct Payload: Codable, Equatable {
        public let kind: String
        public var text: String? = nil
        public var mime: String? = nil
        public var data: String? = nil
        public var t: Double? = (Date().timeIntervalSince1970 * 1000).rounded()

        public static func text(_ text: String) -> Payload {
            Payload(kind: "text", text: text)
        }

        public init(kind: String, text: String? = nil, mime: String? = nil, data: String? = nil) {
            self.kind = kind
            self.text = text
            self.mime = mime
            self.data = data
        }

        public init(_ content: ClipContent) {
            switch content {
            case .text(let text): self.init(kind: "text", text: text)
            case .image(let bytes, let mime): self.init(kind: "image", mime: mime, data: bytes.base64EncodedString())
            }
        }

        /// nil pour un type inconnu (version plus récente de l'autre app, par exemple).
        public var content: ClipContent? {
            switch kind {
            case "text": return text.map { .text($0) }
            case "image":
                guard let mime, let data, let bytes = Data(base64Encoded: data) else { return nil }
                return .image(bytes, mime: mime)
            default: return nil
            }
        }
    }

    public enum Failure: Error { case badSecret, badClip }

    /// Morceau de fichier au format binaire (voir « Binary chunks » dans PROTOCOL.md) : en clair,
    /// 4 octets de longueur, les métadonnées en JSON, puis les octets bruts. Sur une liaison directe,
    /// il circule tel quel dans une trame binaire.
    public struct Chunk: Equatable {
        public let id: String
        public let iv: Data
        /// Chiffré ‖ tag.
        public let box: Data

        public init(id: String, iv: Data, box: Data) {
            self.id = id
            self.iv = iv
            self.box = box
        }

        /// Un `Clip` qui n'est pas du JSON est peut-être un morceau binaire.
        public init?(clip: Clip) {
            guard let iv = Data(base64Encoded: clip.iv), let box = Data(base64Encoded: clip.data) else { return nil }
            self.init(id: clip.id, iv: iv, box: box)
        }

        public var clip: Clip { Clip(id: id, iv: iv.base64EncodedString(), data: box.base64EncodedString()) }
    }

    private static func aadBinary(_ role: Role, _ id: String) -> Data {
        Data("navette/v2b|\(role.rawValue)|\(id)".utf8)
    }

    public static func sealChunk(meta: [String: Any], bytes: Data, key: SymmetricKey, as role: Role = .mac,
                                 id: String = UUID().uuidString.lowercased()) throws -> Chunk {
        var meta = meta
        meta["t"] = (Date().timeIntervalSince1970 * 1000).rounded()
        let json = try JSONSerialization.data(withJSONObject: meta)
        var plaintext = Data(capacity: 4 + json.count + bytes.count)
        withUnsafeBytes(of: UInt32(json.count).bigEndian) { plaintext.append(contentsOf: $0) }
        plaintext.append(json)
        plaintext.append(bytes)
        let nonce = AES.GCM.Nonce()
        let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aadBinary(role, id))
        return Chunk(id: id, iv: nonce.withUnsafeBytes { Data($0) }, box: box.ciphertext + box.tag)
    }

    public static func openChunk(_ chunk: Chunk, key: SymmetricKey, from role: Role = .phone) throws -> (meta: [String: Any], bytes: Data) {
        guard chunk.box.count > 16 else { throw Failure.badClip }
        let sealed = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: chunk.iv),
                                           ciphertext: chunk.box.dropLast(16), tag: chunk.box.suffix(16))
        let plaintext = try AES.GCM.open(sealed, using: key, authenticating: aadBinary(role, chunk.id))
        guard plaintext.count >= 4 else { throw Failure.badClip }
        let length = Int(plaintext.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        guard 4 + length <= plaintext.count,
              let meta = try JSONSerialization.jsonObject(with: plaintext.subdata(in: plaintext.startIndex + 4 ..< plaintext.startIndex + 4 + length)) as? [String: Any]
        else { throw Failure.badClip }
        return (meta, plaintext.subdata(in: plaintext.startIndex + 4 + length ..< plaintext.endIndex))
    }

    public static func newSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "générateur aléatoire indisponible")
        return Data(bytes).base64URLEncodedString()
    }

    public static func deriveKeys(secret: String) throws -> Keys {
        guard let secretData = Data(base64URL: secret), secretData.count >= 16 else { throw Failure.badSecret }
        let key = SymmetricKey(data: secretData)
        func hmac(_ label: String) -> Data {
            Data(HMAC<SHA256>.authenticationCode(for: Data(label.utf8), using: key))
        }
        let digest = hmac("navette/fingerprint/v1")
        let n = digest.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) } % 1_000_000
        let digits = String(format: "%06u", n)
        return Keys(token: hmac("navette/auth/v1").base64URLEncodedString(),
                    encKey: SymmetricKey(data: hmac("navette/enc/v1")),
                    fingerprint: "\(digits.prefix(3)) \(digits.suffix(3))",
                    localKey: SymmetricKey(data: hmac("navette/local/v1")),
                    localID: hmac("navette/local-id/v1").prefix(6).map { String(format: "%02x", $0) }.joined())
    }

    /// Preuve de la poignée de main de la liaison locale : chacun signe les deux nonces avec son rôle.
    public static func localProof(key: SymmetricKey, role: Role, macNonce: String, phoneNonce: String) -> String {
        let message = Data("navette/local/v1|\(role.rawValue)|\(macNonce)|\(phoneNonce)".utf8)
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: key)).base64EncodedString()
    }

    private static func aad(_ role: Role, _ id: String) -> Data {
        Data("navette/v2|\(role.rawValue)|\(id)".utf8)
    }

    /// Par défaut, le Mac chiffre en tant que `mac`.
    public static func seal(_ payload: Payload, key: SymmetricKey, as role: Role = .mac,
                            id: String = UUID().uuidString.lowercased()) throws -> Clip {
        try sealData(JSONEncoder().encode(payload), key: key, role: role, id: id)
    }

    /// Message quelconque (notification, batterie, commande…) : un dictionnaire JSON.
    public static func seal(json: [String: Any], key: SymmetricKey, as role: Role = .mac) throws -> Clip {
        var json = json
        json["t"] = (Date().timeIntervalSince1970 * 1000).rounded()
        return try sealData(JSONSerialization.data(withJSONObject: json), key: key, role: role,
                            id: UUID().uuidString.lowercased())
    }

    public static func openJSON(_ clip: Clip, key: SymmetricKey, from role: Role = .phone) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: openData(clip, key: key, from: role)) as? [String: Any] else {
            throw Failure.badClip
        }
        return json
    }

    private static func sealData(_ plaintext: Data, key: SymmetricKey, role: Role, id: String) throws -> Clip {
        let nonce = AES.GCM.Nonce()
        let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad(role, id))
        let iv = nonce.withUnsafeBytes { Data($0) }
        return Clip(id: id, iv: iv.base64EncodedString(), data: (box.ciphertext + box.tag).base64EncodedString())
    }

    /// Par défaut, le Mac n'accepte que ce qu'a chiffré le téléphone.
    public static func open(_ clip: Clip, key: SymmetricKey, from role: Role = .phone) throws -> Payload {
        try JSONDecoder().decode(Payload.self, from: openData(clip, key: key, from: role))
    }

    public static func openData(_ clip: Clip, key: SymmetricKey, from role: Role = .phone) throws -> Data {
        guard let iv = Data(base64Encoded: clip.iv),
              let raw = Data(base64Encoded: clip.data), raw.count > 16 else { throw Failure.badClip }
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv),
                                        ciphertext: raw.dropLast(16),
                                        tag: raw.suffix(16))
        return try AES.GCM.open(box, using: key, authenticating: aad(role, clip.id))
    }
}

/// Refuse les messages reçus qui sont périmés ou déjà vus :
/// un intermédiaire ne peut pas les rejouer.
public final class ReplayGuard {
    /// Horloges du Mac et du téléphone comprises.
    public static let maxAgeMs: Double = 5 * 60 * 1000
    private let capacity: Int
    private var seen = Set<String>()
    private var order: [String] = []

    public init(capacity: Int = 4096) { self.capacity = capacity }

    public func accept(id: String, t: Double?, now: Double = (Date().timeIntervalSince1970 * 1000)) -> Bool {
        guard let t, abs(now - t) <= Self.maxAgeMs, !seen.contains(id) else { return false }
        seen.insert(id)
        order.append(id)
        if order.count > capacity { seen.remove(order.removeFirst()) }
        return true
    }
}

public extension Data {
    init?(base64URL string: String) {
        var b64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        self.init(base64Encoded: b64)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

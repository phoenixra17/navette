import CryptoKit
import Foundation

/// Protocole Navette v1 — doit rester identique à `server/tests/protocol.js` et à l'app Android.
public enum NavetteCrypto {
    public struct Keys {
        public let token: String
        public let encKey: SymmetricKey
    }

    /// Élément chiffré tel qu'il circule par le serveur.
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

    public static func newSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    public static func deriveKeys(secret: String) throws -> Keys {
        guard let secretData = Data(base64URL: secret), secretData.count >= 16 else { throw Failure.badSecret }
        let key = SymmetricKey(data: secretData)
        func hmac(_ label: String) -> Data {
            Data(HMAC<SHA256>.authenticationCode(for: Data(label.utf8), using: key))
        }
        return Keys(token: hmac("navette/auth/v1").base64URLEncodedString(),
                    encKey: SymmetricKey(data: hmac("navette/enc/v1")))
    }

    public static func seal(_ payload: Payload, key: SymmetricKey, id: String = UUID().uuidString.lowercased()) throws -> Clip {
        try sealData(JSONEncoder().encode(payload), key: key, id: id)
    }

    /// Message quelconque (notification, batterie, commande…) : un dictionnaire JSON.
    public static func seal(json: [String: Any], key: SymmetricKey) throws -> Clip {
        var json = json
        json["t"] = (Date().timeIntervalSince1970 * 1000).rounded()
        return try sealData(JSONSerialization.data(withJSONObject: json), key: key, id: UUID().uuidString.lowercased())
    }

    public static func openJSON(_ clip: Clip, key: SymmetricKey) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: openData(clip, key: key)) as? [String: Any] else {
            throw Failure.badClip
        }
        return json
    }

    private static func sealData(_ plaintext: Data, key: SymmetricKey, id: String) throws -> Clip {
        let nonce = AES.GCM.Nonce()
        let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: Data(id.utf8))
        let iv = nonce.withUnsafeBytes { Data($0) }
        return Clip(id: id, iv: iv.base64EncodedString(), data: (box.ciphertext + box.tag).base64EncodedString())
    }

    public static func open(_ clip: Clip, key: SymmetricKey) throws -> Payload {
        try JSONDecoder().decode(Payload.self, from: openData(clip, key: key))
    }

    public static func openData(_ clip: Clip, key: SymmetricKey) throws -> Data {
        guard let iv = Data(base64Encoded: clip.iv),
              let raw = Data(base64Encoded: clip.data), raw.count > 16 else { throw Failure.badClip }
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv),
                                        ciphertext: raw.dropLast(16),
                                        tag: raw.suffix(16))
        return try AES.GCM.open(box, using: key, authenticating: Data(clip.id.utf8))
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

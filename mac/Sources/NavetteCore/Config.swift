import Foundation

/// Réglages stockés dans ~/.navette/config.json (droits 600 : le secret y est en clair).
public struct Config: Codable, Equatable {
    public var secret: String
    public var device: String
    public var autoSend: Bool
    /// Optionnel : absent des configurations créées avant son ajout (ne pas casser leur lecture).
    public var notifications: Bool?

    public var showsNotifications: Bool {
        get { notifications ?? true }
        set { notifications = newValue }
    }

    /// Point d'accès : téléphone Bluetooth choisi (adresse) et mode automatique. Optionnels aussi.
    public var hotspotDevice: String?
    public var hotspotAuto: Bool?
    public var hotspotNetwork: String?

    public static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".navette")
    public static let file = directory.appendingPathComponent("config.json")

    public static func loadOrCreate() -> Config {
        if let data = try? Data(contentsOf: file),
           let config = try? JSONDecoder().decode(Config.self, from: data) {
            return config
        }
        let config = Config(
                            secret: NavetteCrypto.newSecret(),
                            device: "mac",
                            autoSend: true)
        config.save()
        return config
    }

    public func save() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.directory, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: Self.file, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.file.path)
    }

    /// Contenu du QR d'appairage lu par l'app Android.
    public var pairingURI: String {
        var comps = URLComponents()
        comps.scheme = "navette"
        comps.host = "pair"
        comps.queryItems = [URLQueryItem(name: "s", value: secret)]
        return comps.string ?? ""
    }
}

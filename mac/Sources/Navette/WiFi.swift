import CoreLocation
import CoreWLAN
import Security

/// Wi-Fi du Mac. Depuis macOS 14, les noms de réseaux (le sien comme ceux d'une recherche) ne sont
/// lisibles qu'avec l'autorisation de localisation : Navette ne s'en sert que pour ça.
enum WiFi {
    private static let manager = CLLocationManager()

    static var canReadNetworkNames: Bool {
        let status = manager.authorizationStatus
        return status == .authorizedAlways || status == .authorized
    }

    static func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    static func currentNetwork() -> String? {
        CWWiFiClient.shared().interface()?.ssid()
    }

    /// Recherche ciblée : ne coupe pas la connexion en cours.
    static func isVisible(_ ssid: String) -> Bool {
        guard let interface = CWWiFiClient.shared().interface(),
              let networks = try? interface.scanForNetworks(withName: ssid) else { return false }
        return networks.contains { $0.ssid == ssid }
    }

    /// Rejoint le réseau avec l'API Wi-Fi d'Apple (le mot de passe n'apparaît dans aucune commande).
    /// Renvoie nil si c'est fait, sinon le message d'erreur.
    static func join(_ ssid: String, password: String) -> String? {
        guard let interface = CWWiFiClient.shared().interface() else { return "pas d’interface Wi-Fi" }
        do {
            guard let network = try interface.scanForNetworks(withName: ssid).first(where: { $0.ssid == ssid }) else {
                return "réseau introuvable"
            }
            try interface.associate(to: network, password: password)
            return nil
        } catch {
            return "\(error.localizedDescription) (\((error as NSError).code))"
        }
    }

    // MARK: Mot de passe du point d'accès, dans le trousseau de session de l'utilisateur

    private static let keychainService = "Navette — point d’accès"

    static func savedPassword(for ssid: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: ssid,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func savePassword(_ password: String, for ssid: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: ssid,
        ]
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = Data(password.utf8)
        item[kSecAttrLabel as String] = "Navette — mot de passe du point d’accès « \(ssid) »"
        SecItemAdd(item as CFDictionary, nil)
    }
}

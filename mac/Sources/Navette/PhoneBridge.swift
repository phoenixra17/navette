import AppKit
import NavetteCore
import UserNotifications

/// Tout ce qui n'est pas du presse-papier : notifications du téléphone (avec réponse rapide),
/// batterie, sonnerie et liens. Les messages passent par le même canal chiffré.
final class PhoneBridge: NSObject, UNUserNotificationCenterDelegate {
    /// État du téléphone : batterie, réseau mobile (« 5G »…) et barres de signal (0 à 4).
    struct Battery {
        let level: Int
        let charging: Bool
        let network: String
        let signal: Int
        let date: Date
    }

    /// Envoie un message au téléphone (fourni par AppDelegate).
    var send: (([String: Any]) -> Void)?
    /// L'état affiché dans le menu a changé.
    var onChange: (() -> Void)?
    /// Les notifications du téléphone sont-elles affichées ? (réglage du menu)
    var showNotifications = true

    private(set) var battery: Battery?
    private(set) var isRinging = false
    private var lowBatteryAlerted = false
    private var ringTimer: Timer?

    private let center = UNUserNotificationCenter.current()
    private static let replyCategory = "notif-reponse"
    private static let plainCategory = "notif"
    private static let replyAction = "repondre"

    func start() {
        center.delegate = self
        let reply = UNTextInputNotificationAction(identifier: Self.replyAction, title: "Répondre",
                                                  options: [], textInputButtonTitle: "Envoyer",
                                                  textInputPlaceholder: "Message")
        // customDismissAction : on est prévenu quand une notification est effacée sur le Mac,
        // pour l'effacer aussi sur le téléphone.
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.replyCategory, actions: [reply], intentIdentifiers: [],
                                   options: [.customDismissAction]),
            UNNotificationCategory(identifier: Self.plainCategory, actions: [], intentIdentifiers: [],
                                   options: [.customDismissAction]),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            Self.log("demande d’autorisation : \(granted ? "accordée" : "refusée") \(error.map { "\($0)" } ?? "")")
        }
        center.getNotificationSettings { settings in
            Self.log("réglages : autorisation=\(settings.authorizationStatus.rawValue) alertes=\(settings.alertSetting.rawValue) style=\(settings.alertStyle.rawValue)")
        }
    }

    static func log(_ message: String) { Journal.write(message) }

    /// Message venu du téléphone. Renvoie false si ce n'est pas pour le pont.
    func handle(_ json: [String: Any]) -> Bool {
        switch json["kind"] as? String {
        case "notif": showPhoneNotification(json)
        case "notif-removed":
            if let key = json["key"] as? String { center.removeDeliveredNotifications(withIdentifiers: [Self.id(key)]) }
        case "battery": updateBattery(json)
        case "reply-result":
            if json["ok"] as? Bool == false {
                post(title: "Réponse non envoyée", body: "La notification n’existe plus sur le téléphone.")
            }
        case "url": openURL(json["url"] as? String)
        default: return false
        }
        return true
    }

    // MARK: Commandes vers le téléphone

    /// À la connexion : le téléphone renvoie son état (batterie).
    func sync() {
        send?(["kind": "sync"])
    }

    func ring() {
        send?(["kind": "ring"])
        isRinging = true
        ringTimer?.invalidate()
        ringTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
            self?.isRinging = false // le téléphone s'arrête seul au bout d'une minute
        }
    }

    func stopRinging() {
        send?(["kind": "ring-stop"])
        isRinging = false
        ringTimer?.invalidate()
    }

    func openOnPhone(_ url: URL) {
        send?(["kind": "url", "url": url.absoluteString])
    }

    // MARK: Notifications

    private static func id(_ key: String) -> String { "tel:" + key }

    private func showPhoneNotification(_ json: [String: Any]) {
        guard showNotifications, let key = json["key"] as? String else { return }
        let content = UNMutableNotificationContent()
        let app = json["app"] as? String ?? "Téléphone"
        let title = json["title"] as? String ?? ""
        content.title = title.isEmpty ? app : title
        content.subtitle = title.isEmpty ? "" : app
        content.body = json["text"] as? String ?? ""
        content.threadIdentifier = json["pkg"] as? String ?? app // regroupées par app
        content.categoryIdentifier = (json["canReply"] as? Bool == true) ? Self.replyCategory : Self.plainCategory
        content.userInfo = ["key": key]
        content.sound = .default
        if let attachment = appIcon(json) { content.attachments = [attachment] }
        // Même identifiant : une mise à jour (nouveau message dans la conversation) remplace l'ancienne.
        center.add(UNNotificationRequest(identifier: Self.id(key), content: content, trigger: nil)) { error in
            if let error { Self.log("notification refusée par macOS : \(error)") }
        }
    }

    /// Icône de l'app du téléphone (WhatsApp…), affichée en vignette à droite de la notification.
    /// macOS déplace le fichier joint dans son propre stockage : on en écrit donc une copie à chaque fois.
    private func appIcon(_ json: [String: Any]) -> UNNotificationAttachment? {
        guard let base64 = json["icon"] as? String, let data = Data(base64Encoded: base64) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("navette-icone-\(UUID().uuidString).png")
        guard (try? data.write(to: url)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: "icone", url: url, options: nil)
    }

    private func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        defer { completionHandler() }
        guard let key = response.notification.request.content.userInfo["key"] as? String else { return }
        DispatchQueue.main.async { [weak self] in
            switch response.actionIdentifier {
            case Self.replyAction:
                let text = (response as? UNTextInputNotificationResponse)?.userText ?? ""
                if !text.isEmpty { self?.send?(["kind": "reply", "key": key, "text": text]) }
            case UNNotificationDismissActionIdentifier:
                self?.send?(["kind": "notif-dismiss", "key": key])
            default:
                break // clic sur la notification : rien de plus
            }
        }
    }

    // MARK: Batterie

    private func updateBattery(_ json: [String: Any]) {
        guard let level = json["level"] as? Int else { return }
        let charging = json["charging"] as? Bool ?? false
        battery = Battery(level: level, charging: charging, network: json["net"] as? String ?? "",
                          signal: json["signal"] as? Int ?? 0, date: Date())
        if charging || level > 20 {
            lowBatteryAlerted = false
        } else if level <= 15 && !lowBatteryAlerted {
            lowBatteryAlerted = true
            post(title: "Batterie du téléphone faible", body: "Il reste \(level) %.")
        }
        onChange?()
    }

    // MARK: Liens

    private func openURL(_ string: String?) {
        // Seulement du web : jamais un fichier local ou un schéma d'app venu du réseau.
        guard let string, let url = URL(string: string), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }
}

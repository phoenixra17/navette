import AppKit
import NavetteCore
import QuickLookThumbnailing
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
    /// Le téléphone est-il connecté au relais ? (indiqué avec la batterie)
    private(set) var phoneOnRelay = false
    /// Le Mac l'est-il ? (transmis au téléphone avec `sync`)
    var macOnRelay = false
    private(set) var isRinging = false
    private var lowBatteryAlerted = false
    private var ringTimer: Timer?

    private let center = UNUserNotificationCenter.current()
    private static let replyCategory = "notif-reponse"
    private static let plainCategory = "notif"
    private static let replyAction = "repondre"
    private static let fileCategory = "fichier-recu"
    private static let openAction = "ouvrir"

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
            UNNotificationCategory(identifier: Self.fileCategory,
                                   actions: [UNNotificationAction(identifier: Self.openAction, title: "Ouvrir",
                                                                  options: [.foreground])],
                                   intentIdentifiers: [], options: []),
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
        send?(["kind": "sync", "relay": macOnRelay])
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

    /// Fichier reçu ou envoyé ; un clic montre `reveal` dans le Finder.
    func notifyFile(title: String, body: String, reveal: URL?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let reveal { content.userInfo = ["reveal": reveal.path] }
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Fichier reçu, à la façon d'AirDrop : nom du téléphone, vignette du fichier, son d'AirDrop,
    /// clic = afficher dans le Finder, bouton « Ouvrir ».
    func notifyReceived(_ url: URL, from phone: String?) {
        let content = UNMutableNotificationContent()
        content.title = phone ?? "Téléphone"
        content.body = url.lastPathComponent
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        if let size { content.subtitle = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) }
        content.userInfo = ["reveal": url.path]
        content.categoryIdentifier = Self.fileCategory
        content.threadIdentifier = "fichiers-recus"
        content.sound = Self.airDropSound()
        thumbnail(of: url) { [center] attachment in
            if let attachment { content.attachments = [attachment] }
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    /// Le son d'AirDrop n'est pas un son d'alerte public : on le recopie une fois depuis macOS dans
    /// ~/Library/Sounds, où les notifications vont chercher les sons nommés (rien n'est redistribué).
    private static func airDropSound() -> UNNotificationSound {
        let source = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/Sharing.framework/Versions/A/Resources/airdrop_invite.caf")
        let name = "Navette AirDrop.caf"
        let sounds = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sounds")
        let copy = sounds.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: copy.path) {
            try? FileManager.default.createDirectory(at: sounds, withIntermediateDirectories: true)
            guard (try? FileManager.default.copyItem(at: source, to: copy)) != nil else { return .default }
        }
        return UNNotificationSound(named: UNNotificationSoundName(name))
    }

    /// Vignette Quick Look (aperçu d'une photo, première page d'un PDF, sinon icône du type).
    /// macOS déplace le fichier joint : on lui donne une copie PNG.
    private func thumbnail(of url: URL, done: @escaping (UNNotificationAttachment?) -> Void) {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 256, height: 256),
                                                   scale: 2, representationTypes: .all)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { thumbnail, _ in
            guard let image = thumbnail?.cgImage,
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                return done(nil)
            }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("navette-vignette-\(UUID().uuidString).png")
            guard (try? png.write(to: file)) != nil else { return done(nil) }
            done(try? UNNotificationAttachment(identifier: "vignette", url: file, options: nil))
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        defer { completionHandler() }
        let info = response.notification.request.content.userInfo
        if let path = info["reveal"] as? String {
            let url = URL(fileURLWithPath: path)
            switch response.actionIdentifier {
            case Self.openAction: DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            case UNNotificationDefaultActionIdentifier:
                DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            default: break
            }
            return
        }
        guard let key = info["key"] as? String else { return }
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
        let onRelay = json["relay"] as? Bool ?? false
        if onRelay != phoneOnRelay { Self.log("téléphone sur le relais : \(onRelay)") }
        phoneOnRelay = onRelay
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

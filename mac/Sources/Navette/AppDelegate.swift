import AppKit
import NavetteCore
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var config = Config.loadOrCreate()
    private var keys: NavetteCrypto.Keys!
    private let relay = Relay()
    private let watcher = ClipboardWatcher()
    private var statusItem: NSStatusItem!
    private var pairingWindow: PairingWindow?

    private var lastEvent: String?
    private var flashTimer: Timer?
    private let history = History()
    private let bridge = PhoneBridge()
    private let hotspot = Hotspot()
    /// App au premier plan quand le menu s'ouvre (pour « Ouvrir l'onglet sur le téléphone »).
    private var frontBundleID: String?

    /// Au-delà, on n'envoie pas (un copier accidentel d'un énorme journal, par exemple).
    private let maxTextBytes = 1_000_000

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        do {
            keys = try NavetteCrypto.deriveKeys(secret: config.secret)
        } catch {
            config.secret = NavetteCrypto.newSecret()
            config.save()
            keys = try? NavetteCrypto.deriveKeys(secret: config.secret)
        }

        relay.onState = { [weak self] state in
            self?.updateIcon()
            if state == .connected { self?.bridge.sync() } // le téléphone renvoie sa batterie
        }
        bridge.send = { [weak self] json in self?.sendEvent(json) }
        bridge.showNotifications = config.showsNotifications
        bridge.start()
        hotspot.deviceAddress = config.hotspotDevice
        hotspot.automatic = config.hotspotAuto ?? false
        hotspot.networkName = config.hotspotNetwork
        hotspot.askPassword = { [weak self] ssid in self?.askHotspotPassword(ssid) }
        hotspot.onChange = { [weak self] in
            if let status = self?.hotspot.status { self?.lastEvent = status }
        }
        hotspot.start()
        relay.onClip = { [weak self] clip, from in self?.received(clip, from: from) }
        watcher.onContent = { [weak self] content in
            guard let self, self.config.autoSend else { return }
            self.send(content)
        }

        updateIcon()
        relay.start(config: config, token: keys.token)
        watcher.start()

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.relay.reconnectNow() }

        // Premier lancement : le serveur n'a pas encore ce jeton, on guide tout de suite.
        if !UserDefaults.standard.bool(forKey: "setupShown") {
            UserDefaults.standard.set(true, forKey: "setupShown")
            if config.server.isEmpty { editServer() } // le QR d'appairage contient l'adresse
            showPairing()
        }
    }

    // MARK: Échanges

    private func send(_ content: ClipContent) {
        if case .text(let text) = content, text.utf8.count > maxTextBytes {
            lastEvent = "↑ ignoré : texte trop long (\(text.utf8.count / 1024) Ko)"
            return
        }
        guard let clip = try? NavetteCrypto.seal(NavetteCrypto.Payload(content), key: keys.encKey) else { return }
        relay.send(clip) { [weak self] ok in
            guard let self else { return }
            self.lastEvent = ok ? "↑ \(content.preview)" : "↑ échec d’envoi"
            if ok {
                self.history.add(content, direction: .sent)
                self.flash("arrow.up.circle.fill")
            }
        }
    }

    /// Notification, commande… : n'écrase pas le dernier presse-papier gardé par le serveur.
    private func sendEvent(_ json: [String: Any]) {
        guard let clip = try? NavetteCrypto.seal(json: json, key: keys.encKey) else { return }
        relay.send(clip, ephemeral: true)
    }

    private func received(_ clip: NavetteCrypto.Clip, from: String) {
        guard let data = try? NavetteCrypto.openData(clip, key: keys.encKey),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            lastEvent = "↓ élément illisible (secret différent ?)"
            return
        }
        if bridge.handle(json) { return }
        guard let payload = try? JSONDecoder().decode(NavetteCrypto.Payload.self, from: data),
              let content = payload.content else { return }
        watcher.write(content)
        history.add(content, direction: .received)
        lastEvent = "↓ \(content.preview)"
        flash("arrow.down.circle.fill")
    }

    // MARK: Icône

    private func updateIcon() {
        guard flashTimer == nil else { return }
        let symbol: String
        switch relay.state {
        case .connected: symbol = "arrow.left.arrow.right.circle"
        case .connecting: symbol = "arrow.left.arrow.right.circle"
        case .disconnected, .unauthorized: symbol = "exclamationmark.circle"
        }
        setIcon(symbol, dimmed: relay.state != .connected)
    }

    private func setIcon(_ symbol: String, dimmed: Bool = false) {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Navette")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.appearsDisabled = dimmed
    }

    private func flash(_ symbol: String) {
        flashTimer?.invalidate()
        setIcon(symbol)
        flashTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            self?.flashTimer = nil
            self?.updateIcon()
        }
    }

    // MARK: Menu (reconstruit à chaque ouverture)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let host = URL(string: config.server)?.host ?? config.server

        let status: String
        switch relay.state {
        case .connected: status = "● Connecté à \(host)"
        case .connecting: status = "◌ Connexion à \(host)…"
        case .disconnected(let why): status = "○ Hors ligne — \(why)"
        case .unauthorized: status = "⚠︎ Jeton refusé : mettez-le à jour sur le serveur"
        }
        menu.addItem(disabled(status))
        if let lastEvent { menu.addItem(disabled(lastEvent)) }
        menu.addItem(.separator())

        // Comme un iPhone dans le menu Wi-Fi : nom, réseau, signal, batterie ; un clic = point d'accès.
        menu.addItem(.sectionHeader(title: "Point d’accès personnel"))
        menu.addItem(PhoneMenuItem.make(name: hotspot.phoneName ?? "Téléphone", battery: bridge.battery,
                                        target: self, action: #selector(requestHotspot)))
        let hotspotAuto = item("Automatique si le Mac perd internet", #selector(toggleHotspotAuto))
        hotspotAuto.state = hotspot.automatic ? .on : .off
        menu.addItem(hotspotAuto)
        menu.addItem(networkChoiceItem())
        menu.addItem(item("Mot de passe du point d’accès…", #selector(changeHotspotPassword)))
        let phones = Hotspot.pairedPhones()
        if phones.count > 1 {
            let parent = NSMenuItem(title: "Téléphone Bluetooth", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for phone in phones {
                let entry = item(phone.name ?? phone.addressString, #selector(chooseHotspotPhone(_:)))
                entry.representedObject = phone.addressString
                entry.state = phone.name == hotspot.phoneName ? .on : .off
                submenu.addItem(entry)
            }
            parent.submenu = submenu
            menu.addItem(parent)
        }
        menu.addItem(.separator())

        frontBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        menu.addItem(openOnPhoneItem())
        menu.addItem(bridge.isRinging
            ? item("Arrêter la sonnerie du téléphone", #selector(stopRinging))
            : item("Faire sonner le téléphone", #selector(ring)))
        let notifs = item("Notifications du téléphone", #selector(toggleNotifications))
        notifs.state = config.showsNotifications ? .on : .off
        menu.addItem(notifs)
        menu.addItem(.separator())

        menu.addItem(historyItem())
        menu.addItem(item("Envoyer le presse-papier au téléphone", #selector(sendNow)))
        let auto = item("Envoi automatique à chaque copie", #selector(toggleAuto))
        auto.state = config.autoSend ? .on : .off
        menu.addItem(auto)
        menu.addItem(.separator())

        menu.addItem(item("Appairer le téléphone…", #selector(showPairing)))
        menu.addItem(item("Copier le jeton du serveur", #selector(copyToken)))
        menu.addItem(item("Adresse du serveur…", #selector(editServer)))
        if relay.state != .connected {
            menu.addItem(item("Se reconnecter maintenant", #selector(reconnect)))
        }
        let login = item("Ouvrir au démarrage du Mac", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(item("Quitter Navette", #selector(quit), key: "q"))
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: Actions

    @objc private func sendNow() {
        if let content = watcher.currentShareable() {
            send(content)
        } else {
            lastEvent = "↑ rien à envoyer (vide, fichier non image ou mot de passe)"
        }
    }

    // MARK: Téléphone

    @objc private func ring() {
        bridge.ring()
        lastEvent = "Le téléphone sonne (une minute au plus)"
    }

    @objc private func stopRinging() {
        bridge.stopRinging()
    }

    @objc private func toggleNotifications() {
        config.showsNotifications.toggle()
        config.save()
        bridge.showNotifications = config.showsNotifications
    }

    /// Navigateurs dont on sait lire l'onglet actif (AppleScript).
    private static let browsers: [String: (name: String, script: String)] = [
        "com.apple.Safari": ("Safari", "tell application id \"com.apple.Safari\" to get URL of current tab of front window"),
        "com.google.Chrome": ("Chrome", "tell application id \"com.google.Chrome\" to get URL of active tab of front window"),
        "com.brave.Browser": ("Brave", "tell application id \"com.brave.Browser\" to get URL of active tab of front window"),
        "com.microsoft.edgemac": ("Edge", "tell application id \"com.microsoft.edgemac\" to get URL of active tab of front window"),
        "company.thebrowser.Browser": ("Arc", "tell application id \"company.thebrowser.Browser\" to get URL of active tab of front window"),
    ]

    private func openOnPhoneItem() -> NSMenuItem {
        if let bundle = frontBundleID, let browser = Self.browsers[bundle] {
            return item("Ouvrir l’onglet de \(browser.name) sur le téléphone", #selector(openFrontTabOnPhone))
        }
        if copiedURL() != nil {
            return item("Ouvrir le lien copié sur le téléphone", #selector(openCopiedURLOnPhone))
        }
        return disabled("Ouvrir sur le téléphone (aucun onglet ni lien copié)")
    }

    private func copiedURL() -> URL? {
        guard let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil
        else { return nil }
        return url
    }

    @objc private func openFrontTabOnPhone() {
        guard let bundle = frontBundleID, let browser = Self.browsers[bundle] else { return }
        var error: NSDictionary?
        let result = NSAppleScript(source: browser.script)?.executeAndReturnError(&error)
        guard let string = result?.stringValue, let url = URL(string: string),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            lastEvent = error != nil
                ? "Autorisez Navette à piloter \(browser.name) : Réglages Système › Confidentialité › Automatisation"
                : "Cet onglet n’a pas d’adresse web"
            return
        }
        bridge.openOnPhone(url)
        lastEvent = "↑ ouvert sur le téléphone : \(url.host ?? string)"
    }

    @objc private func openCopiedURLOnPhone() {
        guard let url = copiedURL() else { return }
        bridge.openOnPhone(url)
        lastEvent = "↑ ouvert sur le téléphone : \(url.host ?? url.absoluteString)"
    }

    // MARK: Liens navette:// (bouton du Centre de contrôle)

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "navette" {
            switch url.host {
            case "point-acces": hotspot.request()
            default: break // navette://pair sert au téléphone, pas au Mac
            }
        }
    }

    // MARK: Point d'accès

    @objc private func requestHotspot() {
        hotspot.request()
    }

    @objc private func toggleHotspotAuto() {
        hotspot.automatic.toggle()
        config.hotspotAuto = hotspot.automatic
        config.save()
    }

    /// Réseau Wi-Fi du point d'accès, parmi ceux que le Mac connaît (mot de passe déjà enregistré).
    private func networkChoiceItem() -> NSMenuItem {
        let current = hotspot.targetNetwork(phoneName: hotspot.phoneName)
        let parent = NSMenuItem(title: "Réseau du point d’accès : \(current ?? "à choisir")", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.addItem(disabled("Réseaux déjà connus de ce Mac"))
        for name in Hotspot.knownNetworks() {
            let entry = item(name, #selector(chooseHotspotNetwork(_:)))
            entry.representedObject = name
            entry.state = name == current ? .on : .off
            submenu.addItem(entry)
        }
        parent.submenu = submenu
        return parent
    }

    @objc private func changeHotspotPassword() {
        hotspot.changePassword()
    }

    private func askHotspotPassword(_ ssid: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Mot de passe du point d’accès « \(ssid) »"
        alert.informativeText = "Sur le téléphone : Paramètres › Connexions › Point d’accès mobile et modem › Point d’accès mobile. "
            + "Navette le garde dans votre trousseau et ne le demandera plus."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Enregistrer et se connecter")
        alert.addButton(withTitle: "Annuler")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    @objc private func chooseHotspotNetwork(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        hotspot.networkName = name
        config.hotspotNetwork = name
        config.save()
    }

    @objc private func chooseHotspotPhone(_ sender: NSMenuItem) {
        guard let address = sender.representedObject as? String else { return }
        hotspot.deviceAddress = address
        config.hotspotDevice = address
        config.save()
    }

    // MARK: Historique

    private func historyItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Historique", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        if history.entries.isEmpty {
            submenu.addItem(disabled("Rien pour l’instant"))
        } else {
            submenu.addItem(disabled("Cliquez pour recopier sur le Mac"))
            for (index, entry) in history.entries.enumerated() {
                let arrow = entry.direction == .sent ? "↑" : "↓"
                let when = entry.date.formatted(date: .omitted, time: .shortened)
                let menuItem = item("\(arrow) \(entry.content.preview) · \(when)", #selector(recopy(_:)))
                menuItem.tag = index
                menuItem.image = entry.thumbnail
                submenu.addItem(menuItem)
            }
            submenu.addItem(.separator())
            submenu.addItem(item("Effacer l’historique", #selector(clearHistory)))
        }
        parent.submenu = submenu
        return parent
    }

    @objc private func recopy(_ sender: NSMenuItem) {
        guard history.entries.indices.contains(sender.tag) else { return }
        // Recopie locale seulement : le téléphone l'a déjà (ou en est la source).
        let content = history.entries[sender.tag].content
        watcher.write(content)
        lastEvent = "Recopié : \(content.preview)"
    }

    @objc private func clearHistory() {
        history.clear()
    }

    @objc private func toggleAuto() {
        config.autoSend.toggle()
        config.save()
    }

    @objc private func showPairing() {
        if pairingWindow == nil {
            pairingWindow = PairingWindow(config: config, token: keys.token) { [weak self] in
                self?.copyToken()
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        pairingWindow?.showWindow(nil)
        pairingWindow?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func copyToken() {
        // Écrit via le watcher : le jeton ne doit pas partir vers le téléphone.
        watcher.write(.text(keys.token))
        lastEvent = "Jeton copié (à coller dans NAVETTE_TOKEN)"
    }

    @objc private func editServer() {
        let alert = NSAlert()
        alert.messageText = "Adresse du serveur Navette"
        alert.informativeText = "L’adresse de votre serveur Navette, par exemple http://192.168.1.10:3200 sur votre réseau local, "
            + "ou son adresse Tailscale (100.x.y.z) pour qu’il soit joignable aussi en 4G."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = config.server
        alert.accessoryView = field
        alert.addButton(withTitle: "Enregistrer")
        alert.addButton(withTitle: "Annuler")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme ?? ""), url.host != nil else {
            let error = NSAlert()
            error.messageText = "Adresse invalide"
            error.informativeText = "Elle doit commencer par http:// ou https://."
            error.runModal()
            return
        }
        config.server = value.hasSuffix("/") ? String(value.dropLast()) : value
        config.save()
        pairingWindow?.close()
        pairingWindow = nil // le QR contient l'adresse : il faut le régénérer
        relay.start(config: config, token: keys.token)
    }

    @objc private func reconnect() {
        relay.reconnectNow()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

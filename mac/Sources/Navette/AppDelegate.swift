import AppKit
import NavetteCore
import ServiceManagement
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate, NSDraggingDestination {
    private var config = Config.loadOrCreate()
    private var keys: NavetteCrypto.Keys!
    private let relay = Relay()
    private let local = LocalLink()
    private let ble = BleLink()
    private let watcher = ClipboardWatcher()
    private var statusItem: NSStatusItem!
    private var pairingWindow: PairingWindow?

    private var lastEvent: String?
    private var flashTimer: Timer?
    private let history = History()
    private let bridge = PhoneBridge()
    private let hotspot = Hotspot()
    private let replayGuard = ReplayGuard()
    /// App au premier plan quand le menu s'ouvre (pour « Ouvrir l'onglet sur le téléphone »).
    private var frontBundleID: String?

    /// Au-delà, on n'envoie pas (un copier accidentel d'un énorme journal, par exemple).
    private let maxTextBytes = 1_000_000

    // Fichiers (voir FileTransfer.swift) : envoyés un par un, reçus dans Téléchargements.
    private var fileQueue: [URL] = []
    private var fileSender: FileSender?
    private var preparingFile = false
    private var filesSent = 0
    private let assembler = FileAssembler(directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("fr.soufiane.navette/Reception"))
    private var incomingFiles: [String: (name: String, received: Int64, size: Int64)] = [:]
    private var fileTimer: Timer?

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
            guard let self else { return }
            self.updateIcon()
            // Le téléphone renvoie sa batterie et ses adresses, et apprend si le Mac est joignable par le relais.
            let online = state == .connected
            if online != self.bridge.macOnRelay || online {
                self.bridge.macOnRelay = online
                self.bridge.sync()
            }
        }
        local.log = { Journal.write($0) }
        local.onState = { [weak self] _ in
            guard let self else { return }
            self.updateIcon()
            // Le Bluetooth ne sert qu'en l'absence de réseau commun.
            self.ble.wanted = !self.local.isConnected
            if self.local.isConnected { self.bridge.sync() }
        }
        local.onClip = { [weak self] clip in self?.received(clip, from: "local") }
        local.onChunk = { [weak self] chunk in self?.received(chunk) }
        ble.log = { Journal.write($0) }
        ble.onState = { [weak self] _ in
            self?.updateIcon()
            if self?.ble.isConnected == true { self?.bridge.sync() }
        }
        ble.onClip = { [weak self] clip in self?.received(clip, from: "bluetooth") }
        ble.onChunk = { [weak self] chunk in self?.received(chunk) }
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
        // Fichiers déposés sur l'icône de la barre des menus (la fenêtre du bouton transmet le
        // glisser-déposer à son délégué) et service « Envoyer au téléphone » du Finder.
        if let window = statusItem.button?.window {
            window.registerForDraggedTypes([.fileURL])
            window.delegate = self
        }
        assembler.reply = { [weak self] json in self?.sendEvent(json) }
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        fileTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.assembler.expire().forEach { self?.fileEvent($0) }
        }
        relay.start(config: config, token: keys.token)
        local.start(keys: keys)
        ble.start(keys: keys)
        ble.wanted = !local.isConnected
        watcher.start()

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.relay.reconnectNow()
            self?.local.reconnectNow()
        }

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
        transmit(clip) { [weak self] ok in
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
        transmit(clip, ephemeral: true)
    }

    /// Wi-Fi direct, sinon Bluetooth, sinon (ou en cas d'échec) relais. Une grosse image évite le
    /// Bluetooth (quelques dizaines de Ko/s) quand le relais la porte jusqu'au téléphone.
    private func transmit(_ clip: NavetteCrypto.Clip, ephemeral: Bool = false, completion: ((Bool) -> Void)? = nil) {
        let viaRelay = { [weak self] in self?.relay.send(clip, ephemeral: ephemeral, completion: completion) ?? () }
        let fallback: (Bool) -> Void = { ok in if ok { completion?(true) } else { viaRelay() } }
        let size = clip.data.utf8.count
        let route: (String) -> Void = { if !ephemeral { Journal.write("envoi par \($0) (\(size / 1024) Ko)") } }
        if local.send(clip, ephemeral: ephemeral, completion: fallback) { return route("Wi-Fi") }
        let big = size > 400_000 // ≈ 256 Ko d'image, une fois en base64 et chiffrée
        let relayCarries = relay.state == .connected && bridge.phoneOnRelay
        if !(big && relayCarries), ble.send(clip, ephemeral: ephemeral, completion: fallback) { return route("Bluetooth") }
        route("le relais")
        viaRelay()
    }

    private func received(_ clip: NavetteCrypto.Clip, from: String) {
        guard let data = try? NavetteCrypto.openData(clip, key: keys.encKey),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Par le relais, un morceau de fichier binaire arrive en base64 dans un Clip.
            if let chunk = NavetteCrypto.Chunk(clip: clip), received(chunk) { return }
            lastEvent = "↓ élément illisible (secret différent ?)"
            return
        }
        // Un message déjà reçu ou trop ancien est ignoré : le serveur ne peut pas rejouer nos commandes.
        guard replayGuard.accept(id: clip.id, t: (json["t"] as? NSNumber)?.doubleValue) else {
            Journal.write("élément \(clip.id.prefix(8)) ignoré : rejoué ou périmé")
            return
        }
        if json["kind"] as? String == "local" {
            let hosts = (json["addrs"] as? [String]) ?? []
            local.setAnnounced(hosts: hosts, port: (json["port"] as? NSNumber)?.intValue ?? 0)
            return
        }
        if let kind = json["kind"] as? String, kind.hasPrefix("file") {
            // Accusé de réception ou refus : pour l'envoi en cours ; le reste, pour la réception.
            if kind == "file-ack" || (kind == "file-cancel" && json["fid"] as? String == fileSender?.fid) {
                fileSender?.handle(json)
            } else if let event = assembler.accept(json) {
                fileEvent(event)
            }
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

    /// Morceau de fichier binaire (liaison directe, ou relais). false s'il ne se déchiffre pas.
    @discardableResult
    private func received(_ chunk: NavetteCrypto.Chunk) -> Bool {
        guard let (meta, bytes) = try? NavetteCrypto.openChunk(chunk, key: keys.encKey) else {
            lastEvent = "↓ élément illisible (secret différent ?)"
            return false
        }
        guard replayGuard.accept(id: chunk.id, t: (meta["t"] as? NSNumber)?.doubleValue),
              meta["kind"] as? String == "file" else { return true }
        var json = meta
        json["data"] = bytes
        if let event = assembler.accept(json) { fileEvent(event) }
        return true
    }

    // MARK: Fichiers

    /// Fichiers ou dossiers (envoyés en .zip) à envoyer au téléphone, à la suite des envois en cours.
    func sendFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        fileQueue += urls
        startNextFile()
    }

    private func startNextFile() {
        guard fileSender == nil, !preparingFile else { return }
        guard !fileQueue.isEmpty else {
            filesSent = 0
            return
        }
        let url = fileQueue.removeFirst()
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
            return startFile(url, name: nil, temporary: false)
        }
        // Dossier : macOS le compresse (comme « Compresser » dans le Finder).
        preparingFile = true
        lastEvent = "↑ compression de « \(url.lastPathComponent) »…"
        DispatchQueue.global(qos: .userInitiated).async {
            let zip = Self.zip(url)
            DispatchQueue.main.async {
                self.preparingFile = false
                if let zip {
                    self.startFile(zip, name: url.lastPathComponent + ".zip", temporary: true)
                } else {
                    self.fileFailed(url.lastPathComponent, "compression impossible")
                    self.startNextFile()
                }
            }
        }
    }

    private static func zip(_ folder: URL) -> URL? {
        var result: URL?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &error) { zipped in
            // Le .zip n'existe que dans ce bloc : on le copie.
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("navette-\(UUID().uuidString).zip")
            if (try? FileManager.default.copyItem(at: zipped, to: copy)) != nil { result = copy }
        }
        return result
    }

    /// Wi-Fi direct pour tout ; sinon le relais jusqu'à 25 Mo, puis le Bluetooth jusqu'à 2 Mo.
    private func fileRoute(size: Int64) -> (chunk: Int, bluetooth: Bool)? {
        if local.isConnected { return (FileChunks.chunkSize, false) }
        if relay.state == .connected && bridge.phoneOnRelay && size <= FileChunks.maxRelayBytes {
            return (FileChunks.chunkSize, false)
        }
        if ble.isConnected && size <= FileChunks.maxBluetoothBytes { return (FileChunks.bluetoothChunkSize, true) }
        return nil
    }

    private func startFile(_ url: URL, name: String?, temporary: Bool, waited: Int = 0) {
        let cleanup = { if temporary { try? FileManager.default.removeItem(at: url) } }
        let displayName = name ?? url.lastPathComponent
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        guard let route = fileRoute(size: size) else {
            // App tout juste lancée (service du Finder), réveil… : on laisse aux liaisons le temps de s'établir.
            if waited < 15 {
                preparingFile = true
                lastEvent = "↑ \(displayName) : en attente du téléphone…"
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self.preparingFile = false
                    self.startFile(url, name: name, temporary: temporary, waited: waited + 1)
                }
                return
            }
            cleanup()
            let why = local.isConnected || relay.state == .connected || ble.isConnected
                ? "trop gros sans liaison Wi-Fi avec le téléphone (\(Self.bytes(size)))"
                : "téléphone injoignable"
            fileFailed(displayName, why)
            return startNextFile()
        }
        let key = keys.encKey
        let mime = UTType(filenameExtension: (displayName as NSString).pathExtension)?.preferredMIMEType
        guard let sender = FileSender(
            url: url, name: displayName, mime: mime,
            // Chemin réévalué à chaque morceau : relais perdu en route → Bluetooth, Wi-Fi retrouvé…
            chunkSize: { [weak self] in self?.fileRoute(size: size)?.chunk },
            seal: { try? NavetteCrypto.seal(json: $0, key: key) },
            sealChunk: { try? NavetteCrypto.sealChunk(meta: $0, bytes: $1, key: key) },
            transmit: { [weak self] outgoing, done in
                guard let self, let route = self.fileRoute(size: size) else { return done(false) }
                self.transmitChunk(outgoing, fileSize: size, bluetooth: route.bluetooth, completion: done)
            }
        ) else {
            cleanup()
            fileFailed(displayName, "fichier illisible")
            return startNextFile()
        }
        Journal.write("envoi du fichier « \(sender.name) » (\(Self.bytes(size)), morceaux de \(route.chunk / 1024) Ko)")
        fileSender = sender
        lastEvent = "↑ \(sender.name) — 0 %"
        sender.onProgress = { [weak self, weak sender] in
            guard let self, let sender else { return }
            self.lastEvent = "↑ \(sender.name) — \(Self.percent(sender.sent, sender.size))"
        }
        sender.onFinish = { [weak self, weak sender] error in
            guard let self, let sender else { return }
            cleanup()
            self.fileSender = nil
            if let error {
                self.fileFailed(sender.name, error)
            } else {
                Journal.write("fichier « \(sender.name) » envoyé, réception confirmée")
                self.filesSent += 1
                self.lastEvent = "↑ \(sender.name) envoyé (\(Self.bytes(sender.size)))"
                self.flash("arrow.up.circle.fill")
                if self.fileQueue.isEmpty {
                    self.bridge.notifyFile(title: self.filesSent > 1 ? "\(self.filesSent) fichiers envoyés au téléphone"
                                                                     : "Fichier envoyé au téléphone",
                                           body: sender.name, reveal: nil)
                }
            }
            self.startNextFile()
        }
        sender.start()
    }

    /// Même principe que `transmit`, mais un gros fichier ne se rabat jamais sur le relais. Un morceau
    /// part en trame binaire sur une liaison directe, en base64 (une seule fois) par le relais.
    private func transmitChunk(_ outgoing: FileOutgoing, fileSize: Int64, bluetooth: Bool,
                               completion: @escaping (Bool) -> Void) {
        let clip: () -> NavetteCrypto.Clip = { // base64 seulement si nécessaire
            switch outgoing {
            case .message(let message): return message
            case .chunk(let chunk): return chunk.clip
            }
        }
        let viaRelay = { [weak self] in
            guard let self, fileSize <= FileChunks.maxRelayBytes else { return completion(false) }
            self.relay.send(clip(), ephemeral: true, completion: completion)
        }
        let fallback: (Bool) -> Void = { ok in if ok { completion(true) } else { viaRelay() } }
        if case .chunk(let chunk) = outgoing {
            if local.send(chunk, completion: fallback) { return }
            if bluetooth, ble.send(chunk, completion: fallback) { return }
        }
        if local.send(clip(), ephemeral: true, completion: fallback) { return }
        if bluetooth, ble.send(clip(), ephemeral: true, completion: fallback) { return }
        viaRelay()
    }

    private func fileFailed(_ name: String, _ reason: String) {
        Journal.write("fichier « \(name) » non envoyé : \(reason)")
        lastEvent = "↑ \(name) : \(reason)"
        bridge.notifyFile(title: "Fichier non envoyé", body: "\(name) : \(reason)", reveal: nil)
    }

    private func fileEvent(_ event: FileAssembler.Event) {
        switch event {
        case .progress(let fid, let name, let received, let size):
            if incomingFiles[fid] == nil { Journal.write("réception du fichier « \(name) » (\(Self.bytes(size)))") }
            incomingFiles[fid] = (name, received, size)
            lastEvent = "↓ \(name) — \(Self.percent(received, size))"
        case .completed(let fid, let name, let url):
            incomingFiles[fid] = nil
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            let destination = FileChunks.uniqueURL(for: name, in: downloads)
            do {
                try FileManager.default.moveItem(at: url, to: destination)
            } catch {
                try? FileManager.default.removeItem(at: url)
                Journal.write("fichier « \(name) » : déplacement impossible (\(error))")
                lastEvent = "↓ \(name) : impossible de l’enregistrer dans Téléchargements"
                return
            }
            Journal.write("fichier reçu : \(destination.path)")
            // Fait rebondir la pile Téléchargements du Dock, comme un téléchargement de Safari.
            DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"),
                                                         object: destination.resolvingSymlinksInPath().path)
            lastEvent = "↓ \(destination.lastPathComponent) (Téléchargements)"
            flash("arrow.down.circle.fill")
            bridge.notifyFile(title: "Fichier reçu du téléphone", body: destination.lastPathComponent, reveal: destination)
        case .failed(let fid, let name, let reason):
            incomingFiles[fid] = nil
            Journal.write("fichier « \(name) » : \(reason)")
            lastEvent = "↓ \(name) : \(reason)"
            bridge.notifyFile(title: "Fichier non reçu", body: "\(name) : \(reason)", reveal: nil)
        }
    }

    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    private static func percent(_ done: Int64, _ total: Int64) -> String {
        total > 0 ? "\(Int(done * 100 / total)) %" : "100 %"
    }

    @objc private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.title = "Envoyer au téléphone"
        panel.prompt = "Envoyer"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        sendFiles(panel.urls)
    }

    @objc private func cancelFiles() {
        fileQueue.removeAll()
        fileSender?.cancel()
    }

    /// Service du Finder (clic droit › Services › Envoyer au téléphone), déclaré dans Info.plist.
    @objc func sendFilesService(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        sendFiles(Self.fileURLs(pboard))
    }

    private static func fileURLs(_ pboard: NSPasteboard) -> [URL] {
        pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    // Glisser-déposer sur l'icône de la barre des menus.

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !Self.fileURLs(sender.draggingPasteboard).isEmpty else { return [] }
        statusItem.button?.highlight(true)
        return .copy
    }

    func draggingExited(_ sender: NSDraggingInfo?) {
        statusItem.button?.highlight(false)
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        statusItem.button?.highlight(false)
        let urls = Self.fileURLs(sender.draggingPasteboard)
        sendFiles(urls)
        return !urls.isEmpty
    }

    // MARK: Icône

    private func updateIcon() {
        guard flashTimer == nil else { return }
        let symbol: String
        switch relay.state {
        case _ where local.isConnected || ble.isConnected: symbol = "arrow.left.arrow.right.circle"
        case .connected: symbol = "arrow.left.arrow.right.circle"
        case .connecting: symbol = "arrow.left.arrow.right.circle"
        case .disconnected, .unauthorized: symbol = "exclamationmark.circle"
        }
        setIcon(symbol, dimmed: relay.state != .connected && !local.isConnected && !ble.isConnected)
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
        case .disconnected(let why): status = "○ Serveur hors ligne — \(why)"
        case .unauthorized: status = "⚠︎ Jeton refusé : mettez-le à jour sur le serveur"
        }
        menu.addItem(disabled(status))
        switch local.state {
        case .connected(let via): menu.addItem(disabled("● Liaison directe avec le téléphone (\(via))"))
        case .connecting: menu.addItem(disabled("◌ Liaison directe : connexion…"))
        case .searching: menu.addItem(disabled("○ Liaison directe : téléphone introuvable sur ce réseau"))
        }
        switch ble.state {
        case .connected: menu.addItem(disabled("● Liaison Bluetooth avec le téléphone (\(ble.transport))"))
        case .connecting: menu.addItem(disabled("◌ Bluetooth : connexion au téléphone…"))
        case .searching: menu.addItem(disabled("○ Bluetooth : téléphone hors de portée"))
        case .idle(let why) where !local.isConnected: menu.addItem(disabled("○ Bluetooth : \(why)"))
        case .idle: break
        }
        if let lastEvent { menu.addItem(disabled(lastEvent)) }
        for file in incomingFiles.values {
            menu.addItem(disabled("↓ \(file.name) — \(Self.percent(file.received, file.size))"))
        }
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
        menu.addItem(item("Envoyer des fichiers au téléphone…", #selector(chooseFiles)))
        if let sender = fileSender {
            let waiting = fileQueue.isEmpty ? "" : " (+\(fileQueue.count) en attente)"
            menu.addItem(item("Annuler l’envoi de « \(sender.name) »\(waiting)", #selector(cancelFiles)))
        }
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
        } else if case let urls = Self.fileURLs(NSPasteboard.general), !urls.isEmpty {
            sendFiles(urls) // fichiers copiés dans le Finder : envoyés comme fichiers
        } else {
            lastEvent = "↑ rien à envoyer (vide ou mot de passe)"
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
            pairingWindow = PairingWindow(config: config, token: keys.token, fingerprint: keys.fingerprint) { [weak self] in
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
        local.reconnectNow()
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

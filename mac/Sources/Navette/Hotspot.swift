import Foundation
import IOBluetooth
import Network

/// Point d'accès instantané, façon iPhone. Android interdit aux apps d'activer le point d'accès,
/// mais une routine Samsung (« si le Mac se connecte en Bluetooth → point d'accès activé ») le
/// peut. Il suffit donc que le Mac se connecte au téléphone en Bluetooth : ça marche sans
/// internet, ce qui est justement le cas où l'on en a besoin. macOS rejoint ensuite de lui-même
/// le réseau du téléphone, qu'il connaît déjà.
///
/// Une simple liaison Bluetooth ne suffit pas : Android ne compte un appareil « connecté »
/// qu'une fois un profil établi. Le Mac se présente donc brièvement comme kit mains-libres
/// (HFP) le temps de déclencher la routine (vérifié sur le S24 le 22/09/2026).
final class Hotspot {
    var onChange: (() -> Void)?
    /// Adresse Bluetooth du téléphone choisi (sinon : premier téléphone appairé).
    var deviceAddress: String?
    /// Demander le point d'accès tout seul quand le Mac perd internet.
    var automatic = false
    /// Nom du réseau Wi-Fi du point d'accès (sinon : nom Bluetooth du téléphone, s'il est connu du Mac).
    var networkName: String?
    /// Demande le mot de passe du point d'accès à l'utilisateur (fourni par AppDelegate) ; nil = annulé.
    var askPassword: ((String) -> String?)?

    private(set) var status: String?
    private(set) var isOnline = true
    private var lastRequest: Date?
    private var closeTimer: Timer?
    private var handsfree: HandsfreeLink?
    private var offlineTimer: Timer?
    private var joinAttempt = 0 // essais de connexion, une fois le réseau visible
    private let monitor = NWPathMonitor()

    /// Le temps pour la routine de se déclencher. Court exprès : tant que le Mac est « mains-libres »,
    /// un appel entrant pourrait chercher à passer son audio par lui.
    private static let holdSeconds: TimeInterval = 15
    /// Pas de nouvelle demande automatique avant ce délai (point d'accès coupé volontairement…).
    private static let autoCooldown: TimeInterval = 10 * 60

    func start() {
        // Demandée dès le lancement : sans elle, le Mac ne peut pas repérer le réseau du téléphone.
        if !WiFi.canReadNetworkNames { WiFi.requestPermission() }
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async { self?.pathChanged(path.status == .satisfied) }
        }
        monitor.start(queue: .global(qos: .utility))
    }

    static func pairedPhones() -> [IOBluetoothDevice] {
        let all = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        return all.filter { $0.deviceClassMajor == BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorPhone) }
    }

    var phoneName: String? { target()?.name }

    private func target() -> IOBluetoothDevice? {
        let phones = Self.pairedPhones()
        if let deviceAddress, let chosen = phones.first(where: { $0.addressString == deviceAddress }) { return chosen }
        return phones.first
    }

    func request() {
        guard handsfree == nil else { return } // demande déjà en cours
        guard let device = target() else {
            setStatus("Aucun téléphone appairé en Bluetooth avec ce Mac")
            return
        }
        lastRequest = Date()
        setStatus("Demande envoyée à \(device.name ?? "votre téléphone")…")
        // Déconnecter d'abord : la routine ne se déclenche que sur une nouvelle connexion.
        DispatchQueue.global(qos: .userInitiated).async {
            if device.isConnected() { device.closeConnection(); Thread.sleep(forTimeInterval: 1.5) }
            let result = device.openConnection()
            // Canal mains-libres introuvable tant que macOS n'a pas interrogé les services du téléphone.
            if result == kIOReturnSuccess, device.services == nil {
                _ = device.performSDPQuery(nil)
                Thread.sleep(forTimeInterval: 3)
            }
            DispatchQueue.main.async {
                guard result == kIOReturnSuccess else {
                    self.setStatus("Téléphone injoignable en Bluetooth (trop loin, ou Bluetooth coupé)")
                    return
                }
                self.startHandsfree(device)
            }
        }
    }

    private func startHandsfree(_ device: IOBluetoothDevice) {
        let link = HandsfreeLink(device: device) { [weak self] ok in
            guard let self else { return }
            if ok {
                self.setStatus("Point d’accès demandé, connexion du Mac…")
                self.joinHotspot(phoneName: device.name)
            } else {
                self.setStatus("Le téléphone n’a pas accepté la connexion Bluetooth")
            }
        }
        handsfree = link
        link.open()
        closeTimer?.invalidate()
        closeTimer = Timer.scheduledTimer(withTimeInterval: Self.holdSeconds, repeats: false) { [weak self] _ in
            self?.handsfree?.close()
            self?.handsfree = nil
        }
    }

    // MARK: Rejoindre le réseau du téléphone

    /// Réseaux Wi-Fi mémorisés par le Mac (pas besoin d'autorisation de localisation, contrairement
    /// à une recherche de réseaux, dont macOS masque les noms).
    static func knownNetworks() -> [String] {
        guard let port = wifiPort(),
              let output = run("/usr/sbin/networksetup", ["-listpreferredwirelessnetworks", port]) else { return [] }
        return output.split(separator: "\n").dropFirst()
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Réseau à rejoindre : celui choisi, sinon le nom du téléphone s'il est connu du Mac.
    func targetNetwork(phoneName: String?) -> String? {
        if let networkName { return networkName }
        guard let phoneName else { return nil }
        return Self.knownNetworks().first { $0 == phoneName }
    }

    /// Le point d'accès met quelques secondes à démarrer. On le **cherche** toutes les 3 s (une recherche
    /// ne coupe pas la connexion en cours) et on ne bascule qu'une fois son réseau visible : une tentative
    /// à l'aveugle déconnecte le Mac puis échoue, et macOS revient sur l'ancien réseau (vu le 22/09).
    /// Lire le nom des réseaux exige l'autorisation de localisation depuis macOS 14.
    private func joinHotspot(phoneName: String?) {
        guard let ssid = targetNetwork(phoneName: phoneName) else {
            setStatus("Point d’accès demandé ✓ (choisissez son réseau Wi-Fi dans le menu pour que le Mac s’y connecte seul)")
            return
        }
        guard WiFi.canReadNetworkNames else {
            WiFi.requestPermission()
            setStatus("Point d’accès demandé ✓ — autorisez la localisation pour que le Mac s’y connecte seul")
            Journal.write("rejoindre « \(ssid) » : autorisation de localisation manquante, demandée")
            return
        }
        if WiFi.currentNetwork() == ssid {
            setStatus("Déjà connecté au point d’accès « \(ssid) » ✓")
            return
        }
        joinAttempt = 0
        searchAndJoin(ssid: ssid, deadline: Date().addingTimeInterval(60))
    }

    private func searchAndJoin(ssid: String, deadline: Date) {
        DispatchQueue.global(qos: .userInitiated).async {
            let visible = WiFi.isVisible(ssid)
            DispatchQueue.main.async {
                guard visible else {
                    if Date() < deadline {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.searchAndJoin(ssid: ssid, deadline: deadline) }
                    } else {
                        self.setStatus("Point d’accès « \(ssid) » introuvable après une minute")
                        Journal.write("rejoindre « \(ssid) » : réseau jamais apparu")
                    }
                    return
                }
                self.join(ssid: ssid, deadline: deadline)
            }
        }
    }

    /// Connexion avec le mot de passe rangé dans le trousseau. macOS garde bien celui du réseau, mais
    /// dans le trousseau Système, illisible sans droits administrateur : networksetup échoue en -3900
    /// (constaté le 22/09). On le demande donc une fois à l'utilisateur.
    private func join(ssid: String, deadline: Date) {
        guard let password = WiFi.savedPassword(for: ssid) ?? promptPassword(ssid) else {
            setStatus("Point d’accès allumé ✓ — mot de passe requis pour que le Mac s’y connecte seul")
            return
        }
        joinAttempt += 1
        setStatus("Connexion au point d’accès « \(ssid) »…")
        DispatchQueue.global(qos: .userInitiated).async {
            let error = WiFi.join(ssid, password: password)
            Thread.sleep(forTimeInterval: 2)
            let joined = WiFi.currentNetwork() == ssid
            DispatchQueue.main.async {
                Journal.write("rejoindre « \(ssid) » (essai \(self.joinAttempt)) : \(error ?? "ok") → \(joined ? "connecté" : "pas connecté")")
                if joined {
                    self.setStatus("Connecté au point d’accès « \(ssid) » ✓")
                } else if self.joinAttempt < 3, Date() < deadline {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.join(ssid: ssid, deadline: deadline) }
                } else {
                    self.setStatus("Le Mac n’a pas pu rejoindre « \(ssid) » — mot de passe à vérifier dans le menu")
                }
            }
        }
    }

    private func promptPassword(_ ssid: String) -> String? {
        guard let password = askPassword?(ssid), !password.isEmpty else { return nil }
        WiFi.savePassword(password, for: ssid)
        return password
    }

    /// Menu « Mot de passe du point d'accès… » : changer le mot de passe enregistré.
    func changePassword() {
        guard let ssid = targetNetwork(phoneName: phoneName) else { return }
        if promptPassword(ssid) != nil { setStatus("Mot de passe de « \(ssid) » enregistré ✓") }
    }

    /// Nom de l'interface Wi-Fi (en0 en général).
    static func wifiPort() -> String? {
        guard let output = run("/usr/sbin/networksetup", ["-listallhardwareports"]) else { return nil }
        let lines = output.components(separatedBy: "\n")
        guard let index = lines.firstIndex(where: { $0.contains("Wi-Fi") || $0.contains("AirPort") }),
              index + 1 < lines.count else { return nil }
        return lines[index + 1].replacingOccurrences(of: "Device:", with: "").trimmingCharacters(in: .whitespaces)
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func pathChanged(_ online: Bool) {
        guard online != isOnline else { return }
        isOnline = online
        offlineTimer?.invalidate()
        if online {
            if let lastRequest, Date().timeIntervalSince(lastRequest) < 120 { setStatus("Internet rétabli via le téléphone ✓") }
            return
        }
        // Mode automatique : on laisse 20 s au Wi-Fi habituel pour revenir de lui-même.
        offlineTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
            guard let self, self.automatic, !self.isOnline else { return }
            if let last = self.lastRequest, Date().timeIntervalSince(last) < Self.autoCooldown { return }
            self.request()
        }
    }

    private func setStatus(_ text: String) {
        status = text
        onChange?()
    }
}

/// Côté « kit mains-libres » de l'ouverture d'une connexion HFP (Service Level Connection,
/// spécification Hands-Free Profile §4.2) : quatre commandes AT suffisent pour qu'Android
/// considère l'appareil comme connecté. Aucune fonction audio n'est annoncée ni utilisée.
private final class HandsfreeLink: NSObject, IOBluetoothRFCOMMChannelDelegate {
    private let device: IOBluetoothDevice
    private let completion: (Bool) -> Void
    private var channel: IOBluetoothRFCOMMChannel?
    private var steps = ["AT+BRSF=0", "AT+CIND=?", "AT+CIND?", "AT+CMER=3,0,0,1"]
    private var buffer = ""
    private var finished = false

    /// UUID 16 bits du service « Handsfree Audio Gateway » côté téléphone.
    private static let handsfreeGateway: BluetoothSDPUUID16 = 0x111F

    init(device: IOBluetoothDevice, completion: @escaping (Bool) -> Void) {
        self.device = device
        self.completion = completion
    }

    func open() {
        var channelID: BluetoothRFCOMMChannelID = 0
        guard let record = device.getServiceRecord(for: IOBluetoothSDPUUID(uuid16: Self.handsfreeGateway)),
              record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess else {
            return finish(false)
        }
        var opened: IOBluetoothRFCOMMChannel?
        guard device.openRFCOMMChannelAsync(&opened, withChannelID: channelID, delegate: self) == kIOReturnSuccess else {
            return finish(false)
        }
        channel = opened
        // Filet de sécurité si le téléphone ne répond pas.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.finish(false) }
    }

    func close() {
        channel?.close()
        let device = device
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { device.closeConnection() }
    }

    private func send(_ command: String) {
        var bytes = Array((command + "\r").utf8)
        _ = channel?.writeSync(&bytes, length: UInt16(bytes.count))
    }

    private func finish(_ ok: Bool) {
        guard !finished else { return }
        finished = true
        completion(ok)
    }

    func rfcommChannelOpenComplete(_ channel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        guard error == kIOReturnSuccess else { return finish(false) }
        send(steps.removeFirst())
    }

    func rfcommChannelData(_ channel: IOBluetoothRFCOMMChannel!, data: UnsafeMutableRawPointer!, length: Int) {
        buffer += String(decoding: UnsafeRawBufferPointer(start: data, count: length), as: UTF8.self)
        if buffer.contains("ERROR") { return finish(false) }
        guard buffer.contains("OK") else { return } // réponse pas encore complète
        buffer = ""
        if steps.isEmpty { finish(true) } else { send(steps.removeFirst()) }
    }

    func rfcommChannelClosed(_ channel: IOBluetoothRFCOMMChannel!) {
        finish(false)
    }
}

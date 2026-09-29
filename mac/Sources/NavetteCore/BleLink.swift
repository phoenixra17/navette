import CoreBluetooth
import Foundation

/// Liaison Bluetooth basse consommation avec le téléphone, quand ils n'ont aucun réseau en commun
/// (voir « Bluetooth link » dans PROTOCOL.md). Le téléphone publie un service GATT ; le Mac le
/// cherche et s'y connecte. De préférence, il lit le numéro (PSM) du canal L2CAP du téléphone et
/// l'ouvre : un vrai flux, bien plus rapide. Sinon, il écrit dans `toPhone` et reçoit les
/// notifications de `toMac`. Les octets forment le même flux de trames que la liaison Wi-Fi, avec
/// la même poignée de main.
///
/// Indépendante de la connexion mains-libres du point d'accès (Bluetooth classique, IOBluetooth) :
/// celle-ci est coupée au bout de 15 s sans toucher à la liaison BLE, qui passe par CoreBluetooth.
/// Tout se passe sur la file principale.
public final class BleLink: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, StreamDelegate {
    public enum State: Equatable {
        /// Pas de recherche : inutile (liaison Wi-Fi établie) ou impossible (Bluetooth éteint…).
        case idle(String)
        case searching
        case connecting
        case connected
    }

    public var onState: ((State) -> Void)?
    public var onClip: ((NavetteCrypto.Clip) -> Void)?
    public var onChunk: ((NavetteCrypto.Chunk) -> Void)?
    public var log: ((String) -> Void)?
    public private(set) var state: State = .idle("pas encore démarrée") {
        didSet {
            guard state != oldValue else { return }
            log?("Bluetooth : \(state)")
            onState?(state)
        }
    }

    public var isConnected: Bool { state == .connected }

    /// Mis à false par l'app quand la liaison Wi-Fi est établie : le Bluetooth ne sert alors à rien.
    public var wanted = false {
        didSet { if wanted != oldValue { update() } }
    }

    static let service = CBUUID(string: "8f1d3c52-6a4e-4b8e-9d1b-5a7c2e0f4a10")
    static let toPhoneUUID = CBUUID(string: "8f1d3c52-6a4e-4b8e-9d1b-5a7c2e0f4a11")
    static let toMacUUID = CBUUID(string: "8f1d3c52-6a4e-4b8e-9d1b-5a7c2e0f4a12")
    static let psmUUID = CBUUID(string: "8f1d3c52-6a4e-4b8e-9d1b-5a7c2e0f4a13")

    private var keys: NavetteCrypto.Keys?
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var toPhone: CBCharacteristic?
    private var toMac: CBCharacteristic?
    /// Canal L2CAP ouvert : toutes les trames y passent (sinon, par GATT).
    private var l2cap: CBL2CAPChannel?
    /// Pour l'affichage : « L2CAP » ou « GATT ».
    public private(set) var transport = ""
    private var parser = LinkWire.Parser()

    /// Poignée de main en cours : nonce du Mac, puis attente de « ready ».
    private enum Stage { case none, awaitingHello(macNonce: String), awaitingReady, ready }
    private var stage = Stage.none

    /// Octets à écrire, par trame, avec de quoi prévenir l'appelant.
    private var outbox: [(data: Data, completion: ((Bool) -> Void)?, started: Date)] = []
    /// Téléphones qui ont échoué à la poignée de main (autre secret) : ignorés un moment.
    private var foreign: [UUID: Date] = [:]
    private var timeout: Timer?
    private var pingTimer: Timer?
    private var retryTimer: Timer?
    private var lastHeard = Date()
    /// Le téléphone lit les trames binaires (annoncé par `bin` dans son `hello`).
    private var peerBinary = false

    public override init() { super.init() }

    public func start(keys: NavetteCrypto.Keys) {
        self.keys = keys
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
        update()
    }

    // MARK: Envoi

    /// false si la liaison n'est pas établie : l'appelant passe alors par le relais.
    @discardableResult
    public func send(_ clip: NavetteCrypto.Clip, ephemeral: Bool = false,
                     completion: ((Bool) -> Void)? = nil) -> Bool {
        guard isConnected else { return false }
        var message: [String: Any] = ["type": "clip", "id": clip.id, "iv": clip.iv, "data": clip.data]
        if ephemeral { message["ephemeral"] = true }
        enqueue(message, completion: completion)
        return true
    }

    /// Morceau de fichier en trame binaire. false si pas de liaison, ou téléphone qui ne les lit pas.
    public func send(_ chunk: NavetteCrypto.Chunk, completion: @escaping (Bool) -> Void) -> Bool {
        guard isConnected, peerBinary, let frame = LinkWire.encode(chunk) else { return false }
        outbox.append((frame, completion, Date()))
        pump()
        return true
    }

    // MARK: Recherche et connexion

    private func update() {
        guard let central else { return }
        switch central.state {
        case .poweredOn: break
        case .unauthorized:
            reset(); state = .idle("Bluetooth non autorisé (Réglages Système › Confidentialité)"); return
        case .poweredOff:
            reset(); state = .idle("Bluetooth désactivé"); return
        default:
            return // l'état arrive bientôt (centralManagerDidUpdateState)
        }
        guard wanted, keys != nil else {
            reset()
            state = .idle("inutile : liaison Wi-Fi établie")
            return
        }
        guard peripheral == nil else { return }
        state = .searching
        central.scanForPeripherals(withServices: [Self.service], options: nil)
    }

    /// Coupe tout ; les rappels d'écriture en attente échouent (l'appelant repasse par le relais).
    private func reset() {
        timeout?.invalidate()
        pingTimer?.invalidate()
        retryTimer?.invalidate()
        central?.stopScan()
        if let l2cap {
            for stream in [l2cap.inputStream as Stream?, l2cap.outputStream] {
                stream?.delegate = nil
                stream?.close()
            }
        }
        l2cap = nil
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        toPhone = nil
        toMac = nil
        stage = .none
        parser = LinkWire.Parser()
        let pending = outbox
        outbox = []
        pending.forEach { $0.completion?(false) }
    }

    private func retrySoon() {
        reset()
        guard wanted else { return update() }
        state = .searching
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in self?.update() }
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log?("Bluetooth : état du Mac \(central.state.rawValue), autorisation \(CBManager.authorization.rawValue)")
        update()
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard self.peripheral == nil else { return }
        if let since = foreign[peripheral.identifier], Date().timeIntervalSince(since) < 600 { return }
        central.stopScan()
        self.peripheral = peripheral
        state = .connecting
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
        // Connexion, services, abonnement et poignée de main.
        timeout = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
            guard let self, !self.isConnected else { return }
            self.log?("Bluetooth : pas de réponse du téléphone")
            self.retrySoon()
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral == self.peripheral else { return }
        peripheral.discoverServices([Self.service])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral == self.peripheral else { return }
        retrySoon()
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                               error: Error?) {
        guard peripheral == self.peripheral else { return }
        if isConnected { log?("liaison Bluetooth perdue") }
        retrySoon()
    }

    /// L'app du téléphone a redémarré (mise à jour, redémarrage) : son service a changé, on se reconnecte
    /// tout de suite au lieu d'attendre que les pings restent sans réponse.
    public func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard peripheral == self.peripheral, invalidatedServices.contains(where: { $0.uuid == Self.service }) else { return }
        log?("Bluetooth : service du téléphone redémarré")
        retrySoon()
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else { return retrySoon() }
        peripheral.discoverCharacteristics([Self.toPhoneUUID, Self.toMacUUID, Self.psmUUID], for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                           error: Error?) {
        let characteristics = service.characteristics ?? []
        guard let toPhone = characteristics.first(where: { $0.uuid == Self.toPhoneUUID }),
              let toMac = characteristics.first(where: { $0.uuid == Self.toMacUUID }) else { return retrySoon() }
        self.toPhone = toPhone
        self.toMac = toMac
        if let psm = characteristics.first(where: { $0.uuid == Self.psmUUID }) {
            peripheral.readValue(for: psm) // suite : ouverture du canal L2CAP
        } else {
            useGATT()
        }
    }

    /// Repli : les trames passent par les caractéristiques (écritures et notifications).
    private func useGATT() {
        guard let peripheral, let toMac else { return retrySoon() }
        transport = "GATT"
        peripheral.setNotifyValue(true, for: toMac)
    }

    private func openL2CAP(psmValue: Data?) {
        guard let peripheral, let bytes = psmValue, bytes.count == 2 else { return useGATT() }
        let psm = CBL2CAPPSM(UInt16(bytes[bytes.startIndex]) << 8 | UInt16(bytes[bytes.startIndex + 1]))
        peripheral.openL2CAPChannel(psm)
    }

    public func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard peripheral == self.peripheral else { return }
        guard let channel, error == nil, let input = channel.inputStream, let output = channel.outputStream else {
            log?("Bluetooth : canal L2CAP refusé (\(error?.localizedDescription ?? "?")), repli sur GATT")
            return useGATT()
        }
        l2cap = channel
        transport = "L2CAP"
        for stream in [input as Stream, output] {
            stream.delegate = self
            stream.schedule(in: .main, forMode: .default)
            stream.open()
        }
        sayHello()
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard characteristic.uuid == Self.toMacUUID, characteristic.isNotifying else { return retrySoon() }
        sayHello()
    }

    /// Poignée de main : hello (Mac) → hello + preuve (téléphone) → auth (Mac) → ready.
    private func sayHello() {
        let macNonce = LinkWire.nonce()
        stage = .awaitingHello(macNonce: macNonce)
        enqueue(["type": "hello", "v": 1, "nonce": macNonce, "bin": 1], completion: nil)
    }

    // MARK: Réception

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        if characteristic.uuid == Self.psmUUID { return openL2CAP(psmValue: error == nil ? characteristic.value : nil) }
        guard characteristic.uuid == Self.toMacUUID, let value = characteristic.value else { return }
        received(value)
    }

    private func received(_ bytes: Data) {
        lastHeard = Date()
        let messages: [[String: Any]]
        do { messages = try parser.append(bytes) } catch {
            log?("Bluetooth : trame invalide")
            return retrySoon()
        }
        for message in messages { handle(message) }
    }

    // MARK: Flux L2CAP

    public func stream(_ stream: Stream, handle event: Stream.Event) {
        guard let l2cap, stream === l2cap.inputStream || stream === l2cap.outputStream else { return }
        switch event {
        case .hasBytesAvailable:
            guard let input = stream as? InputStream else { return }
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while input.hasBytesAvailable {
                let n = input.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                received(Data(buffer[0..<n]))
                if self.l2cap == nil { return } // session abandonnée pendant le traitement
            }
        case .hasSpaceAvailable:
            pump()
        case .errorOccurred, .endEncountered:
            log?("Bluetooth : canal L2CAP fermé")
            retrySoon()
        default:
            break
        }
    }

    private func handle(_ message: [String: Any]) {
        let type = message["type"] as? String
        // Le téléphone a clos la session sans couper la liaison : on recommence.
        if type == "reset" {
            log?("Bluetooth : le téléphone demande une nouvelle poignée de main")
            return retrySoon()
        }
        switch stage {
        case .awaitingHello(let macNonce):
            guard let keys, type == "hello",
                  let phoneNonce = message["nonce"] as? String, phoneNonce.count >= 16,
                  let proof = message["proof"] as? String,
                  LinkWire.same(proof, NavetteCrypto.localProof(key: keys.localKey, role: .phone,
                                                               macNonce: macNonce, phoneNonce: phoneNonce))
            else {
                log?("Bluetooth : téléphone non reconnu")
                if let peripheral { foreign[peripheral.identifier] = Date() }
                return retrySoon()
            }
            stage = .awaitingReady
            peerBinary = message["bin"] != nil
            enqueue(["type": "auth", "proof": NavetteCrypto.localProof(key: keys.localKey, role: .mac,
                                                                       macNonce: macNonce, phoneNonce: phoneNonce)],
                    completion: nil)
        case .awaitingReady:
            guard type == "ready" else { return retrySoon() }
            established()
        case .ready:
            if let chunk = message["chunk"] as? NavetteCrypto.Chunk { onChunk?(chunk) }
            if type == "clip", let id = message["id"] as? String, let iv = message["iv"] as? String,
               let data = message["data"] as? String {
                onClip?(NavetteCrypto.Clip(id: id, iv: iv, data: data))
            }
            if type == "ping" { enqueue(["type": "pong"], completion: nil) }
        case .none:
            break
        }
    }

    private func established() {
        timeout?.invalidate()
        stage = .ready
        parser.limit = LinkWire.maxFrame
        lastHeard = Date()
        log?("liaison Bluetooth établie (\(transport))")
        state = .connected
        pingTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastHeard) > 40 {
                self.log?("Bluetooth : plus de nouvelles du téléphone")
                return self.retrySoon()
            }
            self.enqueue(["type": "ping"], completion: nil)
        }
    }

    // MARK: Écriture : écritures sans réponse, au rythme que permet la liaison

    private func enqueue(_ message: [String: Any], completion: ((Bool) -> Void)?) {
        guard let frame = LinkWire.encode(message) else { completion?(false); return }
        outbox.append((frame, completion, Date()))
        pump()
    }

    private func pump() {
        if let output = l2cap?.outputStream { return pumpL2CAP(output) }
        guard let peripheral, let toPhone else { return }
        let size = max(20, peripheral.maximumWriteValueLength(for: .withoutResponse))
        while !outbox.isEmpty, peripheral.canSendWriteWithoutResponse {
            let chunk = outbox[0].data.prefix(size)
            peripheral.writeValue(Data(chunk), for: toPhone, type: .withoutResponse)
            outbox[0].data = Data(outbox[0].data.dropFirst(chunk.count))
            if outbox[0].data.isEmpty { finishFrame() }
        }
    }

    private func pumpL2CAP(_ output: OutputStream) {
        while !outbox.isEmpty, output.hasSpaceAvailable {
            let written = outbox[0].data.withUnsafeBytes { raw in
                output.write(raw.bindMemory(to: UInt8.self).baseAddress!, maxLength: raw.count)
            }
            if written < 0 { return retrySoon() }
            if written == 0 { return }
            outbox[0].data = Data(outbox[0].data.dropFirst(written))
            if outbox[0].data.isEmpty { finishFrame() }
        }
    }

    private func finishFrame() {
        let done = outbox.removeFirst()
        let seconds = Date().timeIntervalSince(done.started)
        if seconds > 2 { log?(String(format: "Bluetooth : trame écrite en %.1f s (%@)", seconds, transport)) }
        done.completion?(true)
    }

    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        pump()
    }
}

import CryptoKit
import Foundation
import Network

/// Liaison directe avec le téléphone, sans serveur (voir « Liaison locale » dans PROTOCOL.md).
/// Le téléphone écoute et s'annonce en Bonjour (`_navette._tcp`) ; le Mac le cherche et s'y connecte.
/// Candidats, dans l'ordre : adresse forcée (`NAVETTE_LOCAL=hôte:port`), Bonjour, puis les adresses
/// que le téléphone a envoyées par le relais (Wi-Fi, point d'accès, Tailscale).
/// Tout se passe sur la file principale.
public final class LocalLink {
    public enum State: Equatable {
        case searching
        case connecting
        /// `via` : « Wi-Fi local », « Tailscale »…
        case connected(via: String)
    }

    public var onState: ((State) -> Void)?
    public var onClip: ((NavetteCrypto.Clip) -> Void)?
    /// Diagnostic (le journal de l'app).
    public var log: ((String) -> Void)?
    public private(set) var state: State = .searching {
        didSet { if state != oldValue { onState?(state) } }
    }

    public var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    public static let serviceType = "_navette._tcp"
    /// Taille maximale d'une trame (image de 16 Mo en base64 comprise), et avant authentification.
    static let maxFrame = 24 * 1024 * 1024
    static let maxHandshakeFrame = 4096

    private var keys: NavetteCrypto.Keys?
    private var browser: NWBrowser?
    private let pathMonitor = NWPathMonitor()
    private var bonjour: [NWEndpoint] = []
    private var announced: [NWEndpoint] = []
    private let manual: NWEndpoint?

    private var connection: NWConnection?
    /// Incrémenté à chaque tentative : les rappels d'une tentative abandonnée sont ignorés.
    private var attempt = 0
    private var queue: [NWEndpoint] = []
    private var retryTimer: Timer?
    private var retryDelay: TimeInterval = 2
    private var handshakeTimer: Timer?
    private var pingTimer: Timer?
    private var lastHeard = Date()

    public init() {
        manual = ProcessInfo.processInfo.environment["NAVETTE_LOCAL"].flatMap(Self.endpoint(from:))
    }

    public func start(keys: NavetteCrypto.Keys) {
        self.keys = keys
        browse()
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.networkChanged() }
        }
        pathMonitor.start(queue: .main)
        reconnectNow()
    }

    /// Réveil du Mac, nouveau réseau… : on repart de zéro si la liaison n'est pas établie.
    public func reconnectNow() {
        guard !isConnected else { return }
        retryDelay = 2
        tryCandidates()
    }

    /// Adresses envoyées par le téléphone (message `local`), essayées après Bonjour.
    public func setAnnounced(hosts: [String], port: Int) {
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port.rawValue > 0 else { return }
        let endpoints = hosts.map { NWEndpoint.hostPort(host: NWEndpoint.Host($0), port: port) }
        guard endpoints != announced else { return }
        announced = endpoints
        reconnectNow()
    }

    // MARK: Envoi

    /// false si la liaison n'est pas établie : l'appelant passe alors par le relais.
    @discardableResult
    public func send(_ clip: NavetteCrypto.Clip, ephemeral: Bool = false,
                     completion: ((Bool) -> Void)? = nil) -> Bool {
        guard isConnected, let connection else { return false }
        var message: [String: Any] = ["type": "clip", "id": clip.id, "iv": clip.iv, "data": clip.data]
        if ephemeral { message["ephemeral"] = true }
        write(message, on: connection) { ok in completion?(ok) }
        return true
    }

    // MARK: Découverte

    private func browse() {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, let id = self.keys?.localID else { return }
            // Seul le téléphone appairé à ce Mac (même secret) annonce cet identifiant.
            self.bonjour = results.compactMap { result in
                guard case .bonjour(let txt) = result.metadata, txt["id"] == id else { return nil }
                return result.endpoint
            }
            if !self.bonjour.isEmpty { self.reconnectNow() }
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state { self?.log?("Bonjour : \(error)") }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func networkChanged() {
        if isConnected { ping() } else { reconnectNow() } // une liaison morte se révèle au ping
    }

    // MARK: Connexion

    private func tryCandidates() {
        retryTimer?.invalidate()
        guard keys != nil else { return }
        queue = [manual].compactMap { $0 } + bonjour + announced
        tryNext()
    }

    private func tryNext() {
        drop()
        guard !queue.isEmpty else {
            state = .searching
            retryTimer = Timer.scheduledTimer(withTimeInterval: retryDelay, repeats: false) { [weak self] _ in
                self?.tryCandidates()
            }
            retryDelay = min(retryDelay * 2, 60)
            return
        }
        let endpoint = queue.removeFirst()
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 3
        tcp.noDelay = true
        let connection = NWConnection(to: endpoint, using: NWParameters(tls: nil, tcp: tcp))
        attempt += 1
        let current = attempt
        self.connection = connection
        state = .connecting
        connection.stateUpdateHandler = { [weak self] connState in
            guard let self, current == self.attempt else { return }
            switch connState {
            case .ready: self.sayHello(on: connection, attempt: current)
            case .failed, .cancelled: self.lost(attempt: current)
            case .waiting: self.lost(attempt: current) // hôte injoignable sur ce réseau : au suivant
            default: break
            }
        }
        connection.viabilityUpdateHandler = { [weak self] viable in
            guard let self, current == self.attempt, !viable, self.isConnected else { return }
            self.lost(attempt: current)
        }
        connection.start(queue: .main)
        // Délai global : connexion TCP + poignée de main.
        handshakeTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            guard let self, current == self.attempt, !self.isConnected else { return }
            self.tryNext()
        }
    }

    private func drop() {
        attempt += 1
        handshakeTimer?.invalidate()
        pingTimer?.invalidate()
        connection?.cancel()
        connection = nil
    }

    private func lost(attempt current: Int) {
        guard current == attempt else { return }
        if isConnected {
            log?("liaison locale perdue")
            retryDelay = 2
            tryCandidates()
        } else {
            tryNext()
        }
    }

    // MARK: Poignée de main (voir PROTOCOL.md)

    private func sayHello(on connection: NWConnection, attempt current: Int) {
        guard let keys else { return }
        let macNonce = Self.nonce()
        write(["type": "hello", "v": 1, "nonce": macNonce], on: connection)
        readFrame(on: connection, limit: Self.maxHandshakeFrame, attempt: current) { [weak self] hello in
            guard let self, hello["type"] as? String == "hello",
                  let phoneNonce = hello["nonce"] as? String, phoneNonce.count >= 16,
                  let proof = hello["proof"] as? String,
                  Self.same(proof, NavetteCrypto.localProof(key: keys.localKey, role: .phone,
                                                            macNonce: macNonce, phoneNonce: phoneNonce))
            else {
                self?.log?("liaison locale : téléphone non reconnu")
                return self?.tryNext() ?? ()
            }
            let mine = NavetteCrypto.localProof(key: keys.localKey, role: .mac, macNonce: macNonce, phoneNonce: phoneNonce)
            self.write(["type": "auth", "proof": mine], on: connection)
            self.readFrame(on: connection, limit: Self.maxHandshakeFrame, attempt: current) { [weak self] ready in
                guard let self, ready["type"] as? String == "ready" else { return self?.tryNext() ?? () }
                self.established(connection, attempt: current)
            }
        }
    }

    private func established(_ connection: NWConnection, attempt current: Int) {
        handshakeTimer?.invalidate()
        queue = []
        retryDelay = 2
        lastHeard = Date()
        let path = connection.currentPath
        let via: String
        if path?.usesInterfaceType(.wifi) == true { via = "Wi-Fi local" }
        else if path?.usesInterfaceType(.wiredEthernet) == true { via = "réseau local" }
        else if path?.usesInterfaceType(.loopback) == true { via = "adresse forcée" }
        else { via = "Tailscale" } // utun
        let remote = path?.remoteEndpoint.map { "\($0)" } ?? "?"
        log?("liaison locale établie (\(via), \(remote))")
        state = .connected(via: via)
        pingTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.ping() }
        receiveLoop(on: connection, attempt: current)
    }

    private func receiveLoop(on connection: NWConnection, attempt current: Int) {
        readFrame(on: connection, limit: Self.maxFrame, attempt: current) { [weak self] message in
            guard let self else { return }
            self.lastHeard = Date()
            if message["type"] as? String == "clip",
               let id = message["id"] as? String, let iv = message["iv"] as? String, let data = message["data"] as? String {
                self.onClip?(NavetteCrypto.Clip(id: id, iv: iv, data: data))
            }
            // ping → pong ; pong : rien d'autre à faire que noter qu'on a des nouvelles.
            if message["type"] as? String == "ping" { self.write(["type": "pong"], on: connection) }
            self.receiveLoop(on: connection, attempt: current)
        }
    }

    private func ping() {
        guard isConnected, let connection else { return }
        if Date().timeIntervalSince(lastHeard) > 40 {
            lost(attempt: attempt)
            return
        }
        write(["type": "ping"], on: connection)
    }

    // MARK: Trames : longueur sur 4 octets (gros-boutiste) puis JSON en UTF-8

    private func write(_ message: [String: Any], on connection: NWConnection, completion: ((Bool) -> Void)? = nil) {
        guard let json = try? JSONSerialization.data(withJSONObject: message) else { completion?(false); return }
        var frame = Data(count: 4)
        frame.withUnsafeMutableBytes { $0.storeBytes(of: UInt32(json.count).bigEndian, as: UInt32.self) }
        frame.append(json)
        connection.send(content: frame, completion: .contentProcessed { error in
            DispatchQueue.main.async { completion?(error == nil) }
        })
    }

    private func readFrame(on connection: NWConnection, limit: Int, attempt current: Int,
                           handler: @escaping ([String: Any]) -> Void) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] header, _, _, error in
            guard let self, current == self.attempt else { return }
            guard error == nil, let header, header.count == 4 else { return self.lost(attempt: current) }
            let length = Int(header.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            guard length > 0, length <= limit else { return self.lost(attempt: current) }
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] body, _, _, error in
                guard let self, current == self.attempt else { return }
                guard error == nil, let body, body.count == length,
                      let message = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
                else { return self.lost(attempt: current) }
                handler(message)
            }
        }
    }

    // MARK: Utilitaires

    private static func nonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }

    /// Comparaison en temps constant.
    private static func same(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    static func endpoint(from string: String) -> NWEndpoint? {
        guard let colon = string.lastIndex(of: ":"),
              let port = UInt16(string[string.index(after: colon)...]),
              let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        let host = String(string[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return .hostPort(host: NWEndpoint.Host(host), port: nwPort)
    }
}

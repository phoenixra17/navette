import Foundation

/// Connexion WebSocket au serveur Navette, avec reconnexion automatique.
/// Tout se passe sur la file principale (délégué sur .main, minuteries sur la boucle principale).
public final class Relay: NSObject, URLSessionWebSocketDelegate {
    public enum State: Equatable {
        case disconnected(String)
        case connecting
        case connected
        case unauthorized
    }

    public var onState: ((State) -> Void)?
    public var onClip: ((NavetteCrypto.Clip, String) -> Void)?
    public private(set) var state: State = .disconnected("pas encore connecté") {
        didSet { if state != oldValue { onState?(state) } }
    }

    private var config: Config?
    private var token = ""
    private var task: URLSessionWebSocketTask?
    private var retryDelay: TimeInterval = 1
    private var retryTimer: Timer?
    private var pingTimer: Timer?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)

    public override init() { super.init() }

    public func start(config: Config, token: String) {
        self.config = config
        self.token = token
        retryDelay = 1
        connect()
    }

    /// Reconnexion immédiate (réveil du Mac, changement de réseau, nouvelle adresse).
    public func reconnectNow() {
        retryDelay = 1
        connect()
    }

    private func request(for url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(config?.device ?? "mac", forHTTPHeaderField: "X-Navette-Device")
        req.timeoutInterval = 10
        return req
    }

    private func connect() {
        retryTimer?.invalidate()
        pingTimer?.invalidate()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        guard let url = config?.webSocketURL else {
            state = .disconnected("adresse du serveur invalide")
            return
        }
        state = .connecting
        let task = session.webSocketTask(with: request(for: url))
        task.maximumMessageSize = 20 * 1024 * 1024 // images comprises
        self.task = task
        task.resume()
        receive(on: task)
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self, task === self.task else { return }
            switch result {
            case .success(let message):
                var raw: Data?
                switch message {
                case .string(let s): raw = Data(s.utf8)
                case .data(let d): raw = d
                @unknown default: break
                }
                if let raw, let msg = try? JSONDecoder().decode(Incoming.self, from: raw), msg.type == "clip" {
                    self.onClip?(NavetteCrypto.Clip(id: msg.id, iv: msg.iv, data: msg.data), msg.from ?? "?")
                }
                self.receive(on: task)
            case .failure:
                break // géré par didCompleteWithError
            }
        }
    }

    private func scheduleRetry() {
        retryTimer?.invalidate()
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 30)
        retryTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.connect()
        }
    }

    // MARK: Envoi

    /// Envoie par WebSocket si connecté, sinon par HTTP (le serveur relaie de la même façon).
    /// Un élément éphémère (notification, commande…) n'écrase pas le dernier presse-papier du serveur.
    public func send(_ clip: NavetteCrypto.Clip, ephemeral: Bool = false, completion: ((Bool) -> Void)? = nil) {
        let msg = Outgoing(type: "clip", id: clip.id, iv: clip.iv, data: clip.data, ephemeral: ephemeral ? true : nil)
        if state == .connected, let task {
            guard let data = try? JSONEncoder().encode(msg), let text = String(data: data, encoding: .utf8) else { return }
            task.send(.string(text)) { error in
                DispatchQueue.main.async { completion?(error == nil) }
            }
            return
        }
        guard let url = config?.clipURL else { completion?(false); return }
        var req = request(for: url)
        req.timeoutInterval = 60 // une image peut prendre du temps en 4G
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(msg)
        session.dataTask(with: req) { _, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async { completion?(ok) }
        }.resume()
    }

    // MARK: URLSessionWebSocketDelegate

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didOpenWithProtocol protocol: String?) {
        guard webSocketTask === task else { return }
        state = .connected
        retryDelay = 1
        pingTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self, weak webSocketTask] _ in
            webSocketTask?.sendPing { error in
                if error != nil { DispatchQueue.main.async { self?.connectionLost("pas de réponse du serveur") } }
            }
        }
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard webSocketTask === task else { return }
        connectionLost("connexion fermée")
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === self.task else { return }
        if (task.response as? HTTPURLResponse)?.statusCode == 401 {
            pingTimer?.invalidate()
            self.task = nil
            state = .unauthorized
            // On retente lentement : le jeton a peut-être été mis à jour sur le serveur entre-temps.
            retryDelay = 60
            scheduleRetry()
            return
        }
        connectionLost(error?.localizedDescription ?? "connexion interrompue")
    }

    private func connectionLost(_ reason: String) {
        pingTimer?.invalidate()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        state = .disconnected(reason)
        scheduleRetry()
    }

    private struct Incoming: Decodable {
        let type: String
        let id: String
        let iv: String
        let data: String
        let from: String?
    }

    private struct Outgoing: Encodable {
        let type: String
        let id: String
        let iv: String
        let data: String
        let ephemeral: Bool?
    }
}

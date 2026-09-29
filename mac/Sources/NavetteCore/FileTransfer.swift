import Foundation

/// Fichiers quelconques, découpés en morceaux chiffrés un à un (messages `file`, voir « Files » dans
/// PROTOCOL.md). Chaque morceau porte son décalage : l'ordre d'arrivée n'importe pas. Après le
/// dernier, l'expéditeur envoie `file-end` ; le destinataire répond `file-ack` avec les plages
/// manquantes (morceaux perdus sur une liaison morte), que l'expéditeur renvoie. Vide = reçu.
public enum FileChunks {
    /// Wi-Fi.
    public static let chunkSize = 512 * 1024
    /// Bluetooth : une trame doit passer bien avant le délai de 40 s sans nouvelles, même en GATT (5 Ko/s).
    public static let bluetoothChunkSize = 32 * 1024
    /// Au-delà, pas de Bluetooth (environ 50 Ko/s).
    public static let maxBluetoothBytes: Int64 = 2 * 1024 * 1024
    public static let maxBytes: Int64 = 4 * 1024 * 1024 * 1024
    /// Transfert abandonné sans nouveau morceau pendant ce délai (une liaison morte met 40 s à se révéler).
    public static let staleAfter: TimeInterval = 120
    /// Plages manquantes renvoyées au plus par accusé de réception.
    static let maxMissingRanges = 1000

    /// Nom de fichier sûr : ni chemin, ni fichier caché, ni caractère de contrôle.
    public static func safeName(_ raw: String) -> String {
        let last = raw.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        var name = String(last.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.utf8.count > 200 {
            let ext = (name as NSString).pathExtension
            let base = String((name as NSString).deletingPathExtension.prefix(150))
            name = ext.isEmpty || ext.count > 20 ? base : "\(base).\(ext)"
        }
        return name.isEmpty ? "fichier" : name
    }

    /// `dossier/nom.ext`, ou `nom 2.ext`, `nom 3.ext`… si le nom est pris (comme le Finder).
    public static func uniqueURL(for name: String, in directory: URL) -> URL {
        let fm = FileManager.default
        var url = directory.appendingPathComponent(name)
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }

    /// Identifiant de transfert : court, sans caractère spécial (il nomme le fichier temporaire).
    static func validFid(_ fid: String) -> Bool {
        (8...64).contains(fid.count) && fid.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
}

/// Plages d'octets reçues, fusionnées : des morceaux de tailles différentes (le chemin, donc la taille
/// des morceaux, peut changer en cours d'envoi) qui se chevauchent ne sont comptés qu'une fois.
struct Coverage {
    /// Triées, disjointes, [début, fin).
    private(set) var ranges: [(start: Int64, end: Int64)] = []
    private(set) var total: Int64 = 0

    /// Ajoute [start, end) ; renvoie le nombre d'octets nouveaux.
    @discardableResult
    mutating func add(_ start: Int64, _ end: Int64) -> Int64 {
        guard end > start else { return 0 }
        var merged: [(start: Int64, end: Int64)] = []
        var lower = start, upper = end, overlap: Int64 = 0
        var placed = false
        for range in ranges {
            if range.end < lower {
                merged.append(range)
            } else if range.start > upper {
                if !placed { merged.append((lower, upper)); placed = true }
                merged.append(range)
            } else { // chevauche ou touche
                overlap += max(0, min(range.end, end) - max(range.start, start))
                lower = min(lower, range.start)
                upper = max(upper, range.end)
            }
        }
        if !placed { merged.append((lower, upper)) }
        ranges = merged
        let added = (end - start) - overlap
        total += added
        return added
    }

    /// Plages [début, fin) manquantes dans [0, size).
    func missing(size: Int64) -> [[Int64]] {
        var gaps: [[Int64]] = []
        var cursor: Int64 = 0
        for range in ranges {
            if range.start > cursor { gaps.append([cursor, range.start]) }
            cursor = max(cursor, range.end)
        }
        if cursor < size { gaps.append([cursor, size]) }
        return gaps
    }
}

/// Ce que `FileSender` fait partir : un message JSON (`file-end`, `file-cancel`) ou un morceau binaire.
public enum FileOutgoing {
    case message(NavetteCrypto.Clip)
    case chunk(NavetteCrypto.Chunk)
}

/// Réassemble les fichiers reçus dans un dossier temporaire. Tout sur la file principale.
public final class FileAssembler {
    public enum Event: Equatable {
        case progress(fid: String, name: String, received: Int64, size: Int64)
        /// `url` : fichier complet, encore dans le dossier temporaire (à déplacer).
        case completed(fid: String, name: String, url: URL)
        case failed(fid: String, name: String, reason: String)
    }

    /// Réponse à l'expéditeur (`file-ack`, `file-cancel`), à chiffrer et envoyer.
    public var reply: (([String: Any]) -> Void)?

    private final class Incoming {
        let name: String
        let size: Int64
        let url: URL
        let handle: FileHandle
        var coverage = Coverage()
        /// Pour un fichier vide : son unique morceau (vide) est arrivé.
        var sawEmpty = false
        var received: Int64 { coverage.total }
        var lastChunk = Date()

        init(name: String, size: Int64, url: URL, handle: FileHandle) {
            self.name = name
            self.size = size
            self.url = url
            self.handle = handle
        }

        /// Plages [début, fin) pas encore reçues.
        var missing: [[Int64]] {
            if size == 0 { return sawEmpty ? [] : [[0, 0]] }
            return Array(coverage.missing(size: size).prefix(FileChunks.maxMissingRanges))
        }
    }

    private let directory: URL
    private var incoming: [String: Incoming] = [:]
    /// Transferts finis (true) ou abandonnés (false) : un morceau en retard ne rouvre rien, et un
    /// `file-end` répété reçoit la même réponse.
    private var closed: [String: Bool] = [:]
    public static let maxConcurrent = 4

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public var isReceiving: Bool { !incoming.isEmpty }

    /// Message `file`, `file-end` ou `file-cancel` déjà déchiffré (`data` : octets bruts d'un morceau
    /// binaire, ou base64). nil si rien à signaler.
    public func accept(_ json: [String: Any]) -> Event? {
        guard let fid = json["fid"] as? String, FileChunks.validFid(fid) else { return nil }
        switch json["kind"] as? String {
        case "file-cancel":
            guard let transfer = incoming[fid] else { return nil }
            finish(fid, completed: false)
            return .failed(fid: fid, name: transfer.name, reason: "annulé par l’expéditeur")
        case "file-end":
            let n = json["n"] as? NSNumber // renvoyé tel quel : l'expéditeur ignore les réponses périmées
            if let done = closed[fid] {
                reply?(done ? Self.ack(fid, [], n: n) : Self.cancel(fid))
            } else if let transfer = incoming[fid] {
                transfer.lastChunk = Date()
                reply?(Self.ack(fid, transfer.missing, n: n))
            } else if let size = (json["size"] as? NSNumber)?.int64Value, (0...FileChunks.maxBytes).contains(size) {
                reply?(Self.ack(fid, [[0, size]], n: n)) // aucun morceau arrivé
            }
            return nil
        case "file":
            return chunk(fid, json)
        default:
            return nil
        }
    }

    private func chunk(_ fid: String, _ json: [String: Any]) -> Event? {
        guard closed[fid] == nil else { return nil }
        guard let size = (json["size"] as? NSNumber)?.int64Value, (0...FileChunks.maxBytes).contains(size),
              let offset = (json["off"] as? NSNumber)?.int64Value, offset >= 0,
              let data = (json["data"] as? Data) ?? (json["data"] as? String).flatMap({ Data(base64Encoded: $0) }),
              offset + Int64(data.count) <= size
        else { return fail(fid, "morceau invalide") }
        let name = FileChunks.safeName(json["name"] as? String ?? "")

        let transfer: Incoming
        if let existing = incoming[fid] {
            guard existing.size == size else { return fail(fid, "taille incohérente") }
            transfer = existing
        } else {
            guard incoming.count < Self.maxConcurrent else { return nil }
            let url = directory.appendingPathComponent("\(fid).part")
            guard FileManager.default.createFile(atPath: url.path, contents: nil),
                  let handle = try? FileHandle(forWritingTo: url) else {
                closed[fid] = false
                reply?(Self.cancel(fid))
                return .failed(fid: fid, name: name, reason: "écriture impossible")
            }
            transfer = Incoming(name: name, size: size, url: url, handle: handle)
            incoming[fid] = transfer
        }
        transfer.lastChunk = Date()
        do {
            try transfer.handle.seek(toOffset: UInt64(offset))
            try transfer.handle.write(contentsOf: data) // un chevauchement réécrit les mêmes octets
        } catch {
            return fail(fid, "disque plein ?")
        }
        let added = transfer.coverage.add(offset, offset + Int64(data.count))
        if size == 0 { transfer.sawEmpty = true }
        // Doublon (renvoi d'un morceau arrivé en retard) : rien de nouveau à signaler.
        guard added > 0 || size == 0 else { return nil }
        guard transfer.received >= size else {
            return .progress(fid: fid, name: transfer.name, received: transfer.received, size: size)
        }
        finish(fid, completed: true)
        reply?(Self.ack(fid, []))
        return .completed(fid: fid, name: transfer.name, url: transfer.url)
    }

    /// Transferts sans nouvelles depuis `FileChunks.staleAfter` (expéditeur parti, liaison coupée).
    public func expire(now: Date = Date()) -> [Event] {
        incoming.filter { now.timeIntervalSince($0.value.lastChunk) > FileChunks.staleAfter }.map { fid, transfer in
            finish(fid, completed: false)
            reply?(Self.cancel(fid))
            return .failed(fid: fid, name: transfer.name, reason: "interrompu")
        }
    }

    private func fail(_ fid: String, _ reason: String) -> Event? {
        guard let transfer = incoming[fid] else { return nil }
        finish(fid, completed: false)
        reply?(Self.cancel(fid))
        return .failed(fid: fid, name: transfer.name, reason: reason)
    }

    private func finish(_ fid: String, completed: Bool) {
        guard let transfer = incoming.removeValue(forKey: fid) else { return }
        closed[fid] = completed
        try? transfer.handle.close()
        if !completed { try? FileManager.default.removeItem(at: transfer.url) }
    }

    static func ack(_ fid: String, _ missing: [[Int64]], n: NSNumber? = nil) -> [String: Any] {
        var ack: [String: Any] = ["kind": "file-ack", "fid": fid, "missing": missing]
        if let n { ack["n"] = n }
        return ack
    }

    static func cancel(_ fid: String) -> [String: Any] {
        ["kind": "file-cancel", "fid": fid]
    }
}

/// Envoie un fichier morceau par morceau : le suivant part quand le précédent est parti (pas de
/// file d'attente de plusieurs Go en mémoire), puis attend l'accusé de réception et renvoie ce qui
/// manque. Lecture et chiffrement hors de la file principale ; tout le reste sur la file principale.
public final class FileSender {
    public let fid = UUID().uuidString.lowercased()
    public let name: String
    public let size: Int64
    /// Octets partis (renvois compris, plafonné à la taille).
    public private(set) var sent: Int64 = 0
    public var onProgress: (() -> Void)?
    /// nil si le destinataire a tout reçu, sinon la raison.
    public var onFinish: ((String?) -> Void)?

    /// Délais (réglables pour les tests).
    public var ackTimeout: TimeInterval = 20
    public var retryDelay: TimeInterval = 2
    static let maxEndAttempts = 4
    static let maxRounds = 10
    static let maxRetries = 20
    /// Morceaux en vol au plus (préparés ou en cours d'envoi).
    public var window = 4
    private var inFlight = 0

    private let url: URL
    private let mime: String?
    /// Taille des morceaux selon le chemin du moment ; nil = aucun chemin (on réessaie un moment).
    private let chunkSize: () -> Int?
    private let seal: ([String: Any]) -> NavetteCrypto.Clip?
    private let sealChunk: ([String: Any], Data) -> NavetteCrypto.Chunk?
    private let transmit: (FileOutgoing, @escaping (Bool) -> Void) -> Void
    private let work = DispatchQueue(label: "navette.fichier")
    private var handle: FileHandle?
    /// Plages [début, fin) restant à envoyer.
    private var ranges: [(start: Int64, end: Int64)]
    private var rounds = 0
    private var retries = 0
    private var endAttempts = 0
    private var ackTimer: DispatchWorkItem?
    private var cancelled = false
    private var done = false

    /// `seal` chiffre un message, `sealChunk` un morceau (métadonnées + octets) ; `transmit` l'envoie
    /// et rappelle avec le résultat.
    public init?(url: URL, name: String? = nil, mime: String? = nil, chunkSize: @escaping () -> Int?,
                 seal: @escaping ([String: Any]) -> NavetteCrypto.Clip?,
                 sealChunk: @escaping ([String: Any], Data) -> NavetteCrypto.Chunk?,
                 transmit: @escaping (FileOutgoing, @escaping (Bool) -> Void) -> Void) {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              Int64(size) <= FileChunks.maxBytes,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        self.url = url
        self.name = FileChunks.safeName(name ?? url.lastPathComponent)
        self.size = Int64(size)
        self.mime = mime
        self.chunkSize = chunkSize
        self.seal = seal
        self.sealChunk = sealChunk
        self.transmit = transmit
        self.handle = handle
        ranges = [(0, Int64(size))]
    }

    public func start() { next() }

    public func cancel() {
        guard !done else { return }
        cancelled = true
        control(["kind": "file-cancel", "fid": fid])
        finish("annulé")
    }

    /// `file-ack` ou `file-cancel` du destinataire.
    public func handle(_ json: [String: Any]) {
        guard !done, json["fid"] as? String == fid else { return }
        if json["kind"] as? String == "file-cancel" { return finish("refusé par le destinataire") }
        guard json["kind"] as? String == "file-ack", let missing = json["missing"] as? [[NSNumber]] else { return }
        let wanted = missing.compactMap { pair -> (Int64, Int64)? in
            guard pair.count == 2 else { return nil }
            let start = pair[0].int64Value, end = pair[1].int64Value
            return start >= 0 && start <= end && end <= size ? (start, end) : nil
        }
        if missing.isEmpty { return finish(nil) }
        guard !wanted.isEmpty else { return }
        // Réponse à un `file-end` précédent (des morceaux étaient encore en route) : on attend la suivante.
        if let n = json["n"] as? NSNumber, n.intValue != endAttempts + rounds * 100 { return }
        guard ranges.isEmpty, inFlight == 0 else { return } // renvoi déjà en cours : le prochain `file-end` fera le point
        ackTimer?.cancel()
        ackTimer = nil
        rounds += 1
        guard rounds <= Self.maxRounds else { return finish("trop de morceaux perdus") }
        ranges = wanted.map { (start: $0.0, end: $0.1) }
        endAttempts = 0
        next()
    }

    /// Réserve le morceau suivant et le prépare, tant que la fenêtre n'est pas pleine : quelques
    /// morceaux en vol gardent le tuyau plein (sinon il se vide entre deux morceaux, et le débit tombe
    /// à un morceau par aller-retour).
    private func next() {
        guard !done, !cancelled, let handle else { return }
        guard var range = ranges.first else {
            if inFlight == 0 { sendEnd() }
            return
        }
        guard inFlight < window else { return }
        guard let piece = chunkSize() else {
            if inFlight == 0 { linkDown { self.next() } } // sinon, le prochain morceau fini relancera
            return
        }
        let offset = range.start
        let count = Int(min(Int64(piece), range.end - range.start))
        range.start += Int64(count)
        if range.start >= range.end { ranges.removeFirst() } else { ranges[0] = range }
        inFlight += 1
        work.async { [self] in
            let data: Data
            do {
                try handle.seek(toOffset: UInt64(offset))
                data = count > 0 ? (try handle.read(upToCount: count) ?? Data()) : Data()
            } catch {
                return DispatchQueue.main.async { self.finish("lecture impossible") }
            }
            if data.count < count {
                return DispatchQueue.main.async { self.finish("fichier modifié pendant l’envoi") }
            }
            var meta: [String: Any] = ["kind": "file", "fid": fid, "name": name, "size": size, "off": offset]
            if let mime { meta["mime"] = mime }
            let chunk = sealChunk(meta, data)
            DispatchQueue.main.async { self.send(chunk, length: data.count) }
        }
        next()
    }

    private func send(_ chunk: NavetteCrypto.Chunk?, length: Int) {
        guard !done, !cancelled else { return }
        guard let chunk else { return finish("chiffrement impossible") }
        transmit(.chunk(chunk)) { ok in
            guard !self.done, !self.cancelled else { return }
            guard ok else { return self.linkDown { self.send(chunk, length: length) } }
            self.retries = 0
            self.inFlight -= 1
            self.sent = min(self.size, self.sent + Int64(length))
            self.onProgress?()
            self.next()
        }
    }

    /// Liaison qui change (Wi-Fi perdu, Bluetooth en cours de connexion) : on réessaie un moment.
    private func linkDown(_ again: @escaping () -> Void) {
        retries += 1
        guard retries <= Self.maxRetries else { return finish("liaison perdue") }
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
            guard let self, !self.done, !self.cancelled else { return }
            again()
        }
    }

    /// Tout est parti : on demande au destinataire ce qui lui manque.
    private func sendEnd() {
        guard !done else { return }
        endAttempts += 1
        guard endAttempts <= Self.maxEndAttempts else { return finish("pas de confirmation du destinataire") }
        control(["kind": "file-end", "fid": fid, "name": name, "size": size, "n": endAttempts + rounds * 100])
        let timer = DispatchWorkItem { [weak self] in self?.sendEnd() }
        ackTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + ackTimeout, execute: timer)
    }

    private func control(_ message: [String: Any]) {
        if let clip = seal(message) { transmit(.message(clip)) { _ in } }
    }

    private func finish(_ error: String?) {
        guard !done else { return }
        done = true
        ackTimer?.cancel()
        if let handle { work.async { try? handle.close() } } // après une éventuelle lecture en cours
        handle = nil
        onFinish?(error)
    }
}

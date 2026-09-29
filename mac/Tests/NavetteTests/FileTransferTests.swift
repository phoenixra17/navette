import XCTest
@testable import NavetteCore

final class FileTransferTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("navette-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Ce que reçoit le téléphone : message JSON, ou morceau binaire passé par une trame (comme sur
    /// une liaison directe) puis déchiffré.
    static func decode(_ outgoing: FileOutgoing, _ keys: NavetteCrypto.Keys) -> [String: Any] {
        switch outgoing {
        case .message(let clip):
            return try! NavetteCrypto.openJSON(clip, key: keys.encKey, from: .phone)
        case .chunk(let chunk):
            var parser = LinkWire.Parser()
            parser.limit = LinkWire.maxFrame
            let received = try! parser.append(LinkWire.encode(chunk)!)[0]["chunk"] as! NavetteCrypto.Chunk
            XCTAssertEqual(received, chunk)
            let (meta, bytes) = try! NavetteCrypto.openChunk(received, key: keys.encKey, from: .phone)
            return meta.merging(["data": bytes]) { $1 }
        }
    }

    /// Vecteur de référence, commun aux apps Mac et Android.
    func testOpensReferenceChunk() throws {
        let keys = try NavetteCrypto.deriveKeys(secret: "q3l2m9d1Xv0kPZ3n4wYtR8sE5uA7bC6fGhJiKlMnOpQ")
        let chunk = NavetteCrypto.Chunk(
            id: "vecteur-binaire", iv: Data([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]),
            box: try XCTUnwrap(Data(base64Encoded: "kPxGVlEPxme7U89aWoEcmUdfL9BccFQahZXH+HfoapHETk8wLVAPesK5TCgqXULFMxJkk/Oxn7IRB5N+ogyXCpFOKClRbexALD6GvtSAuyGWsKoUyN+uFllGlPxBia1Sr3Cl+J61sVxh+xcvfWNkQPtoblc=")))
        let (meta, bytes) = try NavetteCrypto.openChunk(chunk, key: keys.encKey, from: .phone)
        XCTAssertEqual(meta["name"] as? String, "é.bin")
        XCTAssertEqual((meta["t"] as? NSNumber)?.int64Value, 1_790_000_000_000)
        XCTAssertEqual(bytes, Data([0, 1, 2, 250, 251, 255]))
        XCTAssertThrowsError(try NavetteCrypto.openChunk(chunk, key: keys.encKey, from: .mac))
        // Un morceau binaire ne se lit pas comme un élément JSON.
        XCTAssertThrowsError(try NavetteCrypto.openData(chunk.clip, key: keys.encKey, from: .phone))
        XCTAssertEqual(NavetteCrypto.Chunk(clip: chunk.clip), chunk)
    }

    func testBinaryFramesMixWithJSON() throws {
        let chunk = NavetteCrypto.Chunk(id: "abc", iv: Data(repeating: 7, count: 12), box: Data((0..<3000).map { UInt8($0 % 256) }))
        var stream = LinkWire.encode(["type": "ping"])!
        stream += LinkWire.encode(chunk)!
        stream += LinkWire.encode(["type": "pong"])!
        var parser = LinkWire.Parser()
        parser.limit = LinkWire.maxFrame
        var messages: [[String: Any]] = []
        for start in stride(from: 0, to: stream.count, by: 100) { // arrivée par petits morceaux, comme en BLE
            messages += try parser.append(stream.subdata(in: start ..< min(start + 100, stream.count)))
        }
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages[0]["type"] as? String, "ping")
        XCTAssertEqual(messages[1]["chunk"] as? NavetteCrypto.Chunk, chunk)
        XCTAssertEqual(messages[2]["type"] as? String, "pong")
    }

    func testCoverageMergesOverlaps() {
        var coverage = Coverage()
        XCTAssertEqual(coverage.add(0, 512), 512)
        XCTAssertEqual(coverage.add(32, 64), 0) // déjà couvert
        XCTAssertEqual(coverage.add(1000, 1032), 32)
        XCTAssertEqual(coverage.add(500, 1010), 488) // comble le trou [512, 1000)
        XCTAssertEqual(coverage.total, 1032)
        XCTAssertEqual(coverage.missing(size: 1100), [[1032, 1100]])
    }

    /// Chemin qui change en route : un renvoi en petits morceaux croise un gros morceau arrivé en retard.
    /// Le fichier n'est terminé que quand tous les octets sont là.
    func testMixedChunkSizesNeverCompleteEarly() {
        let assembler = FileAssembler(directory: dir)
        let fid = "0123456789abcdef"
        let bytes = (0..<8).map { UInt8($0) }
        _ = assembler.accept(chunk(fid, Array(bytes[0..<4]), off: 0, size: 8)) // gros morceau [0, 4)
        _ = assembler.accept(chunk(fid, Array(bytes[2..<4]), off: 2, size: 8)) // petit renvoi, déjà couvert
        XCTAssertEqual(assembler.accept(chunk(fid, Array(bytes[4..<6]), off: 4, size: 8)),
                       .progress(fid: fid, name: "doc.bin", received: 6, size: 8))
        guard case .completed(_, _, let url) = assembler.accept(chunk(fid, Array(bytes[4..<8]), off: 4, size: 8)) else {
            return XCTFail("fichier non terminé")
        }
        XCTAssertEqual(try Data(contentsOf: url), Data(bytes))
    }

    func testSafeName() {
        XCTAssertEqual(FileChunks.safeName("../../etc/passwd"), "passwd")
        XCTAssertEqual(FileChunks.safeName(".bashrc"), "bashrc")
        XCTAssertEqual(FileChunks.safeName("a\u{0}b:c.pdf"), "ab-c.pdf")
        XCTAssertEqual(FileChunks.safeName(""), "fichier")
        XCTAssertEqual(FileChunks.safeName("C:\\Users\\x\\photo.jpg"), "photo.jpg")
        let long = FileChunks.safeName(String(repeating: "é", count: 300) + ".mp4")
        XCTAssertTrue(long.hasSuffix(".mp4"))
        XCTAssertLessThanOrEqual(long.count, 160)
    }

    func testUniqueURL() throws {
        try Data().write(to: dir.appendingPathComponent("a.txt"))
        try Data().write(to: dir.appendingPathComponent("a 2.txt"))
        XCTAssertEqual(FileChunks.uniqueURL(for: "a.txt", in: dir).lastPathComponent, "a 3.txt")
        XCTAssertEqual(FileChunks.uniqueURL(for: "b", in: dir).lastPathComponent, "b")
    }

    private func chunk(_ fid: String, _ bytes: [UInt8], off: Int, size: Int, name: String = "doc.bin") -> [String: Any] {
        ["kind": "file", "fid": fid, "name": name, "size": size, "off": off, "data": Data(bytes).base64EncodedString()]
    }

    func testAssemblesOutOfOrderAndIgnoresDuplicates() throws {
        let assembler = FileAssembler(directory: dir)
        let fid = "0123456789abcdef"
        XCTAssertEqual(assembler.accept(chunk(fid, [4, 5], off: 4, size: 6)),
                       .progress(fid: fid, name: "doc.bin", received: 2, size: 6))
        XCTAssertNil(assembler.accept(chunk(fid, [4, 5], off: 4, size: 6))) // doublon
        _ = assembler.accept(chunk(fid, [0, 1], off: 0, size: 6))
        guard case .completed(_, let name, let url) = assembler.accept(chunk(fid, [2, 3], off: 2, size: 6)) else {
            return XCTFail("fichier non terminé")
        }
        XCTAssertEqual(name, "doc.bin")
        XCTAssertEqual(try Data(contentsOf: url), Data([0, 1, 2, 3, 4, 5]))
        XCTAssertNil(assembler.accept(chunk(fid, [0, 1], off: 0, size: 6))) // en retard : ne rouvre rien
        XCTAssertFalse(assembler.isReceiving)
    }

    func testEmptyFile() {
        let assembler = FileAssembler(directory: dir)
        guard case .completed(_, _, let url) = assembler.accept(chunk("vide-0123456789", [], off: 0, size: 0)) else {
            return XCTFail("fichier vide non terminé")
        }
        XCTAssertEqual(try Data(contentsOf: url), Data())
    }

    func testRejectsBadChunksAndCancels() {
        let assembler = FileAssembler(directory: dir)
        XCTAssertNil(assembler.accept(chunk("../evil-name", [1], off: 0, size: 1)))
        let fid = "abcdef0123456789"
        _ = assembler.accept(chunk(fid, [1], off: 0, size: 3))
        // Déborde de la taille annoncée : le transfert est abandonné et son fichier supprimé.
        XCTAssertEqual(assembler.accept(chunk(fid, [1, 2, 3], off: 1, size: 3)),
                       .failed(fid: fid, name: "doc.bin", reason: "morceau invalide"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])

        let other = "fedcba9876543210"
        _ = assembler.accept(chunk(other, [1], off: 0, size: 3))
        XCTAssertEqual(assembler.accept(["kind": "file-cancel", "fid": other]),
                       .failed(fid: other, name: "doc.bin", reason: "annulé par l’expéditeur"))
        XCTAssertEqual(assembler.expire(now: Date().addingTimeInterval(3600)), [])
    }

    func testExpiresStaleTransfers() {
        let assembler = FileAssembler(directory: dir)
        let fid = "stale-0123456789"
        _ = assembler.accept(chunk(fid, [1], off: 0, size: 2))
        XCTAssertEqual(assembler.expire(), [])
        XCTAssertEqual(assembler.expire(now: Date().addingTimeInterval(FileChunks.staleAfter + 1)),
                       [.failed(fid: fid, name: "doc.bin", reason: "interrompu")])
    }

    func testAcknowledgesWithMissingRanges() {
        let assembler = FileAssembler(directory: dir)
        var replies: [[String: Any]] = []
        assembler.reply = { replies.append($0) }
        let fid = "0123456789abcdef"
        // Rien reçu : tout manque.
        _ = assembler.accept(["kind": "file-end", "fid": fid, "size": 6])
        XCTAssertEqual(replies.last?["missing"] as? [[Int64]], [[0, 6]])
        _ = assembler.accept(chunk(fid, [2, 3], off: 2, size: 6))
        _ = assembler.accept(["kind": "file-end", "fid": fid, "size": 6])
        XCTAssertEqual(replies.last?["missing"] as? [[Int64]], [[0, 2], [4, 6]])
        _ = assembler.accept(chunk(fid, [0, 1], off: 0, size: 6))
        _ = assembler.accept(chunk(fid, [4, 5], off: 4, size: 6))
        XCTAssertEqual(replies.last?["missing"] as? [[Int64]], []) // terminé : accusé spontané
        _ = assembler.accept(["kind": "file-end", "fid": fid, "size": 6])
        XCTAssertEqual(replies.last?["missing"] as? [[Int64]], []) // accusé perdu : même réponse
        XCTAssertEqual(replies.count, 4)
    }

    /// Liaison qui perd des morceaux sans le dire (TCP mort pas encore détecté) : l'accusé de
    /// réception les fait renvoyer.
    func testResendsLostChunks() throws {
        let keys = try NavetteCrypto.deriveKeys(secret: NavetteCrypto.newSecret())
        let source = dir.appendingPathComponent("source.dat")
        let bytes = (0..<20_000).map { UInt8($0 % 249) }
        try Data(bytes).write(to: source)
        let assembler = FileAssembler(directory: dir.appendingPathComponent("reception"))
        var sender: FileSender!
        var result: URL?
        var dropped = 0
        assembler.reply = { reply in
            // Le destinataire répond par la même liaison chiffrée.
            let clip = try! NavetteCrypto.seal(json: reply, key: keys.encKey, as: .mac)
            DispatchQueue.main.async { sender.handle(try! NavetteCrypto.openJSON(clip, key: keys.encKey, from: .mac)) }
        }
        let finished = expectation(description: "envoi confirmé")
        sender = try XCTUnwrap(FileSender(
            url: source, chunkSize: { 4096 },
            seal: { try? NavetteCrypto.seal(json: $0, key: keys.encKey, as: .phone) },
            sealChunk: { try? NavetteCrypto.sealChunk(meta: $0, bytes: $1, key: keys.encKey, as: .phone) },
            transmit: { outgoing, done in
                let json = Self.decode(outgoing, keys)
                // Les deux premiers morceaux « partent » mais n'arrivent jamais.
                if json["kind"] as? String == "file", dropped < 2 {
                    dropped += 1
                    return done(true)
                }
                if case .completed(_, _, let url) = assembler.accept(json) { result = url }
                done(true)
            }))
        sender.onFinish = { error in
            XCTAssertNil(error)
            finished.fulfill()
        }
        sender.start()
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(dropped, 2)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result)), Data(bytes))
    }

    /// Plus de chemin un moment (Wi-Fi perdu, Bluetooth pas encore connecté), puis un autre, avec
    /// des morceaux plus petits : l'envoi reprend et aboutit.
    func testRouteChangesDuringSend() throws {
        let keys = try NavetteCrypto.deriveKeys(secret: NavetteCrypto.newSecret())
        let source = dir.appendingPathComponent("source.dat")
        let bytes = (0..<20_000).map { UInt8($0 % 247) }
        try Data(bytes).write(to: source)
        let assembler = FileAssembler(directory: dir.appendingPathComponent("reception"))
        var sender: FileSender!
        var result: URL?
        var calls = 0
        var sizes: [Int] = []
        assembler.reply = { reply in DispatchQueue.main.async { sender.handle(reply) } }
        let finished = expectation(description: "envoi confirmé")
        sender = try XCTUnwrap(FileSender(
            url: source,
            chunkSize: {
                calls += 1
                switch calls {
                case 1: return 8192
                case 2, 3: return nil // aucun chemin
                default: return 1024
                }
            },
            seal: { try? NavetteCrypto.seal(json: $0, key: keys.encKey, as: .phone) },
            sealChunk: { try? NavetteCrypto.sealChunk(meta: $0, bytes: $1, key: keys.encKey, as: .phone) },
            transmit: { outgoing, done in
                let json = Self.decode(outgoing, keys)
                if let data = json["data"] as? Data { sizes.append(data.count) }
                if case .completed(_, _, let url) = assembler.accept(json) { result = url }
                done(true)
            }))
        sender.retryDelay = 0.01
        sender.onFinish = { error in
            XCTAssertNil(error)
            finished.fulfill()
        }
        sender.start()
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(sizes.first, 8192)
        XCTAssertEqual(sizes.dropFirst().max(), 1024)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result)), Data(bytes))
    }

    func testGivesUpWithoutAcknowledgment() throws {
        let source = dir.appendingPathComponent("source.dat")
        try Data(count: 100).write(to: source)
        let finished = expectation(description: "échec signalé")
        let sender = try XCTUnwrap(FileSender(
            url: source, chunkSize: { 4096 },
            seal: { _ in NavetteCrypto.Clip(id: "x", iv: "", data: "") },
            sealChunk: { _, _ in NavetteCrypto.Chunk(id: "x", iv: Data(), box: Data()) },
            transmit: { _, done in done(true) }))
        sender.ackTimeout = 0.05
        sender.onFinish = { error in
            XCTAssertEqual(error, "pas de confirmation du destinataire")
            finished.fulfill()
        }
        sender.start()
        wait(for: [finished], timeout: 5)
    }

    /// Envoi chiffré de bout en bout, morceau par morceau, puis réassemblage côté réception.
    func testSenderToAssembler() throws {
        let keys = try NavetteCrypto.deriveKeys(secret: NavetteCrypto.newSecret())
        let source = dir.appendingPathComponent("source.dat")
        let bytes = (0..<10_000).map { UInt8($0 % 251) }
        try Data(bytes).write(to: source)
        let assembler = FileAssembler(directory: dir.appendingPathComponent("reception"))
        var result: URL?
        var chunks = 0
        var sender: FileSender!
        assembler.reply = { reply in DispatchQueue.main.async { sender.handle(reply) } }
        let finished = expectation(description: "envoi terminé")
        sender = try XCTUnwrap(FileSender(
            url: source, name: "photo.jpg", mime: "image/jpeg", chunkSize: { 4096 },
            seal: { try? NavetteCrypto.seal(json: $0, key: keys.encKey, as: .phone) },
            sealChunk: { try? NavetteCrypto.sealChunk(meta: $0, bytes: $1, key: keys.encKey, as: .phone) },
            transmit: { outgoing, done in
                let json = Self.decode(outgoing, keys)
                if json["kind"] as? String == "file" {
                    chunks += 1
                    XCTAssertEqual(json["mime"] as? String, "image/jpeg")
                }
                if case .completed(_, _, let url) = assembler.accept(json) { result = url }
                done(true)
            }))
        sender.onFinish = { error in
            XCTAssertNil(error)
            finished.fulfill()
        }
        sender.start()
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(chunks, 3)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result)), Data(bytes))
    }

    func testSenderStopsWhenLinkFails() throws {
        let source = dir.appendingPathComponent("source.dat")
        try Data(count: 10_000).write(to: source)
        let finished = expectation(description: "échec signalé")
        let sender = try XCTUnwrap(FileSender(
            url: source, chunkSize: { 4096 },
            seal: { _ in NavetteCrypto.Clip(id: "x", iv: "", data: "") },
            sealChunk: { _, _ in NavetteCrypto.Chunk(id: "x", iv: Data(), box: Data()) },
            transmit: { _, done in done(false) }))
        sender.retryDelay = 0.01
        sender.onFinish = { error in
            XCTAssertEqual(error, "liaison perdue")
            finished.fulfill()
        }
        sender.start()
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(sender.sent, 0)
    }
}

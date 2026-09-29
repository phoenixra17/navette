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
            url: source, chunkSize: 4096,
            seal: { try? NavetteCrypto.seal(json: $0, key: keys.encKey, as: .phone) },
            transmit: { clip, done in
                let json = try! NavetteCrypto.openJSON(clip, key: keys.encKey, from: .phone)
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

    func testGivesUpWithoutAcknowledgment() throws {
        let source = dir.appendingPathComponent("source.dat")
        try Data(count: 100).write(to: source)
        let finished = expectation(description: "échec signalé")
        let sender = try XCTUnwrap(FileSender(
            url: source, chunkSize: 4096,
            seal: { _ in NavetteCrypto.Clip(id: "x", iv: "", data: "") },
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
            url: source, name: "photo.jpg", mime: "image/jpeg", chunkSize: 4096,
            seal: { try? NavetteCrypto.seal(json: $0, key: keys.encKey, as: .phone) },
            transmit: { clip, done in
                let json = try! NavetteCrypto.openJSON(clip, key: keys.encKey, from: .phone)
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
            url: source, chunkSize: 4096,
            seal: { _ in NavetteCrypto.Clip(id: "x", iv: "", data: "") },
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

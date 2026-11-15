import Foundation
import Network
import CryptoKit

/// Frame types. See PROTOCOL.md.
enum Frame {
    static let json: UInt8 = 1
    static let screen: UInt8 = 2
    static let camera: UInt8 = 3
    static let file: UInt8 = 4
    static let thumb: UInt8 = 5
    static let icon: UInt8 = 6
}

/// Encrypted, framed channel over one TCP connection. The Mac is always the server.
///
/// Handshake (plaintext): "AMAC" + version(1) + 16-byte salt, in each direction.
/// Session keys: HKDF(pairing key, clientSalt + serverSalt, direction label).
/// Frames: u32 length, then AES-256-GCM(type byte + payload) with a counter nonce.
/// Every method must be called on `queue`.
final class SecureChannel {
    private let conn: NWConnection
    private let psk: Data
    private let queue: DispatchQueue
    private var sendKey: SymmetricKey?
    private var recvKey: SymmetricKey?
    private var sendCtr: UInt64 = 0
    private var recvCtr: UInt64 = 0
    private var closed = false

    var onFrame: ((UInt8, Data) -> Void)?
    var onClose: (() -> Void)?

    init(conn: NWConnection, psk: Data, queue: DispatchQueue) {
        self.conn = conn
        self.psk = psk
        self.queue = queue
    }

    func start() {
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready: self.readHello()
            case .failed, .cancelled: self.finish()
            default: break
            }
        }
        conn.start(queue: queue)
        // Drop connections that never complete the handshake.
        queue.asyncAfter(deadline: .now() + 5) { if self.recvKey == nil { self.close() } }
    }

    func close() {
        if closed { return }
        conn.cancel()
        finish()
    }

    private func finish() {
        if closed { return }
        closed = true
        let cb = onClose
        onClose = nil
        onFrame = nil
        conn.stateUpdateHandler = nil
        cb?()
    }

    private func read(_ n: Int, _ then: @escaping (Data) -> Void) {
        conn.receive(minimumIncompleteLength: n, maximumLength: n) { data, _, _, error in
            guard let data, data.count == n, error == nil, !self.closed else { self.close(); return }
            then(Data(data))
        }
    }

    private func readHello() {
        read(21) { d in
            let b = [UInt8](d)
            guard Array(b[0..<4]) == Array("AMAC".utf8), b[4] == 1 else { self.close(); return }
            let clientSalt = Data(b[5..<21])
            let serverSalt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
            var hello = Data("AMAC".utf8)
            hello.append(1)
            hello.append(serverSalt)
            self.conn.send(content: hello, completion: .contentProcessed { _ in })
            let salt = clientSalt + serverSalt
            self.recvKey = self.derive(salt, "andromac v1 c2s")
            self.sendKey = self.derive(salt, "andromac v1 s2c")
            self.readFrame()
        }
    }

    private func derive(_ salt: Data, _ info: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: psk), salt: salt,
                               info: Data(info.utf8), outputByteCount: 32)
    }

    private func nonce(_ counter: UInt64) -> AES.GCM.Nonce {
        var d = Data(repeating: 0, count: 4)
        withUnsafeBytes(of: counter.bigEndian) { d.append(contentsOf: $0) }
        return try! AES.GCM.Nonce(data: d)
    }

    private func readFrame() {
        read(4) { head in
            let n = Int(head.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
            guard n >= 17, n <= 8 * 1024 * 1024 else { self.close(); return }
            self.read(n) { body in
                guard let key = self.recvKey,
                      let box = try? AES.GCM.SealedBox(nonce: self.nonce(self.recvCtr),
                                                       ciphertext: body.prefix(n - 16), tag: body.suffix(16)),
                      let plain = try? AES.GCM.open(box, using: key), let type = plain.first
                else { self.close(); return } // wrong key or tampering
                self.recvCtr += 1
                self.onFrame?(type, Data(plain.dropFirst()))
                self.readFrame()
            }
        }
    }

    func send(_ type: UInt8, _ payload: Data, done: (() -> Void)? = nil) {
        guard let key = sendKey, !closed else { done?(); return }
        var plain = Data([type])
        plain.append(payload)
        guard let box = try? AES.GCM.seal(plain, using: key, nonce: nonce(sendCtr)) else { done?(); return }
        sendCtr += 1
        let length = UInt32(box.ciphertext.count + box.tag.count)
        var frame = Data()
        withUnsafeBytes(of: length.bigEndian) { frame.append(contentsOf: $0) }
        frame.append(box.ciphertext)
        frame.append(box.tag)
        conn.send(content: frame, completion: .contentProcessed { _ in done?() })
    }
}

/// Stores the pairing key in a file only this user can read
/// (~/Library/Application Support/AndroMac/pairing-key, mode 0600).
///
/// Not the login keychain: this app is ad-hoc signed, so every rebuild counts as a different app there.
/// macOS then blocks launch on a password prompt, and a denied prompt would silently replace the key
/// and break the pairing.
enum KeyStore {
    private static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AndroMac", isDirectory: true).appendingPathComponent("pairing-key")
    }

    static func load() -> Data? { try? Data(contentsOf: url) }

    static func save(_ data: Data) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        try? fm.removeItem(at: url)
        fm.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
    }
}

import Foundation
import Network
import AppKit
import UserNotifications
import SystemConfiguration

/// The name shown in Sharing settings. `Host.current()` can block for seconds on DNS lookups, so it is not used.
let macName: String = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"

struct PhoneNotif: Identifiable, Equatable {
    let id: String // Android notification key
    let app: String
    let title: String
    let text: String
    let canReply: Bool
    let date: Date
}

struct Photo: Identifiable, Equatable { let id: Int64; let name: String }
struct Contact: Identifiable { let id = UUID(); let name: String; let phones: [String] }
struct ClipEntry: Identifiable { let id = UUID(); let text: String; let fromPhone: Bool; let date = Date() }

struct SMSThread: Identifiable, Equatable, Hashable {
    let id: Int64 // Android thread id
    let address: String
    let name: String
    let snippet: String
    let date: Date
    let unread: Bool
    var title: String { name.isEmpty ? (address.isEmpty ? "Unknown" : address) : name }
}

struct SMSMessage: Identifiable, Equatable {
    let id: Int64
    let body: String
    let date: Date
    let outgoing: Bool
}

struct Transfer: Identifiable {
    let id: UUID
    let name: String
    let incoming: Bool
    var done = false
    var failed = false
    var url: URL?
}

/// Owns the listener, the single phone connection and all shared state shown in the UI.
final class Link: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = Link()

    @Published var connected = false
    @Published var phoneName = ""
    /** The phone's address on this network, used for the native screen mode. */
    @Published var phoneIP: String?
    @Published var pairURL = ""
    @Published var notifs: [PhoneNotif] = []
    @Published var clips: [ClipEntry] = []
    @Published var autoClipboard = true
    @Published var photos: [Photo] = []
    @Published var morePhotos = false
    @Published var thumbs: [Int64: NSImage] = [:]
    /** Full-size photos fetched for viewing, kept in the cache folder. */
    @Published var fullPhotos: [Int64: URL] = [:]
    @Published var contacts: [Contact] = []
    @Published var smsThreads: [SMSThread] = []
    @Published var smsMessages: [Int64: [SMSMessage]] = [:]
    /** The conversation on screen, reloaded when the phone reports a change. */
    var openThread: Int64?
    @Published var transfers: [Transfer] = []
    @Published var mirrorSize = CGSize(width: 9, height: 16)
    @Published var mirroring = false
    @Published var cameraOn = false
    @Published var accessibilityOn = false
    @Published var notificationsOn = false
    /** False when macOS is not letting this app show banners (denied, or reset after an update). */
    @Published var bannersAllowed = true
    @Published var battery: Int?
    @Published var charging = false
    /** Launchable apps as reported by the phone app, and their icons as they arrive. */
    @Published var phoneApps: [PhoneApp] = []
    @Published var appIcons: [String: NSImage] = [:]
    @Published var lastError: String?

    let screenFeed = H264Feed()
    let cameraFeed = H264Feed()

    private let queue = DispatchQueue(label: "andromac.link")
    private let fileQueue = DispatchQueue(label: "andromac.files")
    private var listener: NWListener?
    private var channel: SecureChannel?
    private var pending: [ObjectIdentifier: SecureChannel] = [:]
    private var pingTimer: DispatchSourceTimer?
    private var key: Data
    private let deviceID: String
    private var nextFileID: UInt32 = 1
    private var rx: (handle: FileHandle, url: URL, transfer: UUID?, photo: Int64?)?
    private var viewRequests = Set<Int64>() // photos asked for viewing; touched on `queue` only
    private var lastClip = ""
    private var pasteCount = NSPasteboard.general.changeCount
    private var thumbsRequested = Set<Int64>()
    private var iconsRequested = Set<String>()

    private override init() {
        let d = UserDefaults.standard
        let id = d.string(forKey: "deviceID") ?? String(UUID().uuidString.prefix(8)).lowercased()
        d.set(id, forKey: "deviceID")
        deviceID = id
        if let k = KeyStore.load(), k.count == 32 { key = k } else {
            key = Link.randomKey()
            KeyStore.save(key)
        }
        super.init()
    }

    private static func randomKey() -> Data { Data((0..<32).map { _ in UInt8.random(in: 0...255) }) }

    // MARK: lifecycle

    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in self.checkBanners() }
        let reply = UNTextInputNotificationAction(identifier: "reply", title: "Reply", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "reply", actions: [reply], intentIdentifiers: []),
            UNNotificationCategory(identifier: "plain", actions: [], intentIdentifiers: []),
        ])
        queue.async { self.listen(port: 47800) }
        Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { _ in self.pollPasteboard() }
    }

    /// New key: the phone must scan the QR code again.
    func resetPairing() {
        key = Link.randomKey()
        KeyStore.save(key)
        queue.async {
            self.channel?.close()
            self.listener?.cancel()
            self.listen(port: 47800)
        }
    }

    private func listen(port: UInt16) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params, on: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!) else {
            if port != 0 { listen(port: 0) }
            return
        }
        l.service = NWListener.Service(name: "AndroMac-\(deviceID)", type: "_andromac._tcp")
        l.newConnectionHandler = { conn in self.accept(conn) }
        l.stateUpdateHandler = { state in
            switch state {
            case .ready: self.publishPairURL(port: l.port?.rawValue ?? port)
            case .failed:
                l.cancel()
                if port != 0 { self.listen(port: 0) } // preferred port taken, let the system pick
            default: break
            }
        }
        listener = l
        l.start(queue: queue)

        pingTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 10, repeating: 10)
        t.setEventHandler { self.channel?.send(Frame.json, Data(#"{"t":"ping"}"#.utf8)) }
        t.resume()
        pingTimer = t
    }

    private func publishPairURL(port: UInt16) {
        let k = key.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let name = macName
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "Mac"
        let url = "andromac://pair?h=\(localIPv4() ?? "0.0.0.0")&p=\(port)&k=\(k)&id=\(deviceID)&n=\(name)"
        DispatchQueue.main.async { self.pairURL = url }
    }

    /// A connection only replaces the current one after it proves it holds the key (first frame decrypts).
    private func accept(_ conn: NWConnection) {
        let ch = SecureChannel(conn: conn, psk: key, queue: queue)
        let id = ObjectIdentifier(ch)
        pending[id] = ch
        ch.onFrame = { type, data in
            if self.channel !== ch {
                self.pending[id] = nil
                self.channel?.close()
                self.channel = ch
                var ip: String?
                if case let .hostPort(host, _) = conn.endpoint {
                    // Drop the interface suffix ("%en0") and the IPv4-in-IPv6 prefix.
                    ip = "\(host)".split(separator: "%").first.map { $0.replacingOccurrences(of: "::ffff:", with: "") }
                }
                DispatchQueue.main.async { self.phoneIP = ip }
                self.sendOnQueue("hello", ["name": macName])
            }
            self.handle(type, data)
        }
        ch.onClose = {
            self.pending[id] = nil
            guard self.channel === ch else { return }
            self.channel = nil
            self.abortIncomingFile()
            self.viewRequests.removeAll()
            DispatchQueue.main.async {
                self.connected = false
                self.phoneIP = nil // so the next connection is noticed even at the same address
                self.mirroring = false
                self.cameraOn = false
            }
        }
        ch.start()
    }

    // MARK: sending

    private func sendOnQueue(_ t: String, _ fields: [String: Any] = [:]) {
        var j = fields
        j["t"] = t
        guard let d = try? JSONSerialization.data(withJSONObject: j) else { return }
        channel?.send(Frame.json, d)
    }

    func send(_ t: String, _ fields: [String: Any] = [:]) {
        queue.async { self.sendOnQueue(t, fields) }
    }

    private func sendRaw(_ type: UInt8, _ payload: Data, done: @escaping () -> Void) {
        queue.async {
            guard let ch = self.channel else { done(); return }
            ch.send(type, payload, done: done)
        }
    }

    // MARK: receiving (runs on `queue`)

    private func handle(_ type: UInt8, _ data: Data) {
        switch type {
        case Frame.json:
            guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let t = j["t"] as? String else { return }
            handleJSON(t, j)
        case Frame.screen: screenFeed.push(data)
        case Frame.camera: cameraFeed.push(data)
        case Frame.file:
            if data.count > 4 { try? rx?.handle.write(contentsOf: data.dropFirst(4)) }
        case Frame.thumb:
            guard data.count > 8 else { return }
            let id = Int64(bitPattern: data.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) })
            if let img = NSImage(data: Data(data.dropFirst(8))) {
                DispatchQueue.main.async { self.thumbs[id] = img }
            }
        case Frame.icon:
            guard data.count > 2 else { return }
            let b = [UInt8](data.prefix(2))
            let n = Int(b[0]) << 8 | Int(b[1])
            guard data.count > 2 + n else { return }
            let pkg = String(decoding: data.dropFirst(2).prefix(n), as: UTF8.self)
            if let img = NSImage(data: Data(data.dropFirst(2 + n))) {
                DispatchQueue.main.async { self.appIcons[pkg] = img }
            }
        default: break
        }
    }

    private func handleJSON(_ t: String, _ j: [String: Any]) {
        func str(_ k: String) -> String { j[k] as? String ?? "" }
        func flag(_ k: String) -> Bool { j[k] as? Bool ?? false }
        switch t {
        case "hello":
            let name = str("name")
            DispatchQueue.main.async { self.phoneName = name; self.connected = true; self.lastError = nil }
        case "status":
            let (a, m, c, n) = (flag("accessibility"), flag("mirror"), flag("camera"), flag("notifications"))
            let level = j["battery"] as? Int ?? -1
            let charging = flag("charging")
            DispatchQueue.main.async {
                self.accessibilityOn = a; self.mirroring = m; self.cameraOn = c; self.notificationsOn = n
                self.battery = level >= 0 ? level : nil
                self.charging = charging
            }
        case "apps":
            let items = (j["items"] as? [[String: Any]] ?? []).compactMap { d -> PhoneApp? in
                guard let pkg = d["pkg"] as? String else { return nil }
                return PhoneApp(name: d["name"] as? String ?? pkg, package: pkg, system: d["system"] as? Bool ?? false)
            }
            DispatchQueue.main.async { self.phoneApps = items }
        case "clip":
            let text = str("text")
            DispatchQueue.main.async { self.receiveClip(text) }
        case "notif":
            let n = PhoneNotif(id: str("key"), app: str("app"), title: str("title"), text: str("text"),
                               canReply: flag("reply"), date: Date())
            DispatchQueue.main.async { self.addNotif(n) }
        case "notif_gone":
            let key = str("key")
            DispatchQueue.main.async {
                self.notifs.removeAll { $0.id == key }
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [key])
            }
        case "file_start": beginIncomingFile(name: str("name"), photo: (j["photo"] as? NSNumber)?.int64Value)
        case "file_end": endIncomingFile(ok: j["ok"] as? Bool ?? true)
        case "photos":
            let offset = j["offset"] as? Int ?? 0
            let more = flag("more")
            let items = (j["items"] as? [[String: Any]] ?? []).compactMap { d -> Photo? in
                guard let id = (d["id"] as? NSNumber)?.int64Value else { return nil }
                return Photo(id: id, name: d["name"] as? String ?? "")
            }
            DispatchQueue.main.async {
                if offset == 0 { self.photos = items } else { self.photos.append(contentsOf: items) }
                self.morePhotos = more
            }
        case "contacts":
            let items = (j["items"] as? [[String: Any]] ?? []).map {
                Contact(name: $0["name"] as? String ?? "", phones: $0["phones"] as? [String] ?? [])
            }
            DispatchQueue.main.async { self.contacts = items }
        case "sms_threads":
            let items = (j["items"] as? [[String: Any]] ?? []).compactMap { d -> SMSThread? in
                guard let id = (d["id"] as? NSNumber)?.int64Value else { return nil }
                return SMSThread(id: id, address: d["address"] as? String ?? "", name: d["name"] as? String ?? "",
                                 snippet: d["snippet"] as? String ?? "",
                                 date: Date(timeIntervalSince1970: ((d["ts"] as? NSNumber)?.doubleValue ?? 0) / 1000),
                                 unread: d["unread"] as? Bool ?? false)
            }
            DispatchQueue.main.async { self.smsThreads = items }
        case "sms":
            guard let thread = (j["thread"] as? NSNumber)?.int64Value else { return }
            let items = (j["items"] as? [[String: Any]] ?? []).compactMap { d -> SMSMessage? in
                guard let id = (d["id"] as? NSNumber)?.int64Value else { return nil }
                return SMSMessage(id: id, body: d["body"] as? String ?? "",
                                  date: Date(timeIntervalSince1970: ((d["ts"] as? NSNumber)?.doubleValue ?? 0) / 1000),
                                  outgoing: d["out"] as? Bool ?? false)
            }
            DispatchQueue.main.async { self.smsMessages[thread] = items }
        case "sms_changed":
            DispatchQueue.main.async {
                self.loadSMSThreads()
                if let t = self.openThread { self.loadSMS(t) }
            }
        case "mirror_info":
            let size = CGSize(width: j["w"] as? Int ?? 9, height: j["h"] as? Int ?? 16)
            DispatchQueue.main.async { self.mirrorSize = size }
        case "error":
            let msg = str("msg")
            DispatchQueue.main.async { self.lastError = msg }
        default: break
        }
    }

    // MARK: clipboard

    private func receiveClip(_ text: String) {
        lastClip = text
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        pasteCount = pb.changeCount
        remember(text, fromPhone: true)
    }

    /// Text the phone clipboard watcher reported (see Native.startClipboardBridge). Main thread.
    func clipFromPhone(_ text: String) {
        guard autoClipboard, !text.isEmpty, text != lastClip else { return } // also drops the echo of our own clip
        receiveClip(text)
    }

    private func pollPasteboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != pasteCount else { return }
        pasteCount = pb.changeCount
        guard autoClipboard, connected else { return }
        // Password managers mark secrets with this type. Never sync those.
        if pb.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) == true { return }
        guard let s = pb.string(forType: .string), !s.isEmpty, s != lastClip, s.utf8.count < 1_000_000 else { return }
        sendClipboard(s)
    }

    func sendClipboard(_ text: String? = nil) {
        guard let s = text ?? NSPasteboard.general.string(forType: .string), !s.isEmpty else { return }
        lastClip = s
        send("clip", ["text": s])
        remember(s, fromPhone: false)
    }

    private func remember(_ text: String, fromPhone: Bool) {
        clips.insert(ClipEntry(text: text, fromPhone: fromPhone), at: 0)
        if clips.count > 50 { clips.removeLast() }
    }

    // MARK: notifications

    private func addNotif(_ n: PhoneNotif) {
        notifs.removeAll { $0.id == n.id }
        notifs.insert(n, at: 0)
        if notifs.count > 200 { notifs.removeLast() }
        let c = UNMutableNotificationContent()
        c.title = n.title.isEmpty ? n.app : n.title
        c.subtitle = n.title.isEmpty ? "" : n.app
        c.body = n.text
        c.sound = .default
        c.categoryIdentifier = n.canReply ? "reply" : "plain"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: n.id, content: c, trigger: nil))
    }

    /// Reads whether macOS lets this app show notification banners.
    func checkBanners() {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            let ok = s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
            DispatchQueue.main.async { self.bannersAllowed = ok }
        }
    }

    func reply(_ key: String, _ text: String) { send("reply", ["key": key, "text": text]) }

    func dismiss(_ key: String) {
        send("dismiss", ["key": key])
        notifs.removeAll { $0.id == key }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        if let r = response as? UNTextInputNotificationResponse {
            reply(response.notification.request.identifier, r.userText)
        }
        done()
    }

    // MARK: files

    func sendFile(_ url: URL) {
        let tid = UUID()
        DispatchQueue.main.async { self.transfers.insert(Transfer(id: tid, name: url.lastPathComponent, incoming: false), at: 0) }
        fileQueue.async {
            var ok = false
            defer { DispatchQueue.main.async { self.finishTransfer(tid, ok: ok, url: url) } }
            guard let h = try? FileHandle(forReadingFrom: url) else { return }
            defer { try? h.close() }
            let id: UInt32 = self.queue.sync { let v = self.nextFileID; self.nextFileID += 1; return v }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? -1
            self.send("file_start", ["id": Int(id), "name": url.lastPathComponent, "size": size])
            var head = Data()
            withUnsafeBytes(of: id.bigEndian) { head.append(contentsOf: $0) }
            let sem = DispatchSemaphore(value: 0)
            while true {
                guard self.queue.sync(execute: { self.channel != nil }) else { return }
                let chunk = h.readData(ofLength: 64 * 1024)
                if chunk.isEmpty { break }
                self.sendRaw(Frame.file, head + chunk) { sem.signal() } // one chunk in flight at a time
                sem.wait()
            }
            self.send("file_end", ["id": Int(id), "ok": true])
            ok = true
        }
    }

    private func beginIncomingFile(name: String, photo: Int64?) {
        abortIncomingFile()
        let fm = FileManager.default
        let clean = (name as NSString).lastPathComponent.isEmpty ? "file" : (name as NSString).lastPathComponent
        // A photo opened in the viewer goes to the cache, not to Downloads.
        if let photo, viewRequests.remove(photo) != nil {
            let dir = Link.photoCache
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("\(photo)-\(clean)")
            fm.createFile(atPath: url.path, contents: nil)
            guard let h = try? FileHandle(forWritingTo: url) else { return }
            rx = (h, url, nil, photo)
            return
        }
        let dir = fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let url = Link.unusedName(clean, in: dir)
        fm.createFile(atPath: url.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        let tid = UUID()
        rx = (h, url, tid, nil)
        DispatchQueue.main.async { self.transfers.insert(Transfer(id: tid, name: url.lastPathComponent, incoming: true), at: 0) }
    }

    static let photoCache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AndroMac/photos", isDirectory: true)

    /// `name` in `dir`, or "name 2", "name 3"… if that is taken.
    static func unusedName(_ name: String, in dir: URL) -> URL {
        let fm = FileManager.default
        var url = dir.appendingPathComponent(name)
        var n = 2
        while fm.fileExists(atPath: url.path) {
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            url = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }

    private func endIncomingFile(ok: Bool) {
        guard let r = rx else { return }
        rx = nil
        try? r.handle.close()
        if !ok { try? FileManager.default.removeItem(at: r.url) }
        DispatchQueue.main.async {
            if let photo = r.photo { if ok { self.fullPhotos[photo] = r.url } }
            else if let t = r.transfer { self.finishTransfer(t, ok: ok, url: r.url) }
        }
    }

    private func abortIncomingFile() { if rx != nil { endIncomingFile(ok: false) } }

    private func finishTransfer(_ id: UUID, ok: Bool, url: URL) {
        guard let i = transfers.firstIndex(where: { $0.id == id }) else { return }
        transfers[i].done = ok
        transfers[i].failed = !ok
        transfers[i].url = url
    }

    // MARK: photos, contacts, mirror, camera

    func loadPhotos(more: Bool = false) {
        if !more { thumbsRequested.removeAll() }
        send("photos_get", ["offset": more ? photos.count : 0, "limit": 60])
    }

    func requestThumb(_ id: Int64) {
        guard thumbs[id] == nil, thumbsRequested.insert(id).inserted else { return }
        send("thumb_get", ["id": id])
    }

    func downloadPhoto(_ id: Int64) { send("photo_get", ["id": id]) }

    /// Fetches the full-size photo for the viewer, unless it is already cached.
    func viewPhoto(_ id: Int64) {
        if let url = fullPhotos[id], FileManager.default.fileExists(atPath: url.path) { return }
        queue.async {
            guard self.viewRequests.insert(id).inserted else { return }
            self.sendOnQueue("photo_get", ["id": id])
        }
    }

    /// Saves to Downloads: a copy of the cached file if the viewer already has it, otherwise a fresh download.
    func savePhoto(_ p: Photo) {
        guard let cached = fullPhotos[p.id], FileManager.default.fileExists(atPath: cached.path) else { downloadPhoto(p.id); return }
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let url = Link.unusedName(p.name.isEmpty ? cached.lastPathComponent : p.name, in: dir)
        let ok = (try? FileManager.default.copyItem(at: cached, to: url)) != nil
        var t = Transfer(id: UUID(), name: url.lastPathComponent, incoming: true)
        t.done = ok; t.failed = !ok; t.url = url
        transfers.insert(t, at: 0)
    }
    func loadContacts() { send("contacts_get") }
    func loadApps() { send("apps_get") }

    func requestIcon(_ pkg: String) {
        guard appIcons[pkg] == nil, iconsRequested.insert(pkg).inserted else { return }
        send("app_icon_get", ["pkg": pkg])
    }

    func clearNotifs() { notifs.removeAll() }

    func loadSMSThreads() { send("sms_threads_get") }
    func loadSMS(_ thread: Int64) { send("sms_get", ["thread": thread, "limit": 200]) }
    func sendSMS(to: String, text: String) { lastError = nil; send("sms_send", ["to": to, "text": text]) }

    func startMirror() { lastError = nil; send("mirror_start", ["max": 1280, "bitrate": 6_000_000]) }
    func stopMirror() { send("mirror_stop") }
    func input(_ fields: [String: Any]) { send("input", fields) }
    func startCamera(front: Bool) { lastError = nil; send("cam_start", ["front": front]) }
    func stopCamera() { send("cam_stop") }
    func requestKeyframe() { send("keyframe") }
}

/// First non-loopback IPv4 address, preferring Wi-Fi/Ethernet (en*).
func localIPv4() -> String? {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0 else { return nil }
    defer { freeifaddrs(list) }
    var fallback: String?
    var p = list
    while let i = p {
        p = i.pointee.ifa_next
        let flags = Int32(i.pointee.ifa_flags)
        guard let sa = i.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
              flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
        else { continue }
        let ip = String(cString: host)
        if String(cString: i.pointee.ifa_name).hasPrefix("en") { return ip }
        if fallback == nil { fallback = ip }
    }
    return fallback
}

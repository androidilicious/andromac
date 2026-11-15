import Foundation
import AppKit

struct PhoneApp: Identifiable, Hashable {
    let name: String
    let package: String
    let system: Bool
    var id: String { package }
}

/// "Native" phone screen and app windows, the way Phone Link feels on supported phones.
///
/// A sideloaded Android app can only capture the screen through the system cast prompt. The debugging
/// channel (adb) has no such limit: it can stream the screen without a prompt, inject real keyboard and
/// mouse input, and open an app on its own virtual display. This class drives the open-source `scrcpy`
/// tool to do that. It needs USB debugging switched on and one USB connection; after that it works over Wi-Fi.
final class Native: ObservableObject {
    @Published var device: String?      // adb serial in use
    @Published var busy = false
    @Published var problem: String?     // what is missing, in words the user can act on
    @Published var apps: [PhoneApp] = []
    @Published var loadingApps = false
    /** True while the phone clipboard watcher is running, i.e. phone copies reach the Mac by themselves. */
    @Published var clipboardAuto = false

    private let work = DispatchQueue(label: "andromac.native")
    private var running: [Process] = []
    private var retry: String?
    private var clipBridge: Process?
    private var clipDevice: String?

    init() {
        // Phone windows are separate processes; take them down with the app.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) {
            [weak self] _ in self?.closeAll()
        }
    }

    private static func find(_ name: String, _ extra: [String] = []) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin"] + extra + ["\(home)/Library/Android/sdk/platform-tools"]
        return dirs.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private var adb: String? { Self.find("adb", ["/opt/homebrew/share/android-commandlinetools/platform-tools"]) }
    private var scrcpy: String? { Self.find("scrcpy") }
    var ready: Bool { device != nil }

    /// Runs a tool and returns (exit code, combined output). Never call on the main thread.
    private func run(_ tool: String, _ args: [String], timeout: TimeInterval = 15) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.environment = toolEnvironment()
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        guard (try? p.run()) != nil else { return (-1, "could not start \(tool)") }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func toolEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        if let adb { env["ADB"] = adb }
        return env
    }

    /// Attached devices that are authorised and online: [(serial, isNetwork)].
    private func devices(_ adb: String) -> (ready: [String], unauthorized: Bool) {
        let (_, out) = run(adb, ["devices"])
        var ready: [String] = []
        var unauthorized = false
        for line in out.split(separator: "\n").dropFirst() {
            let f = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            guard f.count >= 2 else { continue }
            if f[1] == "device" { ready.append(String(f[0])) }
            if f[1] == "unauthorized" { unauthorized = true }
        }
        return (ready, unauthorized)
    }

    /// Finds the phone on adb, preferring Wi-Fi. A phone on USB is switched to Wi-Fi so the cable can go.
    func refresh(phoneIP: String?) {
        guard !busy else { retry = phoneIP; return }
        busy = true
        work.async {
            let (device, problem) = self.locate(phoneIP: phoneIP)
            DispatchQueue.main.async {
                self.device = device
                self.problem = problem
                self.busy = false
                self.startClipboardBridge()
                if let again = self.retry { self.retry = nil; self.refresh(phoneIP: again) }
            }
        }
    }

    /// "ip:port" of the phone's wireless-debugging service, from `adb mdns services`.
    private func wirelessDebugAddress(_ adb: String, phoneIP: String?) -> String? {
        let (_, out) = run(adb, ["mdns", "services"], timeout: 6)
        let found = out.split(separator: "\n").compactMap { line -> String? in
            let f = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            guard f.count >= 3, f[1] == "_adb-tls-connect._tcp" else { return nil }
            return String(f[2])
        }
        if let phoneIP { return found.first { $0.hasPrefix(phoneIP + ":") } }
        return found.first
    }

    /// Two one-time fixes, harmless to repeat: let the phone app turn wireless debugging back on by itself
    /// after a restart, and lift Android's "restricted setting" block on sideloaded apps, which otherwise shows
    /// accessibility and notification access as denied in the phone's Settings.
    private func grantAutoReconnect(_ adb: String, _ device: String) {
        _ = run(adb, ["-s", device, "shell", "pm grant app.andromac android.permission.WRITE_SECURE_SETTINGS; "
            + "appops set app.andromac ACCESS_RESTRICTED_SETTINGS allow"], timeout: 6)
    }

    private func locate(phoneIP: String?) -> (String?, String?) {
        let (device, problem) = find(phoneIP: phoneIP)
        if let device, let adb { grantAutoReconnect(adb, device) }
        return (device, problem)
    }

    private func find(phoneIP: String?) -> (String?, String?) {
        guard scrcpy != nil else {
            return (nil, "The scrcpy tool is not installed. In Terminal, run:  brew install scrcpy")
        }
        guard let adb else {
            return (nil, "The adb tool is not installed. In Terminal, run:  brew install --cask android-platform-tools")
        }
        let wifi = phoneIP.map { "\($0):5555" }
        var found = devices(adb)
        if let wifi, found.ready.contains(wifi) { return (wifi, nil) }

        if let wifi {
            _ = run(adb, ["connect", wifi], timeout: 4)
            found = devices(adb)
            if found.ready.contains(wifi) { return (wifi, nil) }
            _ = run(adb, ["disconnect", wifi], timeout: 4) // forget a dead entry
        }
        // After a phone restart port 5555 is gone, but the phone app switches wireless debugging back on.
        // That listens on a random port, announced over Bonjour; this Mac is already approved, so it just connects.
        if let tls = wirelessDebugAddress(adb, phoneIP: phoneIP) {
            if !found.ready.contains(tls) { _ = run(adb, ["connect", tls], timeout: 5) }
            if devices(adb).ready.contains(tls) { return (tls, nil) }
            _ = run(adb, ["disconnect", tls], timeout: 4)
        }
        // A phone on USB: ask it to also listen on Wi-Fi, then use that.
        if let usb = found.ready.first(where: { !$0.contains(":") }) {
            if let wifi, !usb.hasPrefix("emulator-") {
                _ = run(adb, ["-s", usb, "tcpip", "5555"], timeout: 8)
                Thread.sleep(forTimeInterval: 2)
                _ = run(adb, ["connect", wifi], timeout: 5)
                if devices(adb).ready.contains(wifi) { return (wifi, nil) }
            }
            return (usb, nil)
        }
        if let other = found.ready.first { return (other, nil) }
        if found.unauthorized {
            return (nil, "The phone is plugged in but has not allowed this Mac. Unlock it and tap Allow on the USB debugging prompt.")
        }
        return (nil, "One-time setup: on the phone open Settings > About phone and tap Build number seven times, then turn on "
            + "Settings > System > Developer options > USB debugging. Plug the phone into this Mac, tap Allow on the phone, "
            + "and press Check again. After that the cable is not needed until the phone restarts.")
    }

    // MARK: windows

    /// The whole phone screen in its own window: no cast prompt, real keyboard and mouse, sound on the Mac.
    func openScreen(title: String, screenOff: Bool) {
        var args = ["--window-title=\(title)", "--disable-screensaver"]
        if screenOff { args.append("--turn-screen-off") }
        guard let window = launch(args), let adb, let device else { return }
        keepAwake(while: window, adb: adb, device: device, screenOff: screenOff)
    }

    /// Holds the phone awake, with its own panel dark if asked, for as long as the phone window is open.
    ///
    /// Left alone, a locked phone falls back asleep a few seconds after the window opens and the picture
    /// freezes, and any sleep/wake cycle lights the panel again. So every two seconds this wakes the phone
    /// if it dozed off, otherwise taps Shift (a key with no effect that still counts as activity, which a
    /// wake-up key does not, so the lock screen's 6-second timer never runs out), and darkens the panel again.
    private func keepAwake(while window: Process, adb: String, device: String, screenOff: Bool) {
        let tick = "case \"$(dumpsys power | grep -m1 mWakefulness=)\" in *Awake*) input keyevent KEYCODE_SHIFT_LEFT;; "
            + "*) input keyevent KEYCODE_WAKEUP;; esac" + (screenOff ? "; cmd display power-off 0" : "")
        let timer = DispatchSource.makeTimerSource(queue: work)
        timer.schedule(deadline: .now() + 1.5, repeating: 2)
        timer.setEventHandler {
            if window.isRunning {
                _ = self.run(adb, ["-s", device, "shell", tick], timeout: 5)
            } else {
                timer.cancel()
                // Give the panel back to the phone; it then sleeps and locks on its usual schedule.
                if screenOff { _ = self.run(adb, ["-s", device, "shell", "cmd display power-reset 0"], timeout: 5) }
            }
        }
        timer.resume()
    }

    /// One app in its own window, on a separate virtual display, while the phone itself stays free.
    func openApp(_ app: PhoneApp) {
        launch(["--window-title=\(app.name)", "--new-display", "--no-vd-system-decorations",
                "--start-app=\(app.package)", "--no-audio", "--window-height=820"])
    }

    @discardableResult
    private func launch(_ args: [String]) -> Process? {
        guard let scrcpy, let device else { return nil }
        problem = nil
        let p = Process()
        p.executableURL = URL(fileURLWithPath: scrcpy)
        p.arguments = ["--serial=\(device)"] + args
        p.environment = toolEnvironment()
        let pipe = Pipe()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = pipe
        let started = Date()
        p.terminationHandler = { p in
            let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            DispatchQueue.main.async {
                self.running.removeAll { $0 === p }
                // Closing the window is a normal exit. A quick failure means the link to the phone is gone.
                if p.terminationStatus != 0, Date().timeIntervalSince(started) < 8 {
                    let reason = text.split(separator: "\n").last { $0.contains("ERROR") }.map(String.init)
                    self.problem = "Could not open the window. " + (reason ?? "Press Check again.")
                    self.device = nil
                }
            }
        }
        do { try p.run(); running.append(p); return p } catch {
            problem = "Could not start scrcpy: \(error.localizedDescription)"
            return nil
        }
    }

    func loadApps() {
        guard let scrcpy, let device, !loadingApps else { return }
        loadingApps = true
        work.async {
            let (_, out) = self.run(scrcpy, ["--serial=\(device)", "--list-apps"], timeout: 40)
            // Lines look like " * Calendar      com.google.android.calendar"; * marks apps that came with the phone.
            let apps = out.split(separator: "\n").compactMap { line -> PhoneApp? in
                let t = line.trimmingCharacters(in: .whitespaces)
                guard let mark = t.first, mark == "*" || mark == "-",
                      let gap = t.lastIndex(of: " ") else { return nil }
                let name = t[t.index(after: t.startIndex)..<gap].trimmingCharacters(in: .whitespaces)
                let package = String(t[t.index(after: gap)...])
                guard !name.isEmpty, package.contains(".") else { return nil }
                return PhoneApp(name: name, package: package, system: mark == "*")
            }
            DispatchQueue.main.async {
                self.apps = apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                self.loadingApps = false
            }
        }
    }

    func closeAll() { running.forEach { $0.terminate() }; clipBridge?.terminate() }

    // MARK: clipboard

    /// Android will not let an installed app read the clipboard in the background, but the debugging shell may.
    /// This runs the small watcher that ships inside the phone app (ClipDaemon) under that shell and feeds
    /// what it prints, one base64 line per copied text, into the normal clipboard path.
    private func startClipboardBridge() {
        guard let adb, let device else { return }
        if let b = clipBridge, b.isRunning, clipDevice == device { return }
        clipBridge?.terminate()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: adb)
        p.arguments = ["-s", device, "shell",
                       "CLASSPATH=$(pm path app.andromac | head -1 | cut -d: -f2) app_process / app.andromac.ClipDaemon"]
        p.environment = toolEnvironment()
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        var pending = Data()
        out.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            if chunk.isEmpty { h.readabilityHandler = nil; return }
            pending.append(chunk)
            while let nl = pending.firstIndex(of: 0x0A) {
                let line = String(decoding: pending[pending.startIndex..<nl], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                pending.removeSubrange(pending.startIndex...nl)
                if line == "READY" {
                    DispatchQueue.main.async { self.clipboardAuto = true }
                } else if let d = Data(base64Encoded: line), let text = String(data: d, encoding: .utf8) {
                    DispatchQueue.main.async { Link.shared.clipFromPhone(text) }
                }
            }
        }
        p.terminationHandler = { p in
            DispatchQueue.main.async {
                guard self.clipBridge === p else { return }
                self.clipBridge = nil
                self.clipboardAuto = false
            }
        }
        do { try p.run(); clipBridge = p; clipDevice = device } catch { clipBridge = nil }
    }
}

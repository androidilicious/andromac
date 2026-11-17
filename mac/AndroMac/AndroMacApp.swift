import SwiftUI
import AppKit

@main
struct AndroMacApp: App {
    @StateObject private var link = Link.shared
    @StateObject private var webcam = Webcam()
    @StateObject private var native = Native()
    @StateObject private var nav = Nav()

    init() {
        // Only one copy may run. A second one (say, the build-folder copy next to the one in Applications) would
        // share the pairing key, and the phone would link to whichever it found first, leaving the other
        // window looking connected to nothing.
        let me = NSRunningApplication.current
        let twins = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "app.andromac.AndroMac")
            .filter { $0 != me && !$0.isTerminated }
        if let running = twins.first {
            running.activate()
            exit(0)
        }
        Link.shared.start()
    }

    var body: some Scene {
        Window("AndroMac", id: "main") {
            ContentView()
                .environmentObject(link)
                .environmentObject(webcam)
                .environmentObject(native)
                .environmentObject(nav)
                .tint(Theme.brand)
                .frame(minWidth: 900, minHeight: 620)
        }
        .defaultSize(width: 1120, height: 740)
        MenuBarExtra {
            MenuContent().environmentObject(link)
        } label: {
            Image(nsImage: menuBarIcon(connected: link.connected))
                .accessibilityLabel(link.connected ? "AndroMac, phone connected" : "AndroMac, phone not connected")
        }
    }
}

struct MenuContent: View {
    @EnvironmentObject var link: Link
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(link.connected ? "Connected to \(link.phoneName)" : "Phone not connected")
        Divider()
        Button("Open AndroMac") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Send Clipboard to Phone") { link.sendClipboard() }.disabled(!link.connected)
        Button("Send File to Phone…") { chooseFiles(link) }.disabled(!link.connected)
        Divider()
        Button("Quit AndroMac") { NSApp.terminate(nil) }
    }
}

func chooseFiles(_ link: Link) {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    NSApp.activate(ignoringOtherApps: true)
    if panel.runModal() == .OK { panel.urls.forEach(link.sendFile) }
}

/// The AM monogram for the menu bar. A template image, so macOS colours it for light and dark menu bars;
/// it is drawn faint while no phone is linked.
func menuBarIcon(connected: Bool) -> NSImage {
    let side: CGFloat = 18
    let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
        // Designed on a 512 grid; the mark spans x 92...420 and y 136...384. Fit it to the icon with a small margin.
        let k = (side - 2) / 372
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: 1 + (x - 70) * k, y: 1 + (y - 74) * k) }
        // One transparency layer, so the two strokes fade as a single shape instead of showing their overlap.
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.setAlpha(connected ? 1 : 0.4)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        defer { ctx.endTransparencyLayer() }
        NSColor.black.setStroke()
        let m = NSBezierPath()
        m.lineWidth = 46 * k
        m.lineCapStyle = .round
        m.lineJoinStyle = .round
        m.move(to: p(92, 384)); m.line(to: p(176, 136)); m.line(to: p(256, 330)); m.line(to: p(336, 136)); m.line(to: p(420, 384))
        m.stroke()
        let bar = NSBezierPath()
        bar.lineWidth = 38 * k
        bar.lineCapStyle = .round
        bar.move(to: p(136, 286)); bar.line(to: p(214, 286))
        bar.stroke()
        return true
    }
    image.isTemplate = true
    return image
}

import SwiftUI
import AppKit

@main
struct AndroMacApp: App {
    @StateObject private var link = Link.shared
    @StateObject private var webcam = Webcam()
    @StateObject private var native = Native()
    @StateObject private var nav = Nav()

    init() { Link.shared.start() }

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
        MenuBarExtra("AndroMac", systemImage: link.connected ? "iphone.gen3.radiowaves.left.and.right" : "iphone.gen3.slash") {
            MenuContent().environmentObject(link)
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

import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers

// MARK: Navigation

enum Pane: String, CaseIterable, Identifiable {
    case home = "Home", mirror = "Phone Screen", apps = "Apps",
         notifications = "Notifications", messages = "Messages",
         clipboard = "Clipboard", files = "Files", photos = "Photos",
         contacts = "Contacts", camera = "Camera"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .home: return "house"
        case .mirror: return "iphone"
        case .apps: return "square.grid.2x2"
        case .notifications: return "bell"
        case .messages: return "message"
        case .clipboard: return "doc.on.clipboard"
        case .files: return "folder"
        case .photos: return "photo.on.rectangle"
        case .contacts: return "person.2"
        case .camera: return "web.camera"
        }
    }
}

/// Which pane is showing, plus hand-offs between panes (a contact's "Message" button opens the composer).
final class Nav: ObservableObject {
    @Published var pane: Pane? = .home
    @Published var composeTo: String?
}

// MARK: Look

enum Theme {
    static let brand = Color(red: 0.09, green: 0.62, blue: 0.53)
    static let brandDeep = Color(red: 0.05, green: 0.42, blue: 0.55)
    static let gradient = LinearGradient(colors: [brand, brandDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let hairline = Color.primary.opacity(0.08)
    /// Stable colour for a name, for avatars and app placeholders.
    static func tint(for text: String) -> Color {
        let palette: [Color] = [.blue, .teal, .indigo, .orange, .pink, .purple, .green, .cyan, .brown, .mint]
        var h: UInt64 = 1469598103934665603 // FNV-1a: spreads short names evenly across the palette
        for s in text.unicodeScalars { h = (h ^ UInt64(s.value)) &* 1099511628211 }
        return palette[Int((h >> 16) % UInt64(palette.count))]
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
    }
}

struct Avatar: View {
    let name: String
    var size: CGFloat = 36
    private var initials: String {
        let words = name.split(separator: " ").filter { $0.first?.isLetter == true }
        let letters = words.prefix(2).compactMap { $0.first }.map(String.init).joined().uppercased()
        return letters.isEmpty ? "#" : letters
    }
    var body: some View {
        Circle().fill(Theme.tint(for: name).gradient)
            .frame(width: size, height: size)
            .overlay(Text(initials).font(.system(size: size * 0.38, weight: .semibold, design: .rounded)).foregroundStyle(.white))
    }
}

struct Pill: View {
    let text: String
    var icon: String?
    var color: Color = .secondary
    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon) }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .foregroundStyle(color)
        .background(color.opacity(0.13), in: Capsule())
    }
}

struct EmptyNote: View {
    let title: String
    let detail: String
    var icon: String = "tray"
    init(_ title: String, _ detail: String, icon: String = "tray") { self.title = title; self.detail = detail; self.icon = icon }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 34, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.title3.weight(.semibold))
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

/// Page scaffold: scrolling column with a comfortable reading width.
struct Page<Content: View>: View {
    var width: CGFloat = 760
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) { content }
                .frame(maxWidth: width, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity)
        }
    }
}

func relative(_ date: Date) -> String {
    let s = Date().timeIntervalSince(date)
    if s < 60 { return "now" }
    if s < 3600 { return "\(Int(s / 60))m" }
    if s < 86400 { return "\(Int(s / 3600))h" }
    if s < 7 * 86400 { return "\(Int(s / 86400))d" }
    return date.formatted(.dateTime.month(.abbreviated).day())
}

// MARK: Shell

struct ContentView: View {
    @EnvironmentObject var link: Link
    @EnvironmentObject var native: Native
    @EnvironmentObject var nav: Nav

    private var unread: Int { link.smsThreads.filter(\.unread).count }

    var body: some View {
        NavigationSplitView {
            List(selection: $nav.pane) {
                Section { row(.home); row(.mirror); row(.apps) }
                Section("Stay in touch") {
                    // The tag goes on last, outside the badge, so the row stays selectable.
                    Label(Pane.notifications.rawValue, systemImage: Pane.notifications.icon).badge(link.notifs.count).tag(Pane.notifications)
                    Label(Pane.messages.rawValue, systemImage: Pane.messages.icon).badge(unread).tag(Pane.messages)
                }
                Section("Share") { row(.clipboard); row(.files); row(.photos) }
                Section("More") { row(.contacts); row(.camera) }
            }
            .safeAreaInset(edge: .bottom) { DeviceBadge().padding(10) }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            VStack(spacing: 0) {
                if let e = link.lastError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(e).lineLimit(3)
                        Spacer()
                        Button("Dismiss") { link.lastError = nil }.buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Color.orange.opacity(0.12))
                }
                Group {
                    switch nav.pane ?? .home {
                    case .home: HomeView()
                    case .notifications: NotificationsView()
                    case .messages: MessagesView()
                    case .clipboard: ClipboardView()
                    case .files: FilesView()
                    case .photos: PhotosView()
                    case .contacts: ContactsView()
                    case .mirror: MirrorView()
                    case .apps: AppsView()
                    case .camera: CameraView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle((nav.pane ?? .home).rawValue)
        }
        // Each time the phone links up, find it for the native window. The second try covers a phone that has
        // just restarted and needs a few seconds to bring wireless debugging back.
        // Fetch conversations as soon as the phone links, so the unread badge is right before Messages is opened.
        .onChange(of: link.connected) { _, on in if on { link.loadSMSThreads() } }
        .onChange(of: link.phoneIP) { _, ip in
            guard let ip else { return }
            native.refresh(phoneIP: ip)
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                if !native.ready, link.phoneIP == ip { native.refresh(phoneIP: ip) }
            }
        }
    }

    private func row(_ p: Pane) -> some View { Label(p.rawValue, systemImage: p.icon).tag(p) }
}

/// The phone, its link state and battery, pinned to the bottom of the sidebar.
struct DeviceBadge: View {
    @EnvironmentObject var link: Link

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(link.connected ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.secondary.opacity(0.3)))
                .frame(width: 34, height: 34)
                .overlay(Image(systemName: "iphone").font(.system(size: 17, weight: .medium)).foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 1) {
                Text(link.connected ? link.phoneName : "No phone").font(.callout.weight(.medium)).lineLimit(1)
                HStack(spacing: 4) {
                    Circle().fill(link.connected ? Color.green : Color.secondary).frame(width: 6, height: 6)
                    Text(link.connected ? "Connected" : "Not connected")
                    if link.connected, let b = link.battery {
                        Text("·")
                        Image(systemName: batterySymbol(b, link.charging))
                        Text("\(b)%")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

func batterySymbol(_ level: Int, _ charging: Bool) -> String {
    if charging { return "battery.100.bolt" }
    switch level {
    case ..<13: return "battery.0"
    case ..<38: return "battery.25"
    case ..<63: return "battery.50"
    case ..<88: return "battery.75"
    default: return "battery.100"
    }
}

// MARK: Home

func qrImage(_ text: String) -> NSImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    filter.correctionLevel = "M"
    guard let out = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
    let rep = NSCIImageRep(ciImage: out)
    let image = NSImage(size: rep.size)
    image.addRepresentation(rep)
    return image
}

struct HomeView: View {
    @EnvironmentObject var link: Link
    @EnvironmentObject var native: Native
    @EnvironmentObject var nav: Nav
    @AppStorage("screenOff") private var screenOff = true
    @State private var showPairing = false

    var body: some View {
        if link.connected { connected } else { PairingView(waiting: true) }
    }

    private var connected: some View {
        Page {
            // Hero
            HStack(spacing: 18) {
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.gradient)
                    .frame(width: 84, height: 84)
                    .overlay(Image(systemName: "iphone").font(.system(size: 40, weight: .regular)).foregroundStyle(.white))
                    .shadow(color: Theme.brand.opacity(0.35), radius: 12, y: 6)
                VStack(alignment: .leading, spacing: 6) {
                    Text(link.phoneName).font(.system(size: 26, weight: .bold, design: .rounded))
                    HStack(spacing: 6) {
                        Pill(text: "Connected", icon: "checkmark.circle.fill", color: .green)
                        if let b = link.battery { Pill(text: "\(b)%", icon: batterySymbol(b, link.charging)) }
                        if let ip = link.phoneIP { Pill(text: ip, icon: "wifi") }
                    }
                }
                Spacer()
            }
            .padding(.bottom, 4)

            // Quick actions
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                ActionTile(title: "Phone screen", icon: "iphone", prominent: true) {
                    if native.ready {
                        native.openScreen(title: link.phoneName.isEmpty ? "Phone" : link.phoneName, screenOff: screenOff)
                    } else { nav.pane = .mirror }
                }
                ActionTile(title: "Send files", icon: "paperplane") { chooseFiles(link) }
                ActionTile(title: "Send clipboard", icon: "doc.on.clipboard") { link.sendClipboard() }
                ActionTile(title: "New message", icon: "square.and.pencil") { nav.composeTo = ""; nav.pane = .messages }
            }

            // What is switched on
            Text("Status").font(.headline).padding(.top, 6)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
                StatusTile(title: "Native phone window", icon: "macwindow",
                           on: native.ready, onText: "Ready", offText: "Needs one-time setup") { nav.pane = .mirror }
                StatusTile(title: "Clipboard", icon: "doc.on.clipboard",
                           on: native.clipboardAuto, onText: "Two-way, automatic", offText: "Mac to phone only") { nav.pane = .clipboard }
                StatusTile(title: "Notifications", icon: "bell",
                           on: link.notificationsOn, onText: "Syncing", offText: "Off on the phone") { nav.pane = .notifications }
                StatusTile(title: "Control of cast screen", icon: "cursorarrow.click.2",
                           on: link.accessibilityOn, onText: "On", offText: "Off on the phone") { nav.pane = .mirror }
            }

            if !link.notifs.isEmpty {
                HStack {
                    Text("Latest notifications").font(.headline)
                    Spacer()
                    Button("See all") { nav.pane = .notifications }.buttonStyle(.link)
                }
                .padding(.top, 6)
                VStack(spacing: 8) { ForEach(link.notifs.prefix(3)) { NotifCard(n: $0, compact: true) } }
            }

            DisclosureGroup("Pair a different phone", isExpanded: $showPairing) {
                PairingView(waiting: false).padding(.top, 8)
            }
            .padding(.top, 6)
        }
    }
}

struct ActionTile: View {
    let title: String
    let icon: String
    var prominent = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 22, weight: .medium))
                Text(title).font(.callout.weight(.medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 78)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background(prominent ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.card),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(prominent ? Color.clear : Theme.hairline))
            .scaleEffect(hover ? 1.02 : 1)
            .animation(.easeOut(duration: 0.12), value: hover)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct StatusTile: View {
    let title: String
    let icon: String
    let on: Bool
    let onText: String
    let offText: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 17)).frame(width: 34, height: 34)
                    .foregroundStyle(on ? Theme.brand : Color.secondary)
                    .background((on ? Theme.brand : Color.secondary).opacity(0.13), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(.medium))
                    Text(on ? onText : offText).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: on ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(on ? Color.green : Color.orange)
            }
            .padding(12)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
        }
        .buttonStyle(.plain)
    }
}

/// QR code and the three steps. `waiting` is the full-page version shown while no phone is linked.
struct PairingView: View {
    @EnvironmentObject var link: Link
    let waiting: Bool

    var body: some View {
        let content = HStack(alignment: .center, spacing: 32) {
            Group {
                if let img = qrImage(link.pairURL), !link.pairURL.isEmpty {
                    Image(nsImage: img).interpolation(.none).resizable().frame(width: 210, height: 210)
                } else {
                    ProgressView().frame(width: 210, height: 210)
                }
            }
            .padding(14)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 14, y: 6)

            VStack(alignment: .leading, spacing: 14) {
                if waiting {
                    Text("Link your phone").font(.system(size: 26, weight: .bold, design: .rounded))
                    Text("Waiting for a phone on this Wi-Fi…").foregroundStyle(.secondary)
                }
                Step(n: 1, text: "Open AndroMac on your Android phone.")
                Step(n: 2, text: "Tap Scan the QR code on your Mac.")
                Step(n: 3, text: "Point the camera at this code. Both devices must be on the same Wi-Fi.")
                HStack {
                    Button("Copy pairing link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(link.pairURL, forType: .string)
                    }
                    Button("Reset pairing", role: .destructive) { link.resetPairing() }
                }
                .padding(.top, 4)
                Text("The code holds the encryption key. Treat it like a password.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 320, alignment: .leading)
        }
        if waiting {
            content.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
        } else {
            Card { content }
        }
    }
}

struct Step: View {
    let n: Int
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.caption.weight(.bold)).foregroundStyle(.white)
                .frame(width: 22, height: 22).background(Theme.brand, in: Circle())
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: Notifications

struct NotificationsView: View {
    @EnvironmentObject var link: Link

    var body: some View {
        Group {
            if link.notifs.isEmpty {
                EmptyNote("You're all caught up", link.notificationsOn
                          ? "New phone notifications show up here and in Notification Center."
                          : "Turn on notification sync in the phone app to see phone notifications here.", icon: "bell.slash")
            } else {
                Page(width: 680) { ForEach(link.notifs) { NotifCard(n: $0) } }
            }
        }
        .toolbar { Button("Clear list") { link.clearNotifs() }.disabled(link.notifs.isEmpty) }
        .safeAreaInset(edge: .top) {
            if !link.bannersAllowed {
                HStack(spacing: 8) {
                    Image(systemName: "bell.slash.fill").foregroundStyle(.orange)
                    Text("macOS is not letting AndroMac show banners, so notifications only appear in this list.")
                    Spacer()
                    Button("Open Notification Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Color.orange.opacity(0.12))
            }
        }
        .onAppear { link.checkBanners() }
    }
}

struct NotifCard: View {
    @EnvironmentObject var link: Link
    let n: PhoneNotif
    var compact = false
    @State private var reply = ""
    @State private var hover = false

    var body: some View {
        Card(padding: 12) {
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.tint(for: n.app).gradient)
                    .frame(width: 36, height: 36)
                    .overlay(Text(String(n.app.prefix(1)).uppercased())
                        .font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundStyle(.white))
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(n.app).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        Text("·").foregroundStyle(.tertiary)
                        Text(relative(n.date)).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { link.dismiss(n.id) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).opacity(hover ? 1 : 0)
                            .help("Dismiss on the phone too")
                    }
                    if !n.title.isEmpty { Text(n.title).fontWeight(.semibold).lineLimit(compact ? 1 : nil) }
                    Text(n.text).foregroundStyle(.primary.opacity(0.85)).lineLimit(compact ? 2 : nil).textSelection(.enabled)
                    if n.canReply, !compact {
                        HStack(spacing: 6) {
                            TextField("Reply…", text: $reply).textFieldStyle(.plain)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(.quaternary.opacity(0.6), in: Capsule())
                                .onSubmit(sendReply)
                            Button(action: sendReply) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                                .buttonStyle(.plain).foregroundStyle(reply.isEmpty ? Color.secondary : Theme.brand)
                                .disabled(reply.isEmpty)
                        }
                        .padding(.top, 4)
                    }
                }
            }
        }
        .onHover { hover = $0 }
    }

    private func sendReply() {
        guard !reply.isEmpty else { return }
        link.reply(n.id, reply)
        reply = ""
    }
}

// MARK: Messages

struct MessagesView: View {
    @EnvironmentObject var link: Link
    @EnvironmentObject var nav: Nav
    @State private var selected: Int64?
    @State private var composing = false
    @State private var to = ""
    @State private var draft = ""
    @State private var search = ""

    private var thread: SMSThread? { link.smsThreads.first { $0.id == selected } }
    private var threads: [SMSThread] {
        search.isEmpty ? link.smsThreads : link.smsThreads.filter {
            $0.title.localizedCaseInsensitiveContains(search) || $0.snippet.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search", text: $search).textFieldStyle(.plain)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(10)
                List(threads, selection: $selected) { t in
                    HStack(spacing: 10) {
                        Avatar(name: t.title, size: 38)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(t.title).fontWeight(t.unread ? .bold : .medium).lineLimit(1)
                                Spacer()
                                Text(relative(t.date)).font(.caption).foregroundStyle(.secondary)
                            }
                            HStack(alignment: .top) {
                                Text(t.snippet).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                                Spacer(minLength: 0)
                                if t.unread { Circle().fill(Theme.brand).frame(width: 8, height: 8).padding(.top, 5) }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .tag(t.id)
                }
                .listStyle(.inset)
                .overlay {
                    if link.smsThreads.isEmpty {
                        EmptyNote("No messages yet", "Tap Grant permissions in the phone app, then press Refresh.", icon: "message")
                    }
                }
            }
            .frame(minWidth: 230, idealWidth: 280, maxWidth: 360)

            VStack(spacing: 0) {
                if composing {
                    HStack {
                        Text("To:").foregroundStyle(.secondary)
                        TextField("Phone number", text: $to).textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    Divider()
                    EmptyNote("New message", "Type a number above and your text below.", icon: "square.and.pencil")
                } else if let t = thread {
                    HStack(spacing: 10) {
                        Avatar(name: t.title, size: 32)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(t.title).fontWeight(.semibold)
                            if !t.name.isEmpty { Text(t.address).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    Divider()
                    Conversation(messages: link.smsMessages[t.id] ?? [])
                } else {
                    EmptyNote("Select a conversation", "Or press New Message to text a number.", icon: "bubble.left.and.bubble.right")
                }
                if composing || thread != nil {
                    HStack(alignment: .bottom, spacing: 8) {
                        TextField("Text message", text: $draft, axis: .vertical)
                            .textFieldStyle(.plain).lineLimit(1...5)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .onSubmit(sendDraft)
                        Button(action: sendDraft) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 28)) }
                            .buttonStyle(.plain)
                            .foregroundStyle(canSend ? Theme.brand : Color.secondary.opacity(0.5))
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(!canSend)
                    }
                    .padding(12)
                }
            }
            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            Button { startCompose("") } label: { Label("New Message", systemImage: "square.and.pencil") }.disabled(!link.connected)
            Button { link.loadSMSThreads(); if let s = selected { link.loadSMS(s) } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(!link.connected)
        }
        .onAppear {
            if link.connected { link.loadSMSThreads() }
            if let number = nav.composeTo { nav.composeTo = nil; startCompose(number) }
        }
        .onChange(of: link.connected) { _, on in if on { link.loadSMSThreads() } }
        .onChange(of: selected) { _, id in
            link.openThread = id
            if let id { composing = false; link.loadSMS(id) }
        }
        .onDisappear { link.openThread = nil }
    }

    private var recipient: String { (composing ? to : thread?.address ?? "").trimmingCharacters(in: .whitespaces) }
    private var canSend: Bool { link.connected && !draft.isEmpty && !recipient.isEmpty }

    /// Opens the existing conversation with that number if there is one, otherwise a blank composer.
    private func startCompose(_ number: String) {
        let digits = number.filter(\.isNumber)
        if !digits.isEmpty, let existing = link.smsThreads.first(where: { $0.address.filter(\.isNumber).hasSuffix(digits) || digits.hasSuffix($0.address.filter(\.isNumber)) && !$0.address.isEmpty }) {
            selected = existing.id
            return
        }
        composing = true; selected = nil; to = number
    }

    private func sendDraft() {
        guard canSend else { return }
        link.sendSMS(to: recipient, text: draft)
        draft = ""
        // The phone reports the change once the message is stored; a new conversation then appears in the list.
        if composing { composing = false }
    }
}

struct Conversation: View {
    let messages: [SMSMessage]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(Array(messages.enumerated()), id: \.element.id) { i, m in
                        // A time stamp wherever the conversation paused for a while.
                        if i == 0 || m.date.timeIntervalSince(messages[i - 1].date) > 1800 {
                            Text(m.date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                                .font(.caption2).foregroundStyle(.secondary).padding(.top, 10).padding(.bottom, 4)
                        }
                        HStack {
                            if m.outgoing { Spacer(minLength: 80) }
                            Text(m.body)
                                .textSelection(.enabled)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(m.outgoing ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Color.secondary.opacity(0.16)),
                                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .foregroundStyle(m.outgoing ? Color.white : Color.primary)
                            if !m.outgoing { Spacer(minLength: 80) }
                        }
                        .padding(.top, i > 0 && messages[i - 1].outgoing != m.outgoing ? 6 : 0)
                        .id(m.id)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
            .onChange(of: messages) { _, new in if let last = new.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            .onAppear { if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) } }
        }
    }
}

// MARK: Clipboard

struct ClipboardView: View {
    @EnvironmentObject var link: Link
    @EnvironmentObject var native: Native

    var body: some View {
        Page(width: 680) {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: native.clipboardAuto ? "arrow.left.arrow.right.circle.fill" : "arrow.right.circle.fill")
                            .font(.title2).foregroundStyle(Theme.brand)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(native.clipboardAuto ? "Two-way clipboard" : "Mac to phone").font(.headline)
                            Text(native.clipboardAuto
                                 ? "Copy on either device, paste on the other."
                                 : "Phone to Mac needs the native setup in Phone Screen. Until then use the Clipboard to Mac tile on the phone.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $link.autoClipboard).toggleStyle(.switch).labelsHidden()
                    }
                    if !native.clipboardAuto || !link.autoClipboard {
                        Button("Send Mac clipboard now") { link.sendClipboard() }.disabled(!link.connected)
                    }
                }
            }
            if link.clips.isEmpty {
                EmptyNote("Nothing shared yet", "Text you copy will be listed here so you can grab it again.", icon: "doc.on.clipboard")
                    .frame(minHeight: 220)
            } else {
                Text("Recent").font(.headline).padding(.top, 4)
                ForEach(link.clips) { ClipRow(c: $0) }
            }
        }
    }
}

struct ClipRow: View {
    let c: ClipEntry
    @State private var hover = false
    @State private var copied = false

    var body: some View {
        Card(padding: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: c.fromPhone ? "iphone" : "laptopcomputer").foregroundStyle(.secondary).frame(width: 22)
                VStack(alignment: .leading, spacing: 4) {
                    Text(c.text).lineLimit(4).textSelection(.enabled)
                    Text((c.fromPhone ? "From phone" : "From Mac") + " · " + relative(c.date)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(c.text, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                }
                .opacity(hover || copied ? 1 : 0)
            }
        }
        .onHover { hover = $0 }
    }
}

// MARK: Files

struct FilesView: View {
    @EnvironmentObject var link: Link
    @State private var targeted = false

    var body: some View {
        Page(width: 680) {
            VStack(spacing: 10) {
                Image(systemName: "arrow.up.doc").font(.system(size: 30, weight: .light))
                    .foregroundStyle(targeted ? Theme.brand : Color.secondary)
                Text("Drop files here to send them to your phone").font(.headline)
                Text("They land in Downloads/AndroMac on the phone.").font(.callout).foregroundStyle(.secondary)
                Button("Choose files…") { chooseFiles(link) }.padding(.top, 2)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 28)
            .background((targeted ? Theme.brand.opacity(0.10) : Theme.card), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7]))
                .foregroundStyle(targeted ? Theme.brand : Color.secondary.opacity(0.4)))
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                for p in providers {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in if let url { link.sendFile(url) } }
                }
                return true
            }
            .disabled(!link.connected)
            .opacity(link.connected ? 1 : 0.5)

            if !link.transfers.isEmpty {
                Text("Transfers").font(.headline).padding(.top, 4)
                Card(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(link.transfers.enumerated()), id: \.element.id) { i, t in
                            if i > 0 { Divider().padding(.leading, 52) }
                            TransferRow(t: t)
                        }
                    }
                }
            } else {
                Text("Files sent from the phone are saved to your Downloads folder.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

struct TransferRow: View {
    let t: Transfer

    private var fileIcon: NSImage {
        let type = UTType(filenameExtension: (t.name as NSString).pathExtension) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: fileIcon).resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(t.name).lineLimit(1).truncationMode(.middle)
                Text(t.incoming ? "From phone" : "To phone").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if t.failed { Pill(text: "Failed", icon: "xmark.circle.fill", color: .red) }
            else if !t.done { ProgressView().controlSize(.small) }
            else if t.incoming, let url = t.url {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.buttonStyle(.link)
            } else { Pill(text: "Sent", icon: "checkmark", color: .green) }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }
}

// MARK: Photos

struct PhotosView: View {
    @EnvironmentObject var link: Link
    @State private var viewing: Photo?
    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 6)]

    var body: some View {
        Group {
            if link.photos.isEmpty {
                EmptyNote("No photos loaded", "Grant photo access in the phone app, then press Refresh.", icon: "photo.on.rectangle.angled")
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(link.photos) { p in PhotoCell(photo: p) { viewing = p } }
                    }
                    .padding(16)
                    if link.morePhotos { Button("Load more") { link.loadPhotos(more: true) }.padding(.bottom, 16) }
                }
            }
        }
        .toolbar { Button { link.loadPhotos() } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(!link.connected) }
        .onAppear { if link.photos.isEmpty, link.connected { link.loadPhotos() } }
        // The viewer covers this pane only. A sheet would block the whole window, sidebar included, until closed.
        .overlay {
            if viewing != nil { PhotoViewer(photo: $viewing).transition(.opacity) }
        }
        .animation(.easeOut(duration: 0.15), value: viewing != nil)
    }
}

struct PhotoCell: View {
    @EnvironmentObject var link: Link
    let photo: Photo
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        Color.secondary.opacity(0.12)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let img = link.thumbs[photo.id] {
                    Image(nsImage: img).resizable().scaledToFill()
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(hover ? 0.9 : 0), lineWidth: 2))
            .shadow(color: .black.opacity(hover ? 0.25 : 0), radius: 8, y: 3)
            .scaleEffect(hover ? 1.03 : 1)
            .animation(.easeOut(duration: 0.12), value: hover)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onAppear { link.requestThumb(photo.id) }
            .onTapGesture(perform: open)
            .contextMenu { Button("Save to Downloads") { link.savePhoto(photo) } }
            .help(photo.name)
    }
}

/// Full-size view of one photo, with arrows to move through the loaded list.
struct PhotoViewer: View {
    @EnvironmentObject var link: Link
    @Binding var photo: Photo?
    @State private var full: NSImage?
    @State private var fullID: Int64?

    private var index: Int? { photo.flatMap { p in link.photos.firstIndex(of: p) } }

    private func step(_ by: Int) {
        guard let i = index, link.photos.indices.contains(i + by) else { return }
        photo = link.photos[i + by]
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let p = photo {
                    if let full, fullID == p.id {
                        Image(nsImage: full).resizable().scaledToFit()
                    } else {
                        // Show the thumbnail straight away and sharpen once the full photo arrives.
                        if let t = link.thumbs[p.id] { Image(nsImage: t).resizable().scaledToFit().opacity(0.6) }
                        ProgressView().controlSize(.large)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Button { step(-1) } label: { Image(systemName: "chevron.left") }
                    .keyboardShortcut(.leftArrow, modifiers: []).disabled((index ?? 0) == 0)
                Button { step(1) } label: { Image(systemName: "chevron.right") }
                    .keyboardShortcut(.rightArrow, modifiers: []).disabled(index.map { $0 >= link.photos.count - 1 } ?? true)
                Text(photo?.name ?? "").lineLimit(1).foregroundStyle(.secondary)
                if let i = index { Text("\(i + 1) of \(link.photos.count)").font(.caption).foregroundStyle(.tertiary) }
                Spacer()
                Button("Open in Preview") {
                    if let p = photo, let url = link.fullPhotos[p.id] { NSWorkspace.shared.open(url) }
                }
                .disabled(photo.flatMap { link.fullPhotos[$0.id] } == nil)
                Button("Save to Downloads") { if let p = photo { link.savePhoto(p) } }
                Button("Done") { photo = nil }.keyboardShortcut(.cancelAction).buttonStyle(.borderedProminent)
            }
            .padding(12)
            .background(.bar)
        }
        .onAppear(perform: load)
        .onChange(of: photo) { _, _ in load() }
        .onChange(of: link.fullPhotos) { _, _ in load() }
    }

    private func load() {
        guard let p = photo else { return }
        guard let url = link.fullPhotos[p.id], FileManager.default.fileExists(atPath: url.path) else {
            link.viewPhoto(p.id)
            return
        }
        if fullID == p.id, full != nil { return }
        let id = p.id
        DispatchQueue.global(qos: .userInitiated).async {
            let img = NSImage(contentsOf: url)
            DispatchQueue.main.async { if photo?.id == id { full = img; fullID = id } }
        }
    }
}

// MARK: Contacts

struct ContactsView: View {
    @EnvironmentObject var link: Link
    @EnvironmentObject var nav: Nav
    @State private var search = ""

    private var shown: [Contact] {
        search.isEmpty ? link.contacts : link.contacts.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.phones.contains { $0.contains(search) }
        }
    }

    var body: some View {
        List(shown) { c in ContactRow(c: c) { number in nav.composeTo = number; nav.pane = .messages } }
            .listStyle(.inset)
            .searchable(text: $search, prompt: "Search contacts")
            .overlay {
                if link.contacts.isEmpty {
                    EmptyNote("No contacts loaded", "Grant contacts access in the phone app, then press Refresh.", icon: "person.2")
                }
            }
            .toolbar { Button { link.loadContacts() } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(!link.connected) }
            .onAppear { if link.contacts.isEmpty, link.connected { link.loadContacts() } }
    }
}

struct ContactRow: View {
    let c: Contact
    let message: (String) -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            Avatar(name: c.name, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(c.name).fontWeight(.medium)
                Text(c.phones.joined(separator: "  ·  ")).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1)
            }
            Spacer()
            if hover, let first = c.phones.first {
                Button { message(first) } label: { Label("Message", systemImage: "message") }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(first, forType: .string)
                } label: { Label("Copy number", systemImage: "doc.on.doc") }.labelStyle(.iconOnly)
            }
        }
        .padding(.vertical, 3)
        .onHover { hover = $0 }
    }
}

// MARK: Phone screen

struct MirrorView: View {
    @EnvironmentObject var link: Link
    @EnvironmentObject var native: Native
    @AppStorage("screenOff") private var screenOff = true

    var body: some View {
        Group {
            if link.mirroring { casting } else { chooser }
        }
        .onAppear { if !native.ready { native.refresh(phoneIP: link.phoneIP) } }
        .onChange(of: link.phoneIP) { _, ip in if !native.ready { native.refresh(phoneIP: ip) } }
    }

    private var chooser: some View {
        Page(width: 680) {
            Card(padding: 22) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 14) {
                        RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.gradient).frame(width: 56, height: 56)
                            .overlay(Image(systemName: "iphone").font(.system(size: 26)).foregroundStyle(.white))
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text("Use your phone on this Mac").font(.title3.weight(.semibold))
                                if native.ready { Pill(text: "Ready", icon: "checkmark.circle.fill", color: .green) }
                            }
                            Text("The whole phone in its own window, with mouse, keyboard, copy and paste, and sound. Nothing to approve on the phone.")
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if native.ready {
                        HStack(spacing: 14) {
                            Button {
                                native.openScreen(title: link.phoneName.isEmpty ? "Phone" : link.phoneName, screenOff: screenOff)
                            } label: { Label("Open phone screen", systemImage: "play.fill").padding(.horizontal, 6) }
                                .buttonStyle(.borderedProminent).controlSize(.large)
                            Toggle("Keep the phone's own display dark", isOn: $screenOff)
                        }
                        if let p = native.problem { Label(p, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                    } else {
                        Divider()
                        Text(native.problem ?? "Looking for the phone…")
                            .foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Button(native.busy ? "Checking…" : "Check again") { native.refresh(phoneIP: link.phoneIP) }
                            .disabled(native.busy)
                    }
                }
            }
            Card {
                HStack(spacing: 12) {
                    Image(systemName: "dot.radiowaves.left.and.right").font(.title2).foregroundStyle(.secondary).frame(width: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cast instead").font(.headline)
                        Text("No setup, but the phone asks for permission every time and its screen must stay on.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Start casting") { link.startMirror() }.disabled(!link.connected)
                }
            }
        }
    }

    private var casting: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Button { link.input(["k": "key", "key": "back"]) } label: { Label("Back", systemImage: "chevron.backward") }
                Button { link.input(["k": "key", "key": "home"]) } label: { Label("Home", systemImage: "circle") }
                Button { link.input(["k": "key", "key": "recents"]) } label: { Label("Recents", systemImage: "square") }
                Spacer()
                if !link.accessibilityOn {
                    Pill(text: "View only: turn on remote control in the phone app", icon: "eye", color: .orange)
                }
                Button("Stop casting", role: .destructive) { link.stopMirror() }
            }
            VideoView(feed: link.screenFeed, sinkName: "mirror", videoSize: link.mirrorSize, onInput: { link.input($0) })
                .aspectRatio(link.mirrorSize.width / max(link.mirrorSize.height, 1), contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(16)
    }
}

// MARK: Apps

struct AppsView: View {
    @EnvironmentObject var link: Link
    @EnvironmentObject var native: Native
    @State private var search = ""
    @AppStorage("showSystemApps") private var showSystem = true

    /// The phone app's own list (with icons) when it has one; otherwise the list read over adb.
    private var all: [PhoneApp] { link.phoneApps.isEmpty ? native.apps : link.phoneApps }
    private var shown: [PhoneApp] {
        all.filter { (showSystem || !$0.system) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
    }

    var body: some View {
        Group {
            if all.isEmpty {
                EmptyNote(link.connected ? "Reading the app list…" : "No phone connected",
                          "Your phone's apps appear here. Click one to open it in its own window.", icon: "square.grid.2x2")
            } else {
                ScrollView {
                    if !native.ready {
                        Card(padding: 12) {
                            HStack {
                                Image(systemName: "info.circle").foregroundStyle(.orange)
                                Text("Opening apps needs the one-time setup in Phone Screen.").font(.callout)
                                Spacer()
                                Button(native.busy ? "Checking…" : "Check again") { native.refresh(phoneIP: link.phoneIP) }.disabled(native.busy)
                            }
                        }
                        .padding([.horizontal, .top], 16)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 14) {
                        ForEach(shown) { app in AppTile(app: app) { native.openApp(app) }.disabled(!native.ready) }
                    }
                    .padding(16)
                }
                .searchable(text: $search, prompt: "Search apps")
            }
        }
        .toolbar {
            Toggle("Built-in apps", isOn: $showSystem)
            Button { link.loadApps(); if native.ready { native.loadApps() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(!link.connected)
        }
        .onAppear {
            if link.connected, link.phoneApps.isEmpty { link.loadApps() }
            if !native.ready { native.refresh(phoneIP: link.phoneIP) } else if all.isEmpty { native.loadApps() }
        }
        .onChange(of: link.connected) { _, on in if on, link.phoneApps.isEmpty { link.loadApps() } }
        .overlay(alignment: .bottom) {
            if let p = native.problem, native.ready {
                Text(p).foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.red.opacity(0.85), in: Capsule()).padding(10)
            }
        }
    }
}

struct AppTile: View {
    @EnvironmentObject var link: Link
    let app: PhoneApp
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: open) {
            VStack(spacing: 6) {
                Group {
                    if let icon = link.appIcons[app.package] {
                        Image(nsImage: icon).resizable().interpolation(.high)
                    } else {
                        RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Theme.tint(for: app.name).gradient)
                            .overlay(Text(String(app.name.prefix(1)).uppercased())
                                .font(.system(size: 24, weight: .semibold, design: .rounded)).foregroundStyle(.white))
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                Text(app.name).font(.caption).lineLimit(2).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .top)
            }
            .padding(.vertical, 8).padding(.horizontal, 4)
            .background(hover ? Color.primary.opacity(0.07) : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .onAppear { link.requestIcon(app.package) }
        .help(app.package)
    }
}

// MARK: Camera

struct CameraView: View {
    @EnvironmentObject var link: Link
    @EnvironmentObject var webcam: Webcam
    @State private var front = false

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black)
                if link.cameraOn {
                    VideoView(feed: link.cameraFeed, sinkName: "camera-preview")
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "video").font(.system(size: 34, weight: .light)).foregroundStyle(.white.opacity(0.5))
                        Text("Use your phone as a camera").font(.title3.weight(.semibold)).foregroundStyle(.white)
                        Text("Hold the phone in landscape. The preview appears here.").foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: 900)

            HStack(spacing: 12) {
                if link.cameraOn {
                    Button("Stop camera", role: .destructive) {
                        if webcam.feeding { webcam.stop(feed: link.cameraFeed) }
                        link.stopCamera()
                    }
                    .controlSize(.large)
                } else {
                    Button { link.startCamera(front: front) } label: { Label("Start phone camera", systemImage: "video.fill") }
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(!link.connected)
                }
                Picker("", selection: $front) {
                    Text("Back").tag(false)
                    Text("Front").tag(true)
                }
                .pickerStyle(.segmented).frame(width: 140).labelsHidden()
                .onChange(of: front) { _, value in if link.cameraOn { link.startCamera(front: value) } }
                Spacer()
            }
            .frame(maxWidth: 900)

            Card(padding: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "web.camera").font(.title3).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Virtual webcam for Zoom, Meet and FaceTime").font(.callout.weight(.medium))
                        Text(webcam.status).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Install") { webcam.install() }
                    Button(webcam.feeding ? "Stop feeding" : "Feed") {
                        if webcam.feeding { webcam.stop(feed: link.cameraFeed) } else { webcam.start(feed: link.cameraFeed) }
                    }
                    .disabled(!link.cameraOn)
                }
            }
            .frame(maxWidth: 900)
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
    }
}

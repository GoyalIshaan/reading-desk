import SwiftUI

enum Companion: String, CaseIterable {
    case chatGPT = "ChatGPT"
    case claude = "Claude"
    case notes = "Notes"

    var url: URL? {
        switch self {
        case .chatGPT: URL(string: "https://chatgpt.com/")
        case .claude: URL(string: "https://claude.ai/")
        case .notes: nil
        }
    }
}

@MainActor
final class Room: ObservableObject {
    @Published private(set) var queue: [BrowserTab] = []
    @Published private(set) var index = 0
    @Published private(set) var shelf: Shelf = .other
    @Published private(set) var companion: Companion = UserDefaults.standard.string(forKey: "companion")
        .flatMap(Companion.init(rawValue:)) ?? .chatGPT

    let reader = WebPage()
    private var chats: [Companion: WebPage] = [:]

    var current: BrowserTab? { queue.indices.contains(index) ? queue[index] : nil }

    func start(_ tabs: [BrowserTab], at first: BrowserTab, in shelf: Shelf) {
        let next = tabs.filter { $0.readableURL != nil }
        guard let index = next.firstIndex(of: first) else { return }
        let previous = current
        self.shelf = shelf
        queue = next
        if previous == first { self.index = index }
        else { go(to: index) }
    }

    func go(to newIndex: Int) {
        guard queue.indices.contains(newIndex), let url = queue[newIndex].readableURL else { return }
        index = newIndex
        reader.load(url)
    }

    func choose(_ mode: Companion) {
        if mode != .notes { _ = chat(for: mode) }
        companion = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "companion")
    }

    func chat(for mode: Companion) -> WebPage? {
        if let page = chats[mode] { return page }
        guard let url = mode.url else { return nil }
        let page = WebPage()
        page.load(url)
        chats[mode] = page
        return page
    }

    func toggleNotes() {
        if companion == .notes {
            let saved = UserDefaults.standard.string(forKey: "lastChat").flatMap(Companion.init(rawValue:))
            choose(saved == .claude ? .claude : .chatGPT)
        } else {
            UserDefaults.standard.set(companion.rawValue, forKey: "lastChat")
            choose(.notes)
        }
    }
}

struct DeskView: View {
    @ObservedObject var library: Library
    @ObservedObject var room: Room
    @ObservedObject var vault: Vault
    @AppStorage("fullscreenOnOpen") private var fullscreenOnOpen = true
    @AppStorage("readerFraction") private var readerFraction = 0.61
    @State private var draggedFraction: Double?
    @State private var dividerHovered = false
    @State private var selectedShelf: Shelf?
    @State private var reading = false
    @State private var enteredFullScreen = false

    var body: some View {
        Group {
            if reading, let source = room.current {
                roomView(source)
            } else {
                LibraryView(library: library, selectedShelf: $selectedShelf, fullscreenOnOpen: $fullscreenOnOpen, open: open)
            }
        }
        .frame(minWidth: 860, minHeight: 550)
        .foregroundStyle(Theme.ink)
        .background(Theme.paper)
        .preferredColorScheme(.dark)
        .task { if !library.loaded { library.refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !reading && library.loaded { library.refresh() }
        }
    }

    private func open(_ shelf: Shelf, tab: BrowserTab? = nil) {
        let tabs = library.tabs.filter { library.shelf(for: $0) == shelf }
        guard let first = tab ?? tabs.first(where: { $0.readableURL != nil }) else { return }
        guard first.readableURL != nil else {
            if !library.sample {
                Task {
                    do { _ = try await Helium.run(["focus", first.windowID, first.id]) }
                    catch { library.error = error.localizedDescription }
                }
            }
            return
        }
        room.start(tabs, at: first, in: shelf)
        if room.companion != .notes { _ = room.chat(for: room.companion) }
        reading = true
        if fullscreenOnOpen, let window = NSApp.keyWindow, !window.styleMask.contains(.fullScreen) {
            enteredFullScreen = true
            window.toggleFullScreen(nil)
        }
    }

    private func closeRoom() {
        reading = false
        if enteredFullScreen, let window = NSApp.keyWindow, window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
        enteredFullScreen = false
        library.refresh()
    }

    private func roomView(_ source: BrowserTab) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Button { closeRoom() } label: { Label("Tab library", systemImage: "chevron.left") }
                    .buttonStyle(DeskButtonStyle())
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                Rectangle().fill(Theme.line).frame(width: 1, height: 21).padding(.horizontal, 2)
                Text(room.shelf.rawValue).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 8)
                HStack(spacing: 3) {
                    DeskIcon("chevron.left", help: "Previous source") { room.go(to: room.index - 1) }
                        .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                        .disabled(room.index == 0)
                    Menu {
                        ForEach(room.queue.indices, id: \.self) { index in
                            Button { room.go(to: index) } label: {
                                if room.index == index {
                                    Label(room.queue[index].displayTitle, systemImage: "checkmark")
                                } else {
                                    Text(room.queue[index].displayTitle)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text("\(room.index + 1) of \(room.queue.count)").monospacedDigit()
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("Source queue")
                    DeskIcon("chevron.right", help: "Next source") { room.go(to: room.index + 1) }
                        .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                        .disabled(room.index + 1 >= room.queue.count)
                }
                Rectangle().fill(Theme.line).frame(width: 1, height: 21).padding(.horizontal, 2)
                ForEach(Companion.allCases, id: \.self) { mode in
                    Button {
                        room.choose(mode)
                    } label: {
                        if mode != room.companion { Text(mode.rawValue) }
                        else { Label(mode.rawValue, systemImage: mode == .notes ? "doc.text" : "bubble.left") }
                    }
                    .buttonStyle(DeskButtonStyle(prominent: mode == room.companion))
                    .accessibilityAddTraits(mode == room.companion ? .isSelected : [])
                }
                Button("Toggle Notes") { room.toggleNotes() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .frame(width: 0, height: 0)
                    .clipped()
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 19)
            .frame(height: 49)
            .background(Theme.paper)
            SurfaceRule()

            GeometryReader { geometry in
                let width = Double(geometry.size.width - 8)
                let minimum = 400 / width
                let maximum = 1 - 335 / width
                let fraction = min(max(draggedFraction ?? readerFraction, minimum), maximum)
                HStack(spacing: 0) {
                    BrowserPane(page: room.reader)
                        .frame(width: CGFloat(width * fraction))
                    ZStack {
                        Rectangle().fill(dividerHovered ? Theme.accent.opacity(0.55) : Theme.line)
                            .frame(width: 1)
                        Capsule().fill(dividerHovered ? Theme.accent : Theme.muted)
                            .frame(width: 2, height: 20)
                    }
                    .frame(width: 8)
                    .frame(maxHeight: .infinity)
                    .background(Theme.paper)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        dividerHovered = inside
                        if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
                    }
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("split"))
                        .onChanged { draggedFraction = min(max((Double($0.location.x) - 4) / width, minimum), maximum) }
                        .onEnded { _ in
                            if let draggedFraction { readerFraction = draggedFraction }
                            draggedFraction = nil
                        })
                    .accessibilityLabel("Resize reading panes")
                    .accessibilityValue("\(Int(fraction * 100)) percent for source")
                    .accessibilityAdjustableAction { direction in
                        let change = direction == .increment ? 0.05 : -0.05
                        readerFraction = min(max(fraction + change, minimum), maximum)
                    }
                    Group {
                        if room.companion == .notes {
                            NotesPane(vault: vault, source: source)
                        } else if let page = room.chat(for: room.companion) {
                            BrowserPane(page: page).id(room.companion)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                }
                .coordinateSpace(name: "split")
            }
        }
    }
}

@MainActor
final class DeskDelegate: NSObject, NSApplicationDelegate {
    weak var vault: Vault?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let vault, vault.isDirty else { return .terminateNow }
        Task {
            if await vault.flush() {
                sender.reply(toApplicationShouldTerminate: true)
                return
            }
            let alert = NSAlert()
            alert.messageText = "A note has an unsaved draft."
            alert.informativeText = vault.error ?? "Return to the note to keep editing or copy your draft."
            alert.addButton(withTitle: "Keep Editing")
            alert.addButton(withTitle: "Discard Draft and Quit")
            sender.reply(toApplicationShouldTerminate: alert.runModal() == .alertSecondButtonReturn)
        }
        return .terminateLater
    }
}

@main
struct ReadingDeskApp: App {
    @NSApplicationDelegateAdaptor(DeskDelegate.self) private var delegate
    @StateObject private var library = Library()
    @StateObject private var room = Room()
    @StateObject private var vault = Vault()

    var body: some Scene {
        Window("Reading Desk", id: "desk") {
            DeskView(library: library, room: room, vault: vault)
                .onAppear { delegate.vault = vault }
        }
        .defaultSize(width: 1180, height: 770)
        .windowToolbarStyle(.unified(showsTitle: false))
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Library") {
                Button("Refresh Helium tabs") { library.refresh() }.keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}

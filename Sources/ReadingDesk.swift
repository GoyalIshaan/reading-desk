import SwiftUI

enum Companion: String, CaseIterable, Identifiable {
    case chatGPT = "ChatGPT"
    case claude = "Claude"
    case gemini = "Gemini"
    case notes = "Notes"

    var id: Self { self }

    var url: URL? {
        switch self {
        case .chatGPT: URL(string: "https://chatgpt.com/")
        case .claude: URL(string: "https://claude.ai/new")
        case .gemini: URL(string: "https://gemini.google.com/app")
        case .notes: nil
        }
    }
}

@MainActor
final class Room: ObservableObject {
    @Published private(set) var queue: [BrowserTab] = []
    @Published private(set) var index = 0
    @Published private(set) var categoryID = Category.otherID
    @Published private(set) var companion: Companion = UserDefaults.standard.string(forKey: "companion")
        .flatMap(Companion.init(rawValue:)) ?? .chatGPT

    let reader = WebPage()
    private var chats: [Companion: WebPage] = [:]

    var current: BrowserTab? { queue.indices.contains(index) ? queue[index] : nil }

    func start(_ tabs: [BrowserTab], at first: BrowserTab, in categoryID: String) {
        let next = tabs.filter { $0.readableURL != nil }
        guard let index = next.firstIndex(of: first) else { return }
        let previous = current
        self.categoryID = categoryID
        queue = next
        if previous == first { self.index = index }
        else { go(to: index) }
    }

    func go(to newIndex: Int) {
        guard queue.indices.contains(newIndex), let url = queue[newIndex].readableURL else { return }
        index = newIndex
        reader.load(url)
    }

    /// Drops a tab from the queue and moves on to the next one on the shelf.
    /// Returns false when the shelf is now empty.
    @discardableResult
    func remove(_ tab: BrowserTab) -> Bool {
        guard let removed = queue.firstIndex(of: tab) else { return !queue.isEmpty }
        queue.remove(at: removed)
        guard !queue.isEmpty else {
            index = 0
            return false
        }
        if removed == index { go(to: min(removed, queue.count - 1)) }
        else if removed < index { index -= 1 }
        return true
    }

    func choose(_ mode: Companion) {
        if mode != .notes {
            _ = chat(for: mode)
            UserDefaults.standard.set(mode.rawValue, forKey: "lastChat")
        }
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
            choose(saved.flatMap { $0 == .notes ? nil : $0 } ?? .chatGPT)
        } else {
            choose(.notes)
        }
    }
}

struct DeskView: View {
    @ObservedObject var library: Library
    @ObservedObject var room: Room
    @ObservedObject var vault: Vault
    /// Not observed here: preview updates should only re-render the library, never the reading room.
    let previews: Previews
    let renderer: NoteRenderer
    @AppStorage("fullscreenOnOpen") private var fullscreenOnOpen = true
    @AppStorage("closeInHelium") private var closeInHelium = true
    @AppStorage("readerFraction") private var readerFraction = 0.62
    @State private var draggedFraction: Double?
    @State private var dividerHovered = false
    @State private var selectedCategory: String?
    @State private var reading = false
    @State private var enteredFullScreen = false
    @State private var fullscreen = false
    @State private var showingQueue = false
    @State private var toast: String?
    @State private var paletteOpen = false
    @State private var toastTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .bottom) {
            // The library stays alive underneath so coming back is instant and keeps its scroll position.
            LibraryView(library: library, previews: previews, selectedCategory: $selectedCategory,
                        fullscreenOnOpen: $fullscreenOnOpen, closeInHelium: $closeInHelium,
                        topInset: fullscreen ? 0 : 1, open: open)
                .opacity(reading ? 0 : 1)
                .allowsHitTesting(!reading)
                .disabled(reading)
                .accessibilityHidden(reading)
            if reading, let source = room.current {
                roomView(source)
            }
            if paletteOpen {
                CommandPalette(library: library, previews: previews,
                               close: { withAnimation(.easeOut(duration: 0.14)) { paletteOpen = false } },
                               openTab: { tab in open(library.category(for: tab).id, tab: tab) },
                               openShelf: { id in
                                   if reading { closeRoom() }
                                   selectedCategory = id
                               })
                    .transition(.opacity)
                    .zIndex(2)
            }
            if let toast {
                Text(toast)
                    .font(Theme.sans(12.5, .medium))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 18).frame(height: 36)
                    .background(Capsule().fill(Theme.raised))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.08)))
                    .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
                    .padding(.bottom, 26)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .frame(minWidth: 920, minHeight: 580)
        .ignoresSafeArea()
        .foregroundStyle(Theme.ink)
        .background(Theme.ground)
        .preferredColorScheme(.dark)
        .task {
            if !library.loaded { library.refresh() }
            if NoteRenderer.debug {
                try? await Task.sleep(for: .seconds(1))
                if let tab = library.tabs.first(where: { $0.readableURL != nil }) { open(library.category(for: tab).id, tab: tab) }
                room.choose(.notes)
                await vault.refresh()
                if let note = vault.notes.first(where: { $0.path.contains("Attention") }) ?? vault.notes.first { await vault.open(note) }
            }
        }
        .onAppear { fullscreen = NSApp.keyWindow?.styleMask.contains(.fullScreen) ?? false }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !reading && library.loaded { library.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openPalette)) { _ in
            withAnimation(.easeOut(duration: 0.14)) { paletteOpen.toggle() }
        }
        .onReceive(Timer.publish(every: 45, on: .main, in: .common).autoconnect()) { _ in
            // Keep the library in step with Helium while it's on screen.
            if !reading && library.loaded && NSApp.isActive { library.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in fullscreen = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in fullscreen = false }
    }

    private func open(_ categoryID: String, tab: BrowserTab? = nil) {
        let tabs = library.tabs.filter { library.category(for: $0).id == categoryID }
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
        room.start(tabs, at: first, in: categoryID)
        if room.companion != .notes { _ = room.chat(for: room.companion) }
        previews.paused = true
        // Switch instantly; the full-screen animation is the only motion.
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { reading = true }
        if fullscreenOnOpen, let window = NSApp.keyWindow, !window.styleMask.contains(.fullScreen) {
            enteredFullScreen = true
            DispatchQueue.main.async { window.toggleFullScreen(nil) }
        }
    }

    private func closeRoom() {
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { reading = false }
        previews.paused = false
        if enteredFullScreen, let window = NSApp.keyWindow, window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
        enteredFullScreen = false
        library.refresh()
    }

    private func finish() {
        guard let tab = room.current else { return }
        library.finish(tab, closeInHelium: closeInHelium)
        if room.remove(tab) {
            showToast("Done · \(room.queue.count) left on this shelf")
        } else {
            selectedCategory = nil
            closeRoom()
            showToast("Shelf finished.")
        }
    }

    private func showToast(_ message: String) {
        toastTask?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { toast = message }
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { toast = nil }
        }
    }

    // MARK: Reading room

    private func roomView(_ source: BrowserTab) -> some View {
        let category = library.category(withID: room.categoryID) ?? library.other
        return VStack(spacing: 0) {
            if !fullscreen {
                // Room for the traffic lights; doubles as the window's drag area.
                Color.clear.frame(height: 28)
            }
            GeometryReader { geometry in
                let width = Double(geometry.size.width - 7)
                let minimum = 420 / width
                let maximum = max(minimum, 1 - 360 / width)
                let fraction = min(max(draggedFraction ?? readerFraction, minimum), maximum)
                HStack(spacing: 0) {
                    BrowserPane(page: room.reader)
                        .frame(width: CGFloat(width * fraction))
                    divider(fraction: fraction, width: width, minimum: minimum, maximum: maximum)
                    VStack(spacing: 0) {
                        companionHeader(category)
                        Group {
                            if room.companion == .notes {
                                NotesPane(vault: vault, renderer: renderer, source: source)
                            } else if let page = room.chat(for: room.companion) {
                                BrowserPane(page: page, showsChrome: false).id(room.companion)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                    }
                    .background(Theme.ground)
                }
                .coordinateSpace(name: "split")
            }
        }
        .background(Theme.ground)
        .background { roomShortcuts }
    }

    private var roomShortcuts: some View {
        ZStack {
            ShortcutButton("Back to library", "[", [.command, .shift]) { closeRoom() }
            ShortcutButton("Previous tab", .leftArrow, [.command, .option]) { room.go(to: room.index - 1) }
            ShortcutButton("Next tab", .rightArrow, [.command, .option]) { room.go(to: room.index + 1) }
            ShortcutButton("Done", "d", [.command, .shift]) { finish() }
            ShortcutButton("Toggle notes", "n", [.command, .shift]) { room.toggleNotes() }
            ShortcutButton("Page back", "[") { room.reader.view.goBack() }
            ShortcutButton("Page forward", "]") { room.reader.view.goForward() }
            ShortcutButton("Copy link", "c", [.command, .shift]) {
                room.reader.copyLink()
                showToast("Link copied")
            }
            ForEach(Array(Companion.allCases.enumerated()), id: \.element) { offset, mode in
                ShortcutButton(mode.rawValue, KeyEquivalent(Character("\(offset + 1)")), [.command, .option]) { room.choose(mode) }
            }
        }
    }

    private func divider(fraction: Double, width: Double, minimum: Double, maximum: Double) -> some View {
        let active = dividerHovered || draggedFraction != nil
        return Rectangle().fill(active ? Theme.accent : Theme.rule).frame(width: active ? 2 : 1)
            .frame(width: 7)
            .frame(maxHeight: .infinity)
            .background(Theme.ground)
            .contentShape(Rectangle())
            .onHover { inside in
                withAnimation(.easeOut(duration: 0.12)) { dividerHovered = inside }
                if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
            }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("split"))
                .onChanged { draggedFraction = min(max((Double($0.location.x) - 3.5) / width, minimum), maximum) }
                .onEnded { _ in
                    if let draggedFraction { readerFraction = draggedFraction }
                    draggedFraction = nil
                })
            .onTapGesture(count: 2) { readerFraction = 0.62 }
            .help("Drag to resize · double-click to reset")
            .accessibilityLabel("Resize reading panes")
            .accessibilityValue("\(Int(fraction * 100)) percent for the page")
            .accessibilityAdjustableAction { direction in
                let change = direction == .increment ? 0.05 : -0.05
                readerFraction = min(max(fraction + change, minimum), maximum)
            }
    }

    private func companionHeader(_ category: Category) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                BackButton(help: "Back to library (⇧⌘[)") { closeRoom() }
                Text(category.name)
                    .font(Theme.serif(17, italic: true))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
                Spacer(minLength: 6)
                HStack(spacing: 0) {
                    DeskIcon("chevron.left", help: "Previous tab (⌥⌘←)") { room.go(to: room.index - 1) }
                        .disabled(room.index == 0)
                    Button { showingQueue.toggle() } label: {
                        Text("\(room.index + 1) of \(room.queue.count)")
                            .font(Theme.mono(11, .medium)).foregroundStyle(Theme.ink2)
                            .padding(.horizontal, 4).frame(height: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("See every tab on this shelf")
                    .popover(isPresented: $showingQueue, arrowEdge: .bottom) { queuePopover }
                    DeskIcon("chevron.right", help: "Next tab (⌥⌘→)") { room.go(to: room.index + 1) }
                        .disabled(room.index + 1 >= room.queue.count)
                }
                Button { finish() } label: {
                    HStack(spacing: 6) { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)); Text("Done") }
                }
                .buttonStyle(DeskButtonStyle(.primary))
                .help(closeInHelium ? "Close this tab in Helium and open the next (⇧⌘D)" : "Mark read and open the next (⇧⌘D)")
            }
            .padding(.leading, 16).padding(.trailing, 12)
            .frame(height: 50)
            HStack(alignment: .top, spacing: 0) {
                CompanionTabs(selection: room.companion) { room.choose($0) }
                if room.companion != .notes, let page = room.chat(for: room.companion) {
                    ChatControls(page: page).padding(.top, -6)
                }
            }
            .padding(.horizontal, 16)
            Hairline()
        }
        .background(Theme.ground)
    }

    private var queuePopover: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(room.queue.enumerated()), id: \.element.id) { index, tab in
                        Button {
                            room.go(to: index)
                            showingQueue = false
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Group {
                                    if let image = previews.images[tab.address] {
                                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                                    } else {
                                        ZStack { Theme.surface; Favicon(icon: previews.icons[tab.host], site: tab.sourceName, size: 18) }
                                    }
                                }
                                .frame(width: 84, height: 54)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(index == room.index ? Theme.accent : Color.white.opacity(0.06), lineWidth: index == room.index ? 1.5 : 1))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(tab.displayTitle).font(Theme.serif(15.5, .medium)).foregroundStyle(Theme.ink).lineLimit(2)
                                    Text(tab.sourceName).font(Theme.mono(10)).foregroundStyle(Theme.ink3)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .background(index == room.index ? Theme.raised : .clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(index)
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(width: 380, height: min(CGFloat(room.queue.count) * 72 + 12, 480))
            .background(Theme.ground)
            .onAppear { proxy.scrollTo(room.index, anchor: .center) }
        }
        .preferredColorScheme(.dark)
    }
}

/// Text tabs with a vermilion underline that slides to the active one.
private struct CompanionTabs: View {
    let selection: Companion
    let choose: (Companion) -> Void
    @Namespace private var namespace
    @State private var hovered: Companion?

    var body: some View {
        HStack(spacing: 22) {
            ForEach(Companion.allCases) { mode in
                let selected = mode == selection
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { choose(mode) }
                } label: {
                    VStack(spacing: 8) {
                        Text(mode.rawValue)
                            .font(Theme.sans(13, selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Theme.ink : hovered == mode ? Theme.ink2 : Theme.ink3)
                        ZStack {
                            Rectangle().fill(.clear).frame(height: 2)
                            if selected {
                                Rectangle().fill(Theme.accent).frame(height: 2)
                                    .matchedGeometryEffect(id: "underline", in: namespace)
                            }
                        }
                    }
                    .fixedSize()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? mode : nil }
                .help("\(mode.rawValue) (⌥⌘\((Companion.allCases.firstIndex(of: mode) ?? 0) + 1))")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer()
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
    @StateObject private var previews = Previews()
    @StateObject private var renderer = NoteRenderer()

    var body: some Scene {
        Window("Reading Desk", id: "desk") {
            DeskView(library: library, room: room, vault: vault, previews: previews, renderer: renderer)
                .onAppear {
                    delegate.vault = vault
                    renderer.vault = vault
                }
        }
        .defaultSize(width: 1320, height: 860)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Library") {
                Button("Search Tabs…") { NotificationCenter.default.post(name: .openPalette, object: nil) }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Divider()
                Button("Refresh Helium Tabs") { library.refresh() }.keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}

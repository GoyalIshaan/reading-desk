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
    /// Kept in case the shelf gets deleted while we're reading it.
    private(set) var shelfName = ""
    @Published private(set) var companion: Companion = UserDefaults.standard.string(forKey: "companion")
        .flatMap(Companion.init(rawValue:)) ?? .chatGPT

    let reader = WebPage()
    private var chats: [Companion: WebPage] = [:]

    var current: BrowserTab? { queue.indices.contains(index) ? queue[index] : nil }

    func start(_ tabs: [BrowserTab], at first: BrowserTab, in categoryID: String, named shelfName: String) {
        let next = tabs.filter { $0.readableURL != nil }
        guard let index = next.firstIndex(of: first) else { return }
        let canKeepPage = current == first
        self.categoryID = categoryID
        self.shelfName = shelfName
        queue = next
        if canKeepPage { self.index = index }
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
    @AppStorage("fullscreenOnOpen") private var fullscreenOnOpen = false
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
    @State private var editingShelves = false
    @State private var toastTask: Task<Void, Never>?
    /// Drives the library → reader transition: false while the room is still arriving.
    @State private var revealed = false
    @State private var hero: Hero?
    @State private var heroTask: Task<Void, Never>?
    @State private var transition = 0
    @State private var windowSize: CGSize = .zero
    /// The floating dock at the bottom of the page: hidden until the pointer comes near.
    @State private var dockHover = false
    @State private var dockFlash = false
    @State private var dockFlashTask: Task<Void, Never>?
    @State private var dockMonitor: Any?
    @State private var bridge: DeskBridge?
    /// Only one Claude sort runs at a time.
    @State private var organizing = false
    /// URLs already sent to auto-sort this session, so leftovers aren't re-sent.
    @State private var autoSortTried: Set<String> = []
    @State private var autoSortFailures: [String: (count: Int, until: Date)] = [:]

    private var dockVisible: Bool { dockHover || dockFlash || showingQueue }
    private var titleBarHeight: CGFloat { fullscreen ? 0 : 28 }

    struct Hero {
        var image: NSImage?
        var title: String
        var site: String
        var from: CGRect
        var expanded = false
    }

    /// Where the reading pane sits, so the hero card can land exactly on it.
    private var readerRect: CGRect {
        let top = titleBarHeight
        let width = Double(windowSize.width - 7)
        guard width > 0 else { return .zero }
        let minimum = 420 / width
        let maximum = max(minimum, 1 - 360 / width)
        let fraction = min(max(readerFraction, minimum), maximum)
        return CGRect(x: 0, y: top, width: CGFloat(width * fraction), height: windowSize.height - top)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // The library stays alive underneath so coming back is instant and keeps its scroll position.
            LibraryView(library: library, previews: previews, selectedCategory: $selectedCategory,
                        closeInHelium: closeInHelium, titleBarHeight: titleBarHeight, open: open)
                .opacity(reading && revealed ? 0 : 1)
                .scaleEffect(reading && revealed ? 0.965 : 1, anchor: .center)
                .allowsHitTesting(!reading)
                .disabled(reading)
                .accessibilityHidden(reading)
            if reading, let source = room.current {
                roomView(source)
            }
            if let hero {
                let rect = hero.expanded ? readerRect : hero.from
                HeroCover(hero: hero)
                    .frame(width: rect.width, height: rect.height)
                    .clipShape(RoundedRectangle(cornerRadius: hero.expanded ? 0 : 6, style: .continuous))
                    .shadow(color: .black.opacity(hero.expanded ? 0 : 0.5), radius: 30, y: 14)
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .zIndex(1)
            }
            if paletteOpen {
                CommandPalette(library: library, previews: previews,
                               fullscreenOnOpen: fullscreenOnOpen, closeInHelium: closeInHelium,
                               close: { withAnimation(.easeOut(duration: 0.14)) { paletteOpen = false } },
                               openTab: { tab in open(library.category(for: tab).id, tab, nil) },
                               openShelf: showShelf, performCommand: performPaletteCommand)
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
                    .padding(.bottom, reading ? 84 : 26)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .frame(minWidth: 920, minHeight: 580)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { windowSize = proxy.size }
                    .onChange(of: proxy.size) { _, size in windowSize = size }
            }
        }
        .ignoresSafeArea()
        .foregroundStyle(Theme.ink)
        .background(Theme.ground)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $editingShelves) { ShelvesEditor(library: library) }
        .task {
            if bridge == nil {
                let bridge = DeskBridge(library: library)
                bridge.start()
                self.bridge = bridge
            }
            if !library.loaded { library.refresh() }
            if NoteRenderer.debug {
                try? await Task.sleep(for: .seconds(1))
                if let tab = library.tabs.first(where: { $0.readableURL != nil }) { open(library.category(for: tab).id, tab, nil) }
                room.choose(.notes)
                await vault.refresh()
                if let note = vault.notes.first(where: { $0.path.contains("Attention") }) ?? vault.notes.first { await vault.open(note) }
            }
        }
        .onAppear { fullscreen = NSApp.keyWindow?.styleMask.contains(.fullScreen) ?? false }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !reading && library.loaded { library.refresh() }
        }
        .onChange(of: library.tabs) { _, _ in autoSortIfNeeded() }
        .onChange(of: library.autoSortShelves) { _, _ in autoSortIfNeeded() }
        .onReceive(NotificationCenter.default.publisher(for: .openPalette)) { _ in
            withAnimation(.easeOut(duration: 0.14)) { paletteOpen.toggle() }
        }
        .onReceive(Timer.publish(every: 45, on: .main, in: .common).autoconnect()) { _ in
            // Keep the library in step with Helium while it's on screen.
            if !reading && library.loaded && NSApp.isActive { library.refresh() }
            autoSortIfNeeded()  // retry shelves whose backoff has expired
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in fullscreen = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in fullscreen = false }
    }

    private func showShelf(_ id: String?) {
        if reading { closeRoom() }
        selectedCategory = id
    }

    private func performPaletteCommand(_ command: CommandPalette.Command) {
        switch command {
        case .allShelves: showShelf(nil)
        case .refresh: library.refresh()
        case .editShelves: editingShelves = true
        case .organize: organizeShelf()
        case .toggleFullscreen: fullscreenOnOpen.toggle()
        case .toggleCloseInHelium: closeInHelium.toggle()
        }
    }

    /// ⇧⌘P → "Sort this shelf…": sorts the shelf on screen, or the one being read.
    private func organizeShelf() {
        guard !organizing else { return showToast("Claude is still sorting a shelf…") }
        let id = reading ? room.categoryID : selectedCategory
        guard let id, let shelf = library.category(withID: id), !shelf.isOther else {
            return showToast("Open a shelf first, then sort it.")
        }
        organizing = true
        showToast("Claude is sorting \(shelf.name)…", for: nil)
        bridge?.flush()
        Task {
            let outcome = await ShelfAgent.organize(shelfID: id)
            organizing = false
            showToast(outcome.message, for: 5)
            autoSortIfNeeded()
        }
    }

    /// After a refresh, send new tabs on auto-sort shelves to Claude, one shelf at a time.
    /// A shelf that keeps failing backs off (10 min, 20 min) and gives up after 3 tries.
    private func autoSortIfNeeded() {
        let maxNewShelves = 2, maxFailures = 3, backoff: TimeInterval = 600
        guard !organizing, !library.sample, !library.autoSortShelves.isEmpty else { return }
        let groups = library.grouped()
        for entry in library.tree.flattened() where library.autoSortShelves.contains(entry.category.id) {
            let shelf = entry.category
            let failure = autoSortFailures[shelf.id]
            if let failure, failure.count >= maxFailures || failure.until > .now { continue }
            let fresh = (groups[shelf.id] ?? []).map(\.address).filter { !autoSortTried.contains($0) }
            guard !shelf.isOther, !library.tree.children(of: shelf.id).isEmpty, !fresh.isEmpty else { continue }
            autoSortTried.formUnion(fresh)
            organizing = true
            bridge?.flush()
            Task {
                let outcome = await ShelfAgent.organize(shelfID: shelf.id, maxNew: maxNewShelves, urls: fresh)
                organizing = false
                if outcome.succeeded {
                    autoSortFailures[shelf.id] = nil
                    if outcome.filedAny { showToast(outcome.message, for: 4) }
                } else {
                    let count = (failure?.count ?? 0) + 1
                    autoSortFailures[shelf.id] = (count, .now.addingTimeInterval(backoff * Double(count)))
                    autoSortTried.subtract(fresh)
                    showToast(count >= maxFailures ? "Auto-sort for \(shelf.name) is off until you reopen the app: \(outcome.message)"
                                         : "Auto-sort for \(shelf.name) paused: \(outcome.message)", for: 6)
                }
                autoSortIfNeeded()  // next shelf, if any
            }
            return
        }
    }

    private func open(_ categoryID: String, _ tab: BrowserTab?, _ origin: CGRect?) {
        // Includes sub-shelves, in the same order as the library page.
        let tabs = library.orderedTabs(in: categoryID)
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
        room.start(tabs, at: first, in: categoryID, named: library.pathName(of: categoryID))
        if room.companion != .notes { _ = room.chat(for: room.companion) }
        previews.paused = true
        transition += 1
        let id = transition

        // 1. The room appears underneath, still "unrevealed"; the tapped card's
        //    cover sits exactly where the card was.
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) {
            revealed = false
            hero = origin.map { Hero(image: previews.images[first.address], title: first.displayTitle, site: first.sourceName, from: $0) }
            reading = true
        }
        // 2. Next frame: the cover grows into the reading pane while the library
        //    recedes and the side column slides in.
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.9)) {
                revealed = true
                hero?.expanded = true
            }
        }
        // 3. Once the real page is there, the cover dissolves into it.
        heroTask?.cancel()
        heroTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(560))
            for _ in 0..<14 where room.reader.state.loading {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !Task.isCancelled, transition == id else { return }
            withAnimation(.easeOut(duration: 0.35)) { hero = nil }
            if fullscreenOnOpen, let window = NSApp.keyWindow, !window.styleMask.contains(.fullScreen) {
                enteredFullScreen = true
                window.toggleFullScreen(nil)
            }
        }
    }

    private func closeRoom() {
        heroTask?.cancel()
        hero = nil
        transition += 1
        let id = transition
        withAnimation(.easeOut(duration: 0.24)) { revealed = false }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard transition == id else { return }
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { reading = false }
        }
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

    /// Pass `seconds: nil` to keep the toast up until the next one replaces it.
    private func showToast(_ message: String, for seconds: Double? = 2.2) {
        toastTask?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { toast = message }
        guard let seconds else { return }
        toastTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { toast = nil }
        }
    }

    // MARK: Reading room

    /// The tapped card's cover, in flight from the grid to the reading pane.
    private struct HeroCover: View {
        let hero: Hero

        var body: some View {
            ZStack(alignment: .topLeading) {
                Theme.surface
                if let image = hero.image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .clipped()
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(hero.site).font(Theme.mono(11)).foregroundStyle(Theme.ink3)
                        Text(hero.title).font(Theme.serif(30)).foregroundStyle(Theme.ink).lineLimit(5)
                    }
                    .padding(32)
                }
            }
        }
    }

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
                    BrowserPane(page: room.reader, showsChrome: false)
                        .frame(width: CGFloat(width * fraction))
                        .overlay(alignment: .bottom) { dock().padding(.bottom, 18) }
                        .opacity(revealed ? 1 : 0)
                    divider(fraction: fraction, width: width, minimum: minimum, maximum: maximum)
                        .opacity(revealed ? 1 : 0)
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
                    .offset(x: revealed ? 0 : 56)
                    .opacity(revealed ? 1 : 0)
                }
                .coordinateSpace(name: "split")
            }
        }
        // Fades in so the library can be seen receding behind it.
        .background(Theme.ground.opacity(revealed ? 1 : 0))
        .background { roomShortcuts }
        .onAppear(perform: installDockMonitor)
        .onDisappear(perform: removeDockMonitor)
        .onChange(of: room.index) { _, _ in flashDock() }
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
            HStack(alignment: .top, spacing: 0) {
                CompanionTabs(selection: room.companion) { room.choose($0) }
                if room.companion != .notes, let page = room.chat(for: room.companion) {
                    ChatControls(page: page).padding(.top, -6)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            Hairline()
        }
        .background(Theme.ground)
    }

    // MARK: Floating dock

    private func dock() -> some View {
        // Fall back to the saved name if the shelf was deleted while reading.
        let shelf = library.category(withID: room.categoryID) == nil ? room.shelfName : library.pathName(of: room.categoryID)
        return ReaderDock(page: room.reader, shelf: shelf, index: room.index, count: room.queue.count,
                   closeInHelium: closeInHelium, showingQueue: $showingQueue,
                   back: { closeRoom() },
                   previous: { room.go(to: room.index - 1) },
                   next: { room.go(to: room.index + 1) },
                   done: { finish() },
                   copied: { showToast("Link copied") },
                   queue: { AnyView(queuePopover) })
            .opacity(dockVisible ? 1 : 0)
            .offset(y: dockVisible ? 0 : 10)
            .allowsHitTesting(dockVisible)
            .animation(.easeOut(duration: dockVisible ? 0.16 : 0.4), value: dockVisible)
    }

    /// Shows the dock for a moment so it's discoverable, then lets it fade.
    private func flashDock() {
        dockFlashTask?.cancel()
        dockFlash = true
        dockFlashTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            dockFlash = false
        }
    }

    /// Watches the pointer instead of laying an invisible hover area over the
    /// page, which would swallow clicks meant for the page itself.
    private func installDockMonitor() {
        guard dockMonitor == nil else { return }
        NSApp.windows.forEach { $0.acceptsMouseMovedEvents = true }
        dockMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { event in
            guard let content = event.window?.contentView else { return event }
            let point = event.locationInWindow
            let y = content.bounds.height - point.y
            let pane = readerRect
            let near = point.x >= pane.minX && point.x <= pane.maxX && y >= pane.maxY - 120 && y <= pane.maxY + 2
            if near != dockHover { dockHover = near }
            return event
        }
        flashDock()
    }

    private func removeDockMonitor() {
        if let dockMonitor { NSEvent.removeMonitor(dockMonitor) }
        dockMonitor = nil
        dockHover = false
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

/// Floating controls for the page: library, shelf position, page history, Done.
private struct ReaderDock: View {
    @ObservedObject var page: WebPage
    let shelf: String
    let index: Int
    let count: Int
    let closeInHelium: Bool
    @Binding var showingQueue: Bool
    let back: () -> Void
    let previous: () -> Void
    let next: () -> Void
    let done: () -> Void
    let copied: () -> Void
    let queue: () -> AnyView

    var body: some View {
        ViewThatFits(in: .horizontal) {
            bar(full: true)
            bar(full: false)
        }
        .padding(.horizontal, 16)
    }

    private func bar(full: Bool) -> some View {
        HStack(spacing: 2) {
            BackButton(help: "Back to library (⇧⌘[)", action: back)
            if full {
                Text(shelf)
                    .font(Theme.serif(15, italic: true))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.leading, 6).padding(.trailing, 4)
            }
            separator
            DeskIcon("chevron.left", help: "Previous tab (⌥⌘←)", action: previous).disabled(index == 0)
            Button { showingQueue.toggle() } label: {
                Text("\(index + 1) of \(count)")
                    .font(Theme.mono(11, .medium)).foregroundStyle(Theme.ink2)
                    .padding(.horizontal, 3).frame(height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help("Every tab on this shelf")
            .popover(isPresented: $showingQueue, arrowEdge: .top) { queue() }
            DeskIcon("chevron.right", help: "Next tab (⌥⌘→)", action: next).disabled(index + 1 >= count)
            if full {
                separator
                DeskIcon("arrow.uturn.left", help: "Page back (⌘[)") { page.view.goBack() }.disabled(!page.state.back)
                DeskIcon("arrow.uturn.right", help: "Page forward (⌘])") { page.view.goForward() }.disabled(!page.state.forward)
                DeskIcon("link", help: "Copy link (⇧⌘C)") {
                    page.copyLink()
                    copied()
                }
                if let url = page.state.url {
                    DeskIcon("arrow.up.right", help: "Open in Helium") { Helium.open(url) }
                }
            }
            Button(action: done) {
                HStack(spacing: 6) { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)); Text("Done") }
            }
            .buttonStyle(DeskButtonStyle(.primary))
            .fixedSize()
            .padding(.leading, 6)
            .help(closeInHelium ? "Close this tab in Helium and open the next (⇧⌘D)" : "Mark read and open the next (⇧⌘D)")
        }
        .padding(.leading, 5).padding(.trailing, 5).padding(.vertical, 5)
        .background(Capsule().fill(Theme.raised.opacity(0.96)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.09)))
        .shadow(color: .black.opacity(0.45), radius: 22, y: 10)
        .fixedSize()
    }

    private var separator: some View {
        Rectangle().fill(Theme.rule).frame(width: 1, height: 18).padding(.horizontal, 6)
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
                Button("Command Palette…") { NotificationCenter.default.post(name: .openPalette, object: nil) }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Divider()
                Button("Refresh Helium Tabs") { library.refresh() }.keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}

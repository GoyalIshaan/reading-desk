import Combine
import SwiftUI
import WebKit

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

    let reader = WebPage(captures: true)
    /// Set while the source is a PDF, which reads in PDFKit instead of the web view.
    @Published private(set) var paper: PaperReader?
    /// The passage selected on the page right now, if any.
    @Published var excerpt: Excerpt?
    private var chats: [Companion: WebPage] = [:]
    /// Chats from least to most recently used. Each chat page is its own web process
    /// (often hundreds of MB once a conversation is long), so only two stay loaded.
    private var chatOrder: [Companion] = []
    private static let liveChats = 2
    /// Set after a while back in the library: the reader and chats were unloaded to free memory.
    private var asleep = false
    /// PDFs PDFKit couldn't open; they stay in the web view.
    private var pdfFailed: Set<URL> = []
    /// The paper came from a web page turning out to be a PDF, so leaving that page closes it.
    private var paperFollowsWeb = false
    private var cancellables: Set<AnyCancellable> = []

    /// What the right-click menu asks for; DeskView carries it out.
    enum Action { case save, ask(Companion), readLater, bibtex, contents }
    let actions = PassthroughSubject<Action, Never>()

    var current: BrowserTab? { queue.indices.contains(index) ? queue[index] : nil }

    init() {
        reader.onCapture = { [weak self] message, webView in self?.handleCapture(message, from: webView) }
        reader.menuItems = { [weak self] in self?.menuItems() ?? [] }
        reader.onPDF = { [weak self] url in
            guard let self, self.paper?.url != url.removingFragment, !self.pdfFailed.contains(url.removingFragment) else { return }
            self.openPaper(url, followsWeb: true)
        }
        reader.$state
            .map(\.url)
            .removeDuplicates()
            .sink { [weak self] url in
                guard let self, let url else { return }
                self.excerpt = nil
                if self.paperFollowsWeb, let paper = self.paper, url.removingFragment != paper.url { self.paper = nil }
            }
            .store(in: &cancellables)
    }

    /// The address of what's on screen: the PDF, the page you navigated to, or the tab.
    var currentURL: URL? { paper?.url ?? reader.state.url ?? current?.readableURL }

    var lastChat: Companion {
        UserDefaults.standard.string(forKey: "lastChat").flatMap(Companion.init(rawValue:)).flatMap { $0 == .notes ? nil : $0 } ?? .chatGPT
    }

    var sourceTitle: String {
        let title = current?.displayTitle.trimmed ?? ""
        if let paperTitle = paper?.title, !paperTitle.isEmpty, title.isEmpty || title.lowercased().hasSuffix(".pdf") || title.hasPrefix("http") {
            return paperTitle
        }
        return title.isEmpty ? (currentURL?.absoluteString ?? "Untitled") : title
    }

    var isPaper: Bool { paper != nil || BibTeX.isPaper(currentURL) }

    /// arXiv abstract pages have a PDF one click away; PDFs have their abstract page.
    var arxivSwitch: (pdf: Bool, url: URL)? {
        guard let url = currentURL, let id = SourceKey.arxivID(url) else { return nil }
        if paper != nil { return (false, URL(string: "https://arxiv.org/abs/" + id)!) }
        return (true, URL(string: "https://arxiv.org/pdf/" + id)!)
    }

    private func load(_ url: URL) {
        excerpt = nil
        if url.looksLikePDF && !pdfFailed.contains(url.removingFragment) {
            openPaper(url, followsWeb: false)
        } else {
            paper = nil
            reader.load(url)
        }
    }

    func openPaper(_ url: URL, followsWeb: Bool) {
        let paper = PaperReader(url: url)
        paper.onSelection = { [weak self, weak paper] partial in
            guard let self, let paper, self.paper === paper else { return }
            self.excerpt = partial.map { $0.excerpt(title: self.sourceTitle, url: paper.url) }
        }
        paper.view.onSelectionMoved = { [weak self] rect in self?.excerpt?.rect = rect }
        paper.view.extraMenuItems = { [weak self] in self?.menuItems() ?? [] }
        paperFollowsWeb = followsWeb
        excerpt = nil
        self.paper = paper
        Task {
            await paper.load()
            guard paper.failure != nil, self.paper === paper else { return }
            pdfFailed.insert(paper.url)
            self.paper = nil
            if !followsWeb { reader.load(url) }
        }
    }

    /// Right-click on the page: the selection's actions first, then the page's.
    private func menuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let send: (Action) -> () -> Void = { action in { [weak self] in self?.actions.send(action) } }
        if excerpt != nil {
            items.append(ActionMenuItem("Save to Note", symbol: "text.quote", handler: send(.save)))
            for mode in Companion.allCases where mode != .notes {
                items.append(ActionMenuItem("Ask \(mode.rawValue)", symbol: "bubble.left", handler: send(.ask(mode))))
            }
            items.append(.separator())
        }
        items.append(ActionMenuItem("Read Later", symbol: "bookmark", handler: send(.readLater)))
        if isPaper { items.append(ActionMenuItem("Copy BibTeX", symbol: "quote.bubble", handler: send(.bibtex))) }
        items.append(ActionMenuItem(paper != nil ? "Sections…" : "Headings…", symbol: "list.bullet.indent", handler: send(.contents)))
        return items
    }

    /// arXiv: flip between the abstract page and the PDF.
    func switchArxiv() {
        guard let target = arxivSwitch else { return }
        if target.pdf { openPaper(target.url, followsWeb: false) }
        else {
            paper = nil
            excerpt = nil
            if reader.state.url.flatMap(SourceKey.arxivID) == nil || reader.state.url?.path.hasPrefix("/pdf") == true {
                reader.load(target.url)
            }
        }
    }

    func copyLink() {
        guard let url = currentURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    private func handleCapture(_ message: [String: Any], from webView: WKWebView) {
        guard paper == nil, let type = message["type"] as? String else { return }
        let scale: CGFloat = {
            guard let viewport = (message["viewport"] as? Double) ?? (message["viewport"] as? Int).map(Double.init), viewport > 0 else { return 1 }
            return webView.bounds.width / CGFloat(viewport)
        }()
        // A window opened from a link sits under a 38-point header inside the pane.
        let top: CGFloat = webView === reader.view ? 0 : 38
        func rect() -> CGRect? {
            guard let box = message["rect"] as? [String: Any] else { return nil }
            func number(_ key: String) -> CGFloat { CGFloat((box[key] as? Double) ?? (box[key] as? Int).map(Double.init) ?? 0) }
            return CGRect(x: number("x") * scale, y: number("y") * scale + top, width: number("w") * scale, height: number("h") * scale)
        }
        switch type {
        case "selection":
            if WebPage.debugCapture { NSLog("RD capture: selection rect=\(String(describing: rect())) empty=\(message["empty"] ?? false)") }
            guard message["empty"] as? Bool != true, let raw = message["text"] as? String,
                  let url = webView.url ?? reader.state.url ?? current?.readableURL else {
                excerpt = nil
                return
            }
            let kind: Excerpt.Kind = message["kind"] as? String == "code" ? .code(language: message["language"] as? String) : .prose
            let text = kind == .prose ? Excerpt.tidy(raw) : raw.replacingOccurrences(of: "\u{00A0}", with: " ")
            guard !text.trimmed.isEmpty else { excerpt = nil; return }
            excerpt = Excerpt(text: text, plain: (message["plain"] as? String) ?? raw, kind: kind,
                              section: message["section"] as? String, sourceTitle: sourceTitle,
                              sourceURL: url.removingFragment, rect: rect())
        case "selectionRect":
            if excerpt != nil { excerpt?.rect = rect() }
        default:
            break
        }
    }

    /// Drafts a question about the passage in a chat. Nothing is sent: the
    /// excerpt and its source land in the composer, and the caret waits after it.
    func ask(_ excerpt: Excerpt, in mode: Companion) async -> Bool {
        choose(mode)
        guard let page = chat(for: mode) else { return false }
        for _ in 0..<50 where page.state.loading || page.state.url == nil {
            try? await Task.sleep(for: .milliseconds(200))
        }
        for attempt in 0..<8 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(450)) }
            page.view.window?.makeFirstResponder(page.view)
            let result = try? await page.view.callAsyncJavaScript(ChatDraft.insert, arguments: ["text": excerpt.prompt],
                                                                 in: nil, contentWorld: .defaultClient)
            if result as? Bool == true || (result as? NSNumber)?.boolValue == true { return true }
        }
        return false
    }

    func start(_ tabs: [BrowserTab], at first: BrowserTab, in categoryID: String, named shelfName: String) {
        let next = tabs.filter { $0.readableURL != nil }
        guard let index = next.firstIndex(of: first) else { return }
        let canKeepPage = current == first && !asleep
        asleep = false
        self.categoryID = categoryID
        self.shelfName = shelfName
        queue = next
        if canKeepPage { self.index = index }
        else { go(to: index) }
    }

    func go(to newIndex: Int) {
        guard queue.indices.contains(newIndex), let url = queue[newIndex].readableURL else { return }
        index = newIndex
        load(url)
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
        guard mode != .notes else { return nil }
        chatOrder.removeAll { $0 == mode }
        chatOrder.append(mode)
        if let page = chats[mode] { return page }
        guard let url = mode.url else { return nil }
        let page = WebPage()
        page.load(url)
        chats[mode] = page
        while chatOrder.count > Self.liveChats {
            let oldest = chatOrder.removeFirst()
            chats[oldest]?.view.stopLoading()
            chats[oldest] = nil
        }
        return page
    }

    /// Back in the library for a while: let go of the page, the PDF and the chats.
    /// Everything reloads (scroll position included) the next time you start reading.
    func sleep() {
        guard !asleep else { return }
        asleep = true
        excerpt = nil
        paper = nil
        for page in chats.values { page.view.stopLoading() }
        chats = [:]
        chatOrder = []
        reader.unload()
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
    @AppStorage("resumeOnLaunch") private var resumeOnLaunch = true
    @State private var resumed = false
    @State private var showingContents = false
    @State private var sleepTask: Task<Void, Never>?
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
    @State private var openTask: Task<Void, Never>?
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
    /// "shelfID|url" pairs already sent to auto-sort, so leftovers aren't re-sent.
    /// Saved across launches; keyed per shelf so a triaged tab can still be sub-sorted.
    @State private var autoSortTried = Set(UserDefaults.standard.stringArray(forKey: "autoSortTried.v1") ?? [])
    @State private var autoSortFailures: [String: (count: Int, until: Date)] = [:]

    private var dockVisible: Bool { dockHover || dockFlash || showingQueue || showingContents }
    private var titleBarHeight: CGFloat { fullscreen ? 0 : 28 }

    /// Where the reading pane sits (for the dock's hover zone).
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
            LibraryView(library: library, previews: previews, notes: vault.index, selectedCategory: $selectedCategory,
                        closeInHelium: closeInHelium, titleBarHeight: titleBarHeight, open: open)
                .opacity(reading && revealed ? 0 : 1)
                .allowsHitTesting(!reading)
                .disabled(reading)
                .accessibilityHidden(reading)
            if reading, let source = room.current {
                roomView(source)
            }
            if paletteOpen {
                CommandPalette(library: library, previews: previews,
                               fullscreenOnOpen: fullscreenOnOpen, closeInHelium: closeInHelium,
                               resumeOnLaunch: resumeOnLaunch,
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
            if library.loaded { resumeIfNeeded() }
            // Index the vault up front, so cards and pages can show the notes you already have.
            if vault.root != nil { await vault.refresh() }
            if WebPage.debugCapture {
                try? await Task.sleep(for: .seconds(1))
                if let tab = library.tabs.first(where: { $0.address.contains("paulgraham") }) { open(library.category(for: tab).id, tab, nil) }
                try? await Task.sleep(for: .seconds(7))
                NSLog("RD capture: excerpt=\(room.excerpt.map { "\($0.text.prefix(40)) rect \(String(describing: $0.rect))" } ?? "nil") reading=\(reading) revealed=\(revealed)")
                let menu = NSMenu()
                if let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    room.reader.view.willOpenMenu(menu, with: event)
                }
                NSLog("RD capture: menu items → \(menu.items.map(\.title))")
                room.excerpt = nil
                _ = try? await room.reader.view.evaluateJavaScript("window.open(location.href, '_blank'); 1")
                try? await Task.sleep(for: .seconds(8))
                NSLog("RD capture: child excerpt=\(room.excerpt.map { "url \($0.sourceURL) rect \(String(describing: $0.rect))" } ?? "nil") opened=\(room.reader.openedPage != nil)")
                if let child = room.reader.openedPage, let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    let childMenu = NSMenu()
                    child.view.willOpenMenu(childMenu, with: event)
                    NSLog("RD capture: child menu items → \(childMenu.items.map(\.title))")
                }
            }
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
            if vault.root != nil { Task { await vault.refresh() } }
        }
        .onChange(of: library.loaded) { _, loaded in if loaded { resumeIfNeeded() } }
        .onChange(of: room.current?.address) { _, address in
            saveSession()
            guard reading, let address else { return }
            let count = vault.index.count(for: address)
            if count > 0 && room.companion != .notes {
                showToast(count == 1 ? "You have a note on this page, under Notes" : "You have \(count) notes on this page, under Notes")
            }
        }
        .onChange(of: vault.selection) { _, _ in saveSession() }
        .onReceive(room.actions) { action in
            switch action {
            case .save: saveHighlight()
            case .ask(let mode): ask(mode)
            case .readLater: readLater()
            case .bibtex: copyBibTeX()
            case .contents:
                flashDock()
                showingContents = true
            }
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
        case .toggleResume: resumeOnLaunch.toggle()
        case .continueReading: resume(ReadingMemory.session)
        }
    }

    // MARK: Continue reading

    /// On launch, put you back on the page (and note) you had open when you quit.
    private func resumeIfNeeded() {
        guard !resumed else { return }
        resumed = true
        // Sample data, or a failed Helium import, says nothing about whether your page is still open.
        guard resumeOnLaunch, !NoteRenderer.debug, !library.sample, library.error == nil else { return }
        resume(ReadingMemory.session)
    }

    private func resume(_ session: ReadingMemory.Session?) {
        guard let session else { return }
        let tab = library.tabs.first { $0.address == session.address }
            ?? library.tabs.first { SourceKey.key(for: $0.address) == SourceKey.key(for: session.address) && SourceKey.key(for: session.address) != nil }
        guard let tab else {
            showToast("“\(session.title)” isn’t open in Helium any more")
            if !library.sample && library.lastUpdated != nil { ReadingMemory.session = nil }
            return
        }
        open(library.category(for: tab).id, tab, nil)
        guard let path = session.notePath else { return }
        Task {
            if vault.notes.isEmpty { await vault.refresh() }
            if let note = vault.note(atPath: path), vault.selection != note { await vault.open(note) }
        }
    }

    private func saveSession() {
        guard reading, !library.sample, let tab = room.current else { return }
        ReadingMemory.session = ReadingMemory.Session(categoryID: room.categoryID, address: tab.address,
                                                      title: tab.displayTitle, notePath: vault.selection?.path)
    }

    // MARK: Highlights, questions, papers

    private func saveHighlight() {
        guard let excerpt = room.excerpt, let tab = room.current else {
            showToast("Select a passage on the page first")
            return
        }
        guard vault.root != nil else {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { room.choose(.notes) }
            showToast("Connect your Obsidian vault to save highlights")
            return
        }
        room.excerpt = nil
        Task {
            guard await vault.capture(excerpt.noteBlock, from: tab), let note = vault.selection else {
                showToast(vault.error ?? "Couldn’t save to the note")
                return
            }
            renderer.startEditingAtEnd(note, text: vault.text)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { room.choose(.notes) }
            showToast("Saved to “\(note.name)”")
        }
    }

    private func ask(_ mode: Companion) {
        guard let excerpt = room.excerpt else {
            showToast("Select a passage on the page first")
            return
        }
        room.excerpt = nil
        Task {
            if await room.ask(excerpt, in: mode) { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(excerpt.prompt, forType: .string)
            showToast("Couldn’t reach the \(mode.rawValue) box. The question is on your clipboard")
        }
    }

    private func readLater() {
        guard let tab = room.current else { return }
        if library.isSaved(tab) {
            showToast("Already on Read later")
            return
        }
        library.saveForLater(tab, closeInHelium: closeInHelium)
        showToast(closeInHelium && tab.windowID != SavedSource.windowID ? "Saved to Read later · closed in Helium" : "Saved to Read later")
    }

    private func copyBibTeX() {
        guard let url = room.currentURL else { return }
        let title = room.sourceTitle
        showToast("Looking up BibTeX…")
        Task {
            let entry = await BibTeX.entry(for: url, title: title)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.text, forType: .string)
            showToast(entry.published ? "BibTeX copied" : "No published BibTeX. Copied a @misc entry")
        }
    }

    /// ⇧⌘P → "Sort this shelf…": sorts the shelf on screen, or the one being read.
    private func organizeShelf() {
        guard !organizing else { return showToast("Claude is still sorting a shelf…") }
        let id = reading ? room.categoryID : selectedCategory
        guard let id, let shelf = library.category(withID: id) else {
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

    /// After a refresh, send new tabs on auto-sort shelves to Claude, one shelf at a time
    /// and at most 25 tabs per run. Unsorted is triaged into any shelf; other
    /// shelves are sorted into their sub-shelves. A shelf that keeps failing backs off
    /// (10 min, 20 min) and gives up after 3 tries.
    private func autoSortIfNeeded() {
        let maxNewShelves = 2, maxFailures = 3, backoff: TimeInterval = 600, batchSize = 25
        guard !organizing, !library.sample, !library.autoSortShelves.isEmpty else { return }
        let groups = library.grouped()
        for entry in library.tree.flattened() where library.autoSortShelves.contains(entry.category.id) {
            let shelf = entry.category
            let failure = autoSortFailures[shelf.id]
            if let failure, failure.count >= maxFailures || failure.until > .now { continue }
            guard shelf.isOther || !library.tree.children(of: shelf.id).isEmpty else { continue }
            // In Unsorted, skip tabs the user pinned there on purpose.
            let candidates = (groups[shelf.id] ?? []).filter {
                !shelf.isOther || (library.assignments[$0.address] == nil && library.siteRules[$0.site] == nil)
            }
            let fresh = Array(candidates.map(\.address)
                .filter { !autoSortTried.contains("\(shelf.id)|\($0)") }
                .prefix(batchSize))
            guard !fresh.isEmpty else { continue }
            markTried(shelf.id, fresh, tried: true)
            organizing = true
            bridge?.flush()
            Task {
                let outcome = await ShelfAgent.organize(shelfID: shelf.id, maxNew: shelf.isOther ? 0 : maxNewShelves,
                                                        urls: fresh)
                organizing = false
                if outcome.succeeded {
                    autoSortFailures[shelf.id] = nil
                    if outcome.filedAny { showToast(outcome.message, for: 4) }
                } else {
                    let count = (failure?.count ?? 0) + 1
                    autoSortFailures[shelf.id] = (count, .now.addingTimeInterval(backoff * Double(count)))
                    markTried(shelf.id, fresh, tried: false)  // let them be retried after the backoff
                    showToast(count >= maxFailures ? "Auto-sort for \(shelf.name) is off until you reopen the app: \(outcome.message)"
                                         : "Auto-sort for \(shelf.name) paused: \(outcome.message)", for: 6)
                }
                autoSortIfNeeded()  // next shelf, if any
            }
            return
        }
    }

    private func markTried(_ shelfID: String, _ urls: [String], tried: Bool) {
        let keys = urls.map { "\(shelfID)|\($0)" }
        if tried { autoSortTried.formUnion(keys) } else { autoSortTried.subtract(keys) }
        if autoSortTried.count > 5000 { autoSortTried = Set(keys) }  // crude cap so the saved list can't grow forever
        UserDefaults.standard.set(Array(autoSortTried), forKey: "autoSortTried.v1")
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
        sleepTask?.cancel()
        room.start(tabs, at: first, in: categoryID, named: library.pathName(of: categoryID))
        saveSession()
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
            reading = true
        }
        // 2. Next frame: a short crossfade. (A cover that grew into the page looked
        //    nice in theory but stuttered while the page loaded underneath it.)
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.18)) { revealed = true }
        }
        // 3. Once the page has had a moment to load, go full screen if that's the setting.
        openTask?.cancel()
        openTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(560))
            guard !Task.isCancelled, transition == id else { return }
            if fullscreenOnOpen, let window = NSApp.keyWindow, !window.styleMask.contains(.fullScreen) {
                enteredFullScreen = true
                window.toggleFullScreen(nil)
            }
        }
    }

    private func closeRoom() {
        if !library.sample { ReadingMemory.session = nil }
        room.excerpt = nil
        openTask?.cancel()
        transition += 1
        let id = transition
        withAnimation(.easeOut(duration: 0.16)) { revealed = false }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(170))
            guard transition == id else { return }
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { reading = false }
        }
        previews.paused = false
        sleepTask?.cancel()
        sleepTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(300))
            guard !Task.isCancelled, !reading else { return }
            room.sleep()
        }
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
                    readerPane
                        .frame(width: CGFloat(width * fraction))
                        .overlay(alignment: .bottom) { dock().padding(.bottom, 18) }
                        .opacity(revealed ? 1 : 0)
                    divider(fraction: fraction, width: width, minimum: minimum, maximum: maximum)
                        .opacity(revealed ? 1 : 0)
                    VStack(spacing: 0) {
                        companionHeader(category)
                        Group {
                            if room.companion == .notes {
                                NotesPane(vault: vault, renderer: renderer, index: vault.index, source: source)
                            } else if let page = room.chat(for: room.companion) {
                                BrowserPane(page: page, showsChrome: false).id(room.companion)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                    }
                    .background(Theme.ground)
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

    /// The page (or PDF), with the Save / Ask bar floating over whatever you've selected.
    private var readerPane: some View {
        ZStack {
            BrowserPane(page: room.reader, showsChrome: false)
            if let paper = room.paper {
                PaperPane(paper: paper).id(ObjectIdentifier(paper))
            }
        }
        .overlay {
            GeometryReader { proxy in
                if let excerpt = room.excerpt, let rect = excerpt.rect, revealed,
                   rect.maxY > 0, rect.minY < proxy.size.height {
                    SelectionBar(lastChat: room.lastChat, save: saveHighlight, ask: ask)
                        .position(selectionBarPosition(rect, in: proxy.size))
                        .transition(.opacity.combined(with: .scale(scale: 0.94)))
                }
            }
            .animation(.easeOut(duration: 0.12), value: room.excerpt == nil)
        }
    }

    private func selectionBarPosition(_ rect: CGRect, in size: CGSize) -> CGPoint {
        let half = CGSize(width: 150, height: 17)
        let x = min(max(rect.midX, half.width + 12), max(half.width + 12, size.width - half.width - 12))
        var y = rect.minY - half.height - 10
        if y < half.height + 8 { y = rect.maxY + half.height + 10 }
        y = min(max(y, half.height + 8), max(half.height + 8, size.height - half.height - 86))
        return CGPoint(x: x, y: y)
    }

    private var roomShortcuts: some View {
        ZStack {
            ShortcutButton("Save highlight to note", "s", [.command, .shift]) { saveHighlight() }
            ShortcutButton("Ask about this", "a", [.command, .shift]) { ask(room.lastChat) }
            ShortcutButton("Read later", "l", [.command, .shift]) { readLater() }
            ShortcutButton("Copy BibTeX", "b", [.command, .shift]) { copyBibTeX() }
            ShortcutButton("Contents", "o", [.command, .shift]) { showingContents.toggle(); flashDock() }
            ShortcutButton("Back to library", "[", [.command, .shift]) { closeRoom() }
            ShortcutButton("Previous tab", .leftArrow, [.command, .option]) { room.go(to: room.index - 1) }
            ShortcutButton("Next tab", .rightArrow, [.command, .option]) { room.go(to: room.index + 1) }
            ShortcutButton("Done", "d", [.command, .shift]) { finish() }
            ShortcutButton("Toggle notes", "n", [.command, .shift]) { room.toggleNotes() }
            ShortcutButton("Page back", "[") { room.reader.view.goBack() }
            ShortcutButton("Page forward", "]") { room.reader.view.goForward() }
            ShortcutButton("Copy link", "c", [.command, .shift]) {
                room.copyLink()
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
                CompanionTabs(selection: room.companion, index: vault.index, address: room.current?.address ?? "") { room.choose($0) }
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
        return ReaderDock(page: room.reader, paper: room.paper, url: room.currentURL, shelf: shelf,
                   index: room.index, count: room.queue.count,
                   closeInHelium: closeInHelium, isPaper: room.isPaper,
                   saved: room.current.map(library.isSaved) ?? false,
                   arxivSwitch: room.arxivSwitch?.pdf,
                   showingQueue: $showingQueue, showingContents: $showingContents,
                   back: { closeRoom() },
                   previous: { room.go(to: room.index - 1) },
                   next: { room.go(to: room.index + 1) },
                   done: { finish() },
                   copyLink: {
                       room.copyLink()
                       showToast("Link copied")
                   },
                   readLater: readLater,
                   bibtex: copyBibTeX,
                   switchArxiv: { room.switchArxiv() },
                   queue: { AnyView(queuePopover) },
                   contents: { AnyView(ContentsList(room: room) { showingContents = false }) })
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

/// Floating controls for the page: library, shelf position, page history, paper tools, Done.
private struct ReaderDock: View {
    @ObservedObject var page: WebPage
    let paper: PaperReader?
    let url: URL?
    let shelf: String
    let index: Int
    let count: Int
    let closeInHelium: Bool
    let isPaper: Bool
    let saved: Bool
    /// arXiv: true offers the PDF, false offers the abstract page.
    let arxivSwitch: Bool?
    @Binding var showingQueue: Bool
    @Binding var showingContents: Bool
    let back: () -> Void
    let previous: () -> Void
    let next: () -> Void
    let done: () -> Void
    let copyLink: () -> Void
    let readLater: () -> Void
    let bibtex: () -> Void
    let switchArxiv: () -> Void
    let queue: () -> AnyView
    let contents: () -> AnyView

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
            separator
            Button { showingContents.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "list.bullet.indent").font(.system(size: 12))
                    if let paper { PaperPageLabel(paper: paper) }
                }
                .foregroundStyle(showingContents ? Theme.ink : Theme.ink3)
                .padding(.horizontal, 6).frame(height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help(paper != nil ? "Sections of this PDF" : "Headings on this page")
            .popover(isPresented: $showingContents, arrowEdge: .top) { contents() }
            if let arxivSwitch {
                DeskIcon(arxivSwitch ? "doc.richtext" : "doc.plaintext",
                         help: arxivSwitch ? "Read the PDF" : "Back to the abstract page", action: switchArxiv)
            }
            if isPaper {
                DeskIcon("quote.bubble", help: "Copy BibTeX", action: bibtex)
            }
            DeskIcon(saved ? "bookmark.fill" : "bookmark", help: saved ? "On Read later" : "Read later", action: readLater)
                .foregroundStyle(saved ? Theme.accent : Theme.ink3)
            if full {
                separator
                if paper == nil {
                    DeskIcon("arrow.uturn.left", help: "Page back (⌘[)") { page.view.goBack() }.disabled(!page.state.back)
                    DeskIcon("arrow.uturn.right", help: "Page forward (⌘])") { page.view.goForward() }.disabled(!page.state.forward)
                }
                DeskIcon("link", help: "Copy link (⇧⌘C)", action: copyLink)
                if let url {
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

private struct PaperPageLabel: View {
    @ObservedObject var paper: PaperReader
    var body: some View {
        if paper.pageCount > 0 {
            Text("p. \(paper.pageIndex + 1)/\(paper.pageCount)").font(Theme.mono(10.5, .medium)).foregroundStyle(Theme.ink2)
        }
    }
}

/// The floating bar over a selection: keep it in the page's note, or ask a chat about it.
private struct SelectionBar: View {
    let lastChat: Companion
    let save: () -> Void
    let ask: (Companion) -> Void

    var body: some View {
        HStack(spacing: 0) {
            BarButton(symbol: "text.quote", title: "Save to note", help: "Quote this in the page’s note, with a link back to it", action: save)
            Rectangle().fill(Theme.rule).frame(width: 1, height: 16)
            BarButton(symbol: "bubble.left", title: "Ask \(lastChat.rawValue)",
                      help: "Draft a question about this in \(lastChat.rawValue). Nothing is sent") { ask(lastChat) }
            Menu {
                ForEach(Companion.allCases.filter { $0 != .notes }) { mode in
                    Button("Ask \(mode.rawValue)") { ask(mode) }
                }
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.ink3).frame(width: 22, height: 28)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Ask another chat")
        }
        .padding(.horizontal, 3).padding(.vertical, 2)
        .background(Capsule().fill(Theme.raised.opacity(0.98)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.11)))
        .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
        .fixedSize()
        .environment(\.colorScheme, .dark)
    }

    private struct BarButton: View {
        let symbol: String
        let title: String
        let help: String
        let action: () -> Void
        @State private var hovered = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 6) {
                    Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                    Text(title).font(Theme.sans(12, .medium))
                }
                .foregroundStyle(hovered ? Theme.ink : Theme.ink2)
                .padding(.horizontal, 11).frame(height: 28)
                .background(Capsule().fill(hovered ? Color.white.opacity(0.06) : .clear))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .help(help)
        }
    }
}

/// Sections of the PDF, or headings of the page, to jump between.
private struct ContentsList: View {
    @ObservedObject var room: Room
    let close: () -> Void
    @State private var headings: [Heading] = []
    @State private var loaded = false

    struct Heading: Identifiable { let id: Int; let level: Int; let text: String }

    var body: some View {
        Group {
            if let paper = room.paper {
                PaperContents(paper: paper, close: close)
            } else if !loaded {
                ProgressView().controlSize(.small).frame(width: 320, height: 80)
            } else if headings.isEmpty {
                Self.empty("This page has no headings.")
            } else {
                list(headings.map { ($0.id, $0.level, $0.text, false) }) { id in
                    room.reader.jump(toHeading: id)
                    close()
                }
            }
        }
        .background(Theme.ground)
        .preferredColorScheme(.dark)
        .task {
            guard room.paper == nil else { return }
            let found = await room.reader.outline()
            let minimum = found.map(\.level).min() ?? 1
            headings = found.enumerated().map { Heading(id: $0.offset, level: $0.element.level - minimum + 1, text: $0.element.text) }
            loaded = true
        }
    }

    private struct PaperContents: View {
        @ObservedObject var paper: PaperReader
        let close: () -> Void

        var body: some View {
            if paper.sections.isEmpty {
                ContentsList.empty(paper.pageCount > 0 ? "This PDF has no outline. \(paper.pageCount) pages." : "Still opening the PDF…")
            } else {
                let current = paper.section(forPage: paper.pageIndex)?.id
                ContentsList.list(paper.sections.map { ($0.id, $0.level, $0.title, $0.id == current) },
                                  trailing: { id in paper.sections.first { $0.id == id }.map { "\($0.pageIndex + 1)" } }) { id in
                    if let section = paper.sections.first(where: { $0.id == id }) { paper.go(to: section) }
                    close()
                }
            }
        }
    }

    fileprivate static func empty(_ message: String) -> some View {
        Text(message).font(Theme.serif(16, italic: true)).foregroundStyle(Theme.ink3)
            .padding(20).frame(width: 320, alignment: .leading)
    }

    private func list(_ rows: [(Int, Int, String, Bool)], select: @escaping (Int) -> Void) -> some View {
        Self.list(rows, trailing: { _ in nil }, select: select)
    }

    fileprivate static func list(_ rows: [(Int, Int, String, Bool)], trailing: @escaping (Int) -> String?,
                                 select: @escaping (Int) -> Void) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows, id: \.0) { id, level, title, current in
                        Button { select(id) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(title)
                                    .font(level <= 1 ? Theme.serif(16, .medium) : Theme.sans(12.5, level == 2 ? .medium : .regular))
                                    .foregroundStyle(current ? Theme.accent : level <= 2 ? Theme.ink : Theme.ink2)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 8)
                                if let page = trailing(id) {
                                    Text(page).font(Theme.mono(10)).foregroundStyle(Theme.ink4)
                                }
                            }
                            .padding(.leading, CGFloat(14 + (min(level, 4) - 1) * 14)).padding(.trailing, 14)
                            .padding(.vertical, 6)
                            .background(current ? Theme.raised : .clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(id)
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(width: 360, height: min(CGFloat(rows.count) * 34 + 14, 460))
            .onAppear { if let current = rows.first(where: \.3)?.0 { proxy.scrollTo(current, anchor: .center) } }
        }
    }
}

/// Text tabs with a vermilion underline that slides to the active one.
private struct CompanionTabs: View {
    let selection: Companion
    @ObservedObject var index: NoteIndex
    let address: String
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
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(mode.rawValue)
                                .font(Theme.sans(13, selected ? .semibold : .regular))
                                .foregroundStyle(selected ? Theme.ink : hovered == mode ? Theme.ink2 : Theme.ink3)
                            // Notes you already have on this page.
                            if mode == .notes, case let count = index.count(for: address), count > 0 {
                                Text("\(count)").font(Theme.mono(9.5, .medium)).foregroundStyle(Theme.accent)
                                    .baselineOffset(5)
                                    .help(count == 1 ? "You have a note on this page" : "You have \(count) notes on this page")
                            }
                        }
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

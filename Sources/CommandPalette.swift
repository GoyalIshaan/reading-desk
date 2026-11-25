import SwiftUI

extension Notification.Name {
    static let openPalette = Notification.Name("ReadingDesk.openPalette")
}

/// ⇧⌘P: commands and search over every tab and shelf. Tab matching and ranking
/// live in `SearchIndex`; this view only keeps the results for the current query, so
/// hovering and scrolling never re-run the search.
struct CommandPalette: View {
    @ObservedObject var library: Library
    @ObservedObject var previews: Previews
    let fullscreenOnOpen: Bool
    let closeInHelium: Bool
    var resumeOnLaunch = true
    let close: () -> Void
    let openTab: (BrowserTab) -> Void
    let openShelf: (String) -> Void
    let performCommand: (Command) -> Void

    @State private var query = ""
    @State private var selection = 0
    @State private var index = SearchIndex(documents: [])
    @State private var indexedTabs: [BrowserTab] = []
    @State private var results: [Item] = []
    /// Set by arrow keys only. Hover changes the selection without scrolling the list.
    @State private var scrollTarget: Int?
    @State private var keyMonitor: Any?
    @State private var wasPaused = false
    @State private var mouseLocation = NSEvent.mouseLocation
    @FocusState private var focused: Bool

    enum Command: String, CaseIterable {
        case continueReading, allShelves, refresh, editShelves, organize, toggleFullscreen, toggleCloseInHelium, toggleResume

        var label: (title: String, symbol: String, keywords: String) {
            switch self {
            case .allShelves: ("Show all shelves", "square.grid.2x2", "everything back library")
            case .refresh: ("Refresh Helium tabs", "arrow.clockwise", "reload import update")
            case .editShelves: ("Edit shelves and filing rules", "books.vertical", "manage categories autofiling")
            case .organize: ("Sort this shelf with Claude", "wand.and.stars",
                             "agent ai organize file categorize subshelves nested auto triage")
            case .toggleFullscreen: ("Enter full screen when reading", "arrow.up.left.and.arrow.down.right", "fullscreen settings reading options")
            case .toggleCloseInHelium: ("Close Helium tabs when marked done", "xmark.circle", "keep tabs open settings reading options")
            case .continueReading: ("Continue where I left off", "book", "resume last session reopen")
            case .toggleResume: ("Reopen where I left off on launch", "clock.arrow.circlepath", "resume continue session settings reading options")
            }
        }
    }

    struct Item: Identifiable {
        /// `path` / `shelf` hold the full shelf path, e.g. "Parent › Child".
        enum Kind { case command(Command), shelf(Category, path: String, count: Int), tab(BrowserTab, shelf: String) }
        enum Section { case commands, shelves, tabs }
        let kind: Kind
        var words: Set<String> = []
        var snippet: String?
        var detail: String?

        var id: String {
            switch kind {
            case .command(let command): "command:" + command.rawValue
            case .shelf(let category, _, _): "shelf:" + category.id
            case .tab(let tab, _): "tab:" + tab.id
            }
        }

        var section: Section {
            switch kind {
            case .command: .commands
            case .shelf: .shelves
            case .tab: .tabs
            }
        }
    }

    // MARK: Search

    private func rebuildIndex() {
        indexedTabs = library.tabs
        index = SearchIndex(documents: indexedTabs.map { tab in
            let preview = previews.info[tab.address]
            let path = tab.url.map { $0.path + " " + ($0.query ?? "") } ?? tab.address
            return [
                .title: tab.displayTitle,
                .site: tab.site + " " + (preview?.siteName ?? ""),
                .shelf: library.pathName(of: library.category(for: tab).id),
                .address: path,
                .summary: preview?.summary ?? "",
                .body: preview?.text ?? "",
            ]
        })
        runSearch(keepSelection: true)
    }

    /// A new query starts at the top. A refresh of the same query (tabs changed)
    /// keeps whichever row was selected, so the list never jumps under you.
    private func runSearch(keepSelection: Bool = false) {
        let selectedID = keepSelection && results.indices.contains(selection) ? results[selection].id : nil
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let terms = SearchIndex.queryTerms(trimmed)
        let commands = Command.allCases.compactMap { command -> Item? in
            if command == .continueReading && ReadingMemory.session == nil { return nil }
            let label = command.label
            let words = SearchIndex.words(in: label.title + " " + label.keywords)
            guard terms.allSatisfy({ term in words.contains { $0.hasPrefix(term) } }) else { return nil }
            let detail: String? = switch command {
            case .toggleFullscreen: fullscreenOnOpen ? "On" : "Off"
            case .toggleCloseInHelium: closeInHelium ? "On" : "Off"
            case .toggleResume: resumeOnLaunch ? "On" : "Off"
            case .continueReading: ReadingMemory.session?.title
            default: nil
            }
            return Item(kind: .command(command), detail: detail)
        }
        // Non-empty shelves in tree order; counts include sub-shelves.
        let totals = library.totals(library.grouped())
        let shelves = library.tree.flattened().compactMap { row -> Item? in
            let count = totals[row.category.id] ?? 0
            return count > 0 ? Item(kind: .shelf(row.category, path: library.pathName(of: row.category.id), count: count)) : nil
        }
        func tabItem(_ tab: BrowserTab) -> CommandPalette.Item.Kind {
            .tab(tab, shelf: library.pathName(of: library.category(for: tab).id))
        }
        if trimmed.isEmpty {
            results = shelves + commands + indexedTabs.prefix(40).map { Item(kind: tabItem($0)) }
        } else {
            let matchingShelves = shelves.filter { item in
                guard case .shelf(_, let path, _) = item.kind else { return false }
                let words = SearchIndex.words(in: path)
                return terms.allSatisfy { term in words.contains { $0.hasPrefix(term) } }
            }
            let tabs = index.search(trimmed).map { hit -> Item in
                Item(kind: tabItem(indexedTabs[hit.index]), words: hit.words, snippet: hit.snippet)
            }
            results = commands + Array(matchingShelves.prefix(3)) + tabs
        }
        if let selectedID, let kept = results.firstIndex(where: { $0.id == selectedID }) {
            selection = kept
        } else {
            selection = 0
            scrollTarget = 0
        }
    }

    // MARK: Layout

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture(perform: close)
            VStack(spacing: 0) {
                field
                Hairline()
                list
                Hairline()
                footer
            }
            .frame(width: 640)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .compositingGroup()
            .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
            .padding(.top, 110)
        }
        .defaultFocus($focused, true, priority: .userInitiated)
        .onAppear {
            // Preview fetching publishes every 300 ms while it runs, which redraws the
            // library underneath. Hold it while the palette is up.
            wasPaused = previews.paused
            previews.paused = true
            mouseLocation = NSEvent.mouseLocation
            rebuildIndex()
            installKeys()
        }
        .task {
            await Task.yield()
            focused = true
        }
        .onDisappear {
            previews.paused = wasPaused
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
        .onChange(of: query) { _, _ in runSearch() }
        .onChange(of: library.tabs) { _, _ in rebuildIndex() }
    }

    /// Arrow keys go to the list, not the text field. A window-level monitor sees them
    /// before the field editor does, which `onKeyPress` on a TextField doesn't guarantee.
    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let control = event.modifierFlags.contains(.control)
            switch event.keyCode {
            case 125: move(1); return nil                       // ↓
            case 126: move(-1); return nil                      // ↑
            case 45 where control: move(1); return nil          // ⌃N
            case 35 where control: move(-1); return nil         // ⌃P
            case 121: move(8); return nil                       // page down
            case 116: move(-8); return nil                      // page up
            case 36, 76: activate(inHelium: event.modifierFlags.contains(.command)); return nil // ↩
            case 53: close(); return nil                        // esc
            default: return event
            }
        }
    }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.ink3)
            TextField("Search tabs, shelves, and commands", text: $query,
                      prompt: Text("Search tabs, shelves, and commands").foregroundStyle(Theme.ink4))
                .textFieldStyle(.plain)
                .font(Theme.sans(15))
                .foregroundStyle(Theme.ink)
                .focused($focused)
                .accessibilityLabel("Search tabs, shelves, and commands")
            if !query.isEmpty {
                Text("\(results.count)")
                    .font(Theme.sans(12).monospacedDigit())
                    .foregroundStyle(Theme.ink4)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
    }

    @ViewBuilder private var list: some View {
        if results.isEmpty {
            VStack(spacing: 4) {
                Text("No results for “\(query)”").font(Theme.sans(13.5, .medium)).foregroundStyle(Theme.ink2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 36)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { offset, item in
                            if offset == 0 || results[offset - 1].section != item.section {
                                header(item.section, first: offset == 0)
                            }
                            PaletteRow(item: item, selected: offset == selection, icon: icon(for: item)).equatable()
                                .id(offset)
                                .onContinuousHover { phase in
                                    guard case .active = phase else { return }
                                    let location = NSEvent.mouseLocation
                                    // Filtering can move a row under a stationary pointer.
                                    guard location != mouseLocation else { return }
                                    mouseLocation = location
                                    selection = offset
                                }
                                .onTapGesture { selection = offset; activate(inHelium: false) }
                                .accessibilityElement(children: .combine)
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAction { selection = offset; activate(inHelium: false) }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                }
                .scrollIndicators(.never)
                .frame(maxHeight: 420)
                .onChange(of: scrollTarget) { _, target in
                    guard let target else { return }
                    proxy.scrollTo(target, anchor: nil)
                    scrollTarget = nil
                }
            }
        }
    }

    private func header(_ section: Item.Section, first: Bool) -> some View {
        let title = switch section {
        case .commands: "Commands"
        case .shelves: "Shelves"
        case .tabs: query.isEmpty ? "Recent tabs" : "Tabs"
        }
        return Text(title)
            .font(Theme.sans(11, .medium))
            .foregroundStyle(Theme.ink3)
            .padding(.horizontal, 10)
            .padding(.top, first ? 10 : 12)
            .padding(.bottom, 4)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            hint("↑↓", "Move")
            if results.indices.contains(selection) {
                switch results[selection].section {
                case .commands: hint("↩", "Run")
                case .shelves: hint("↩", "Open shelf")
                case .tabs:
                    hint("↩", "Read")
                    hint("⌘↩", "Open in Helium")
                }
            }
            Spacer()
            Text("\(library.tabs.count) tabs").font(Theme.sans(11).monospacedDigit()).foregroundStyle(Theme.ink4)
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(Theme.sans(10.5, .medium)).foregroundStyle(Theme.ink2)
                .padding(.horizontal, 4).frame(minWidth: 18, minHeight: 17)
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.raised))
            Text(label).font(Theme.sans(11)).foregroundStyle(Theme.ink3)
        }
    }

    private func icon(for item: Item) -> NSImage? {
        if case .tab(let tab, _) = item.kind { return previews.icons[tab.host] }
        return nil
    }

    // MARK: Actions

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = (selection + delta % results.count + results.count) % results.count
        scrollTarget = selection
    }

    private func activate(inHelium: Bool) {
        guard results.indices.contains(selection) else { return }
        switch results[selection].kind {
        case .command(let command):
            close()
            performCommand(command)
            return
        case .shelf(let category, _, _):
            openShelf(category.id)
        case .tab(let tab, _):
            if inHelium, let url = tab.readableURL { Helium.open(url) } else { openTab(tab) }
        }
        close()
    }
}

/// One result. Kept as its own view so a selection change only redraws the two rows involved.
private struct PaletteRow: View, Equatable {
    let item: CommandPalette.Item
    let selected: Bool
    let icon: NSImage?

    static func == (a: Self, b: Self) -> Bool {
        a.item.id == b.item.id && a.selected == b.selected && a.icon === b.icon
            && a.item.words == b.item.words && a.item.snippet == b.item.snippet && a.item.detail == b.item.detail
    }

    var body: some View {
        HStack(spacing: 11) {
            switch item.kind {
            case .command(let command):
                Image(systemName: command.label.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(selected ? Theme.accent : Theme.ink3)
                    .frame(width: 18, height: 18)
                Text(command.label.title).font(Theme.sans(13.5, .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                Spacer(minLength: 8)
                if let detail = item.detail {
                    Text(detail).font(Theme.sans(12)).foregroundStyle(Theme.ink3).lineLimit(1).truncationMode(.middle)
                }
            case .shelf(let category, let path, let count):
                Image(systemName: category.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(selected ? Theme.accent : Theme.ink3)
                    .frame(width: 18, height: 18)
                Text(Self.shelfPath(path)).lineLimit(1).truncationMode(.head)
                Spacer(minLength: 8)
                Text("\(count)").font(Theme.sans(12).monospacedDigit()).foregroundStyle(Theme.ink3)
            case .tab(let tab, let shelf):
                Favicon(icon: icon, site: tab.sourceName, size: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.marked(tab.displayTitle, item.words, size: 13.5, base: Theme.ink))
                        .lineLimit(1)
                    Text(Self.marked(item.snippet.map { tab.sourceName + "  ·  " + $0 } ?? tab.sourceName,
                                     item.words, size: 11.5, base: Theme.ink3))
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                if tab.active {
                    Circle().fill(Theme.accent).frame(width: 5, height: 5).help("Active in Helium")
                }
                Text(shelf).font(Theme.sans(11.5)).foregroundStyle(Theme.ink4).lineLimit(1).fixedSize()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: item.section == .tabs ? 46 : 34)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? Theme.raised : .clear))
        .contentShape(Rectangle())
    }

    /// Shelf path with the parent levels dimmed.
    static func shelfPath(_ path: String) -> AttributedString {
        let parts = path.components(separatedBy: ShelfTree.separator)
        var result = AttributedString()
        for (index, part) in parts.enumerated() {
            let last = index == parts.count - 1
            var piece = AttributedString(last ? part : part + ShelfTree.separator)
            piece.font = Theme.sans(13.5, .medium)
            piece.foregroundColor = last ? Theme.ink : Theme.ink3
            result += piece
        }
        return result
    }

    /// Geist text with the words the search matched brightened in the accent.
    static func marked(_ text: String, _ words: Set<String>, size: CGFloat, base: Color) -> AttributedString {
        var result = AttributedString(text)
        result.font = Theme.sans(size, size > 12 ? .medium : .regular)
        result.foregroundColor = base
        guard !words.isEmpty else { return result }
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        // Folding can change the character count (e.g. ligatures); skip highlighting then.
        guard folded.count == text.count else { return result }
        var start = folded.startIndex
        while start < folded.endIndex {
            guard let wordStart = folded[start...].firstIndex(where: { $0.isLetter || $0.isNumber }) else { break }
            let wordEnd = folded[wordStart...].firstIndex(where: { !($0.isLetter || $0.isNumber) }) ?? folded.endIndex
            if words.contains(String(folded[wordStart..<wordEnd])) {
                let from = folded.distance(from: folded.startIndex, to: wordStart)
                let to = folded.distance(from: folded.startIndex, to: wordEnd)
                let a = result.characters.index(result.startIndex, offsetBy: from)
                let b = result.characters.index(result.startIndex, offsetBy: to)
                result[a..<b].foregroundColor = Theme.accent
            }
            start = wordEnd
        }
        return result
    }
}

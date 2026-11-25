import SwiftUI

struct LibraryView: View {
    @ObservedObject var library: Library
    @ObservedObject var previews: Previews
    /// Notes in the vault about each page, for the little ✎ count on cards.
    @ObservedObject var notes: NoteIndex
    @Binding var selectedCategory: String?
    let closeInHelium: Bool
    let titleBarHeight: CGFloat
    /// Shelf, tab to start on, and where the tapped card sits on screen (for the hero transition).
    let open: (String, BrowserTab?, CGRect?) -> Void

    private let margin: CGFloat = 48
    private let gutter: CGFloat = 28
    /// Searching lives in the ⌘⇧P palette now; the library always shows everything.
    private let query = ""

    private func matching(_ tabs: [BrowserTab]) -> [BrowserTab] {
        query.isEmpty ? tabs : tabs.filter { tab in
            let preview = previews.info[tab.address]
            return tab.displayTitle.localizedCaseInsensitiveContains(query)
                || tab.address.localizedCaseInsensitiveContains(query)
                || (preview?.summary?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private func readingTime(_ tabs: [BrowserTab]) -> String? {
        let minutes = tabs.compactMap { previews.info[$0.address]?.minutes }.reduce(0, +)
        guard minutes > 0 else { return nil }
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }

    var body: some View {
        let groups = library.grouped()
        let totals = library.totals(groups)
        let ordered = library.visibleChildren(of: nil, totals: totals)
        let shared = boilerplate
        let selected = selectedCategory.flatMap(library.category(withID:))
        GeometryReader { geometry in
            let available = geometry.size.width - margin * 2
            let columns = max(1, min(5, Int((available + gutter) / (290 + gutter))))
            let columnWidth = (available - gutter * CGFloat(columns - 1)) / CGFloat(columns)
            ScrollView {
                // Lazy, so only the sections on screen are laid out and drawn.
                LazyVStack(alignment: .leading, spacing: 0) {
                    sourceStatus.frame(height: 28)
                    if let error = library.error {
                        HStack(spacing: 8) {
                            Text(error).font(Theme.sans(12.5)).foregroundStyle(Theme.error).textSelection(.enabled)
                            Spacer()
                            DeskIcon("xmark", help: "Dismiss") { library.error = nil }
                        }
                        .padding(.bottom, 8)
                    }
                    masthead(ordered, totals: totals)
                        .padding(.top, 30)
                    Hairline().padding(.top, 22)
                    if library.tabs.isEmpty {
                        empty.padding(.top, 60)
                    } else if let selected {
                        let children = library.visibleChildren(of: selected.id, totals: totals)
                        let all = matching(library.orderedTabs(in: selected.id, groups: groups, totals: totals))
                        summary(all, category: selected).padding(.vertical, 18)
                        if children.isEmpty {
                            grid(all, columns: columns, width: columnWidth, shared: shared, readIn: selected.id, labelFrom: selected.id)
                        } else {
                            // One section per sub-shelf, then whatever is filed on the parent itself.
                            ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
                                section(child, tabs: matching(library.orderedTabs(in: child.id, groups: groups, totals: totals)),
                                        index: index, readIn: selected.id, columns: columns, width: columnWidth, shared: shared)
                            }
                            let direct = matching(groups[selected.id] ?? [])
                            if !direct.isEmpty {
                                section(selected, title: "Unsorted in \(selected.name)", tabs: direct, index: children.count,
                                        readIn: selected.id, columns: columns, width: columnWidth, shared: shared)
                            }
                        }
                    } else if !query.isEmpty {
                        let tabs = matching(library.tabs)
                        summary(tabs, category: nil).padding(.vertical, 18)
                        grid(tabs, columns: columns, width: columnWidth, shared: shared, readIn: nil, labelFrom: nil)
                    } else {
                        summary(library.tabs, category: nil).padding(.vertical, 18)
                        ForEach(Array(ordered.enumerated()), id: \.element.id) { index, category in
                            section(category, tabs: library.orderedTabs(in: category.id, groups: groups, totals: totals), index: index,
                                    readIn: category.id, columns: columns, width: columnWidth, shared: shared)
                        }
                    }
                }
                .padding(.horizontal, margin)
                .padding(.top, 16)
                .padding(.bottom, 80)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .overlay(alignment: .top) {
                LinearGradient(colors: [Theme.ground, Theme.ground.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 16)
                    .allowsHitTesting(false)
            }
            .padding(.top, titleBarHeight)
        }
        .background(Theme.ground)
        .background {
            ShortcutButton("Up one level", "[") { goUp() }
        }
        .onChange(of: library.categories) { old, new in
            // If the open shelf was deleted, fall back to its parent.
            guard let id = selectedCategory, !new.contains(where: { $0.id == id }) else { return }
            let parent = old.first { $0.id == id }?.parentID
            selectedCategory = parent.flatMap { parent in new.contains { $0.id == parent } ? parent : nil }
        }
    }

    /// ⌘[ goes up one level.
    private func goUp() {
        select(selectedCategory.flatMap { library.category(withID: $0)?.parentID })
    }

    /// Where the library came from, so it's never a mystery.
    private var sourceStatus: some View {
        HStack(spacing: 7) {
            if library.sample {
                Text("SAMPLE DATA").font(Theme.mono(10, .medium)).foregroundStyle(Theme.accent)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.5)))
            } else {
                Circle().fill(library.error == nil && library.lastUpdated != nil ? Color(hex: 0x6FCF8E) : Theme.ink4)
                    .frame(width: 6, height: 6)
                Group {
                    if library.updating && library.lastUpdated == nil {
                        Text("Reading Helium…")
                    } else if let updated = library.lastUpdated {
                        Text("Helium · \(library.rawCount) tabs · \(updated.formatted(date: .omitted, time: .shortened))")
                    } else {
                        Text("Helium not connected")
                    }
                }
                .font(Theme.mono(10.5)).foregroundStyle(Theme.ink3)
                if library.updating { ProgressView().controlSize(.mini).scaleEffect(0.8) }
            }
        }
        .help(library.lastUpdated != nil && library.rawCount != library.tabs.count
              ? "\(library.rawCount) Helium tabs, \(library.tabs.count) after merging duplicates and skipping new-tab pages"
              : "")
    }

    /// The shelf index: big Garamond words with superscript counts, plus a smaller
    /// row of sub-shelves for each level of the current selection.
    private func masthead(_ ordered: [Category], totals: [String: Int]) -> some View {
        let path = selectedCategory.map { library.tree.path(of: $0) } ?? []
        let rows = path.enumerated().compactMap { depth, shelf -> (parent: Category, children: [Category], selected: String?)? in
            let children = library.visibleChildren(of: shelf.id, totals: totals)
            guard !children.isEmpty else { return nil }
            return (shelf, children, path.indices.contains(depth + 1) ? path[depth + 1].id : nil)
        }
        return VStack(alignment: .leading, spacing: 0) {
            FlowLayout(spacing: 30, lineSpacing: 2) {
                ShelfWord(name: "All", count: library.tabs.count, selected: selectedCategory == nil) { select(nil) }
                ForEach(ordered) { category in
                    ShelfWord(name: category.name, count: totals[category.id] ?? 0,
                              selected: path.first?.id == category.id, agent: category.isAgentMade) { select(category.id) }
                }
            }
            ForEach(Array(rows.enumerated()), id: \.element.parent.id) { level, row in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("in \(row.parent.name)").font(Theme.serif(14, italic: true)).foregroundStyle(Theme.ink4).fixedSize()
                    FlowLayout(spacing: level == 0 ? 22 : 18, lineSpacing: 2) {
                        ForEach(row.children) { child in
                            ShelfWord(name: child.name, count: totals[child.id] ?? 0, selected: row.selected == child.id,
                                      agent: child.isAgentMade, size: level == 0 ? 26 : 21) { select(child.id) }
                        }
                    }
                }
                .padding(.top, level == 0 ? 14 : 6)
                .transition(.opacity)
            }
        }
    }

    private func summary(_ tabs: [BrowserTab], category: Category?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            if let category, let parent = category.parentID.flatMap(library.category(withID:)) {
                TextAction(title: parent.name, systemImage: "arrow.up") { select(parent.id) }
                    .help("Up to \(library.pathName(of: parent.id)) (⌘[)")
                Text("·").font(Theme.mono(11)).foregroundStyle(Theme.ink4)
            }
            Text(tabs.count == 1 ? "1 tab" : "\(tabs.count) tabs")
                .font(Theme.mono(11)).foregroundStyle(Theme.ink2)
            if let time = readingTime(tabs) {
                Text("≈ \(time) of reading").font(Theme.mono(11)).foregroundStyle(Theme.ink3)
            }
            if library.finishedToday > 0 {
                Text("\(library.finishedToday) finished today").font(Theme.mono(11)).foregroundStyle(Theme.accent.opacity(0.85))
            }
            if library.updating { ProgressView().controlSize(.mini) }
            Spacer()
            if let category, tabs.contains(where: { $0.readableURL != nil }) {
                Button { open(category.id, nil, nil) } label: {
                    HStack(spacing: 7) { Text("Begin reading"); Image(systemName: "arrow.right").font(.system(size: 10.5, weight: .semibold)) }
                }
                .buttonStyle(DeskButtonStyle(.primary))
                .keyboardShortcut(.return, modifiers: .command)
                .help("Open this shelf in the reader (⌘↩)")
            }
        }
    }

    /// One shelf's tabs under a numbered heading. A `title` marks the "Unsorted in …"
    /// section, which shows every tab and has no drill-in or Read button.
    /// `readIn` is the shelf a card click starts reading from.
    private func section(_ category: Category, title: String? = nil, tabs: [BrowserTab], index: Int, readIn: String,
                         columns: Int, width: CGFloat, shared: (images: Set<String>, summaries: Set<String>)) -> some View {
        let unsorted = title != nil
        let shown = unsorted ? tabs : Array(tabs.prefix(columns * 2))
        return VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(Self.roman(index + 1)).font(Theme.serif(15, italic: true)).foregroundStyle(Theme.accent)
                if let title {
                    Text(title).font(Theme.serif(30, italic: true)).foregroundStyle(Theme.ink2)
                } else {
                    Button { select(category.id) } label: {
                        Text(category.name).font(Theme.serif(30)).foregroundStyle(Theme.ink)
                    }
                    .buttonStyle(.plain)
                }
                Text("\(tabs.count)").font(Theme.mono(11)).foregroundStyle(Theme.ink3)
                if let time = readingTime(tabs) {
                    Text("· \(time)").font(Theme.mono(11)).foregroundStyle(Theme.ink4)
                }
                Spacer()
                if tabs.count > shown.count {
                    TextAction(title: "All \(tabs.count)", systemImage: "arrow.right", trailing: true) { select(category.id) }
                        .padding(.trailing, 14)
                }
                if !unsorted, tabs.contains(where: { $0.readableURL != nil }) {
                    Button { open(category.id, nil, nil) } label: { Text("Read shelf") }
                        .buttonStyle(DeskButtonStyle(.outline))
                }
            }
            grid(shown, columns: columns, width: width, shared: shared, readIn: readIn, labelFrom: category.id)
        }
        .padding(.top, index == 0 ? 8 : 44)
        .padding(.bottom, 4)
    }

    /// Cards filed below `labelFrom` show their sub-shelf path. `readIn` defaults to the tab's own shelf.
    private func grid(_ tabs: [BrowserTab], columns: Int, width: CGFloat, shared: (images: Set<String>, summaries: Set<String>),
                      readIn: String?, labelFrom: String?) -> some View {
        Group {
            if tabs.isEmpty {
                Text(query.isEmpty ? "Nothing on this shelf." : "No tabs match “\(query)”.")
                    .font(Theme.serif(20, italic: true)).foregroundStyle(Theme.ink3).padding(.vertical, 30)
            } else {
                HStack(alignment: .top, spacing: gutter) {
                    ForEach(0..<columns, id: \.self) { column in
                        LazyVStack(alignment: .leading, spacing: 34) {
                            ForEach(Array(tabs.enumerated()).filter { $0.offset % columns == column }, id: \.element.id) { _, tab in
                                card(tab, width: width, shared: shared, readIn: readIn, labelFrom: labelFrom)
                            }
                        }
                        .frame(width: width)
                    }
                }
            }
        }
    }

    /// Images and descriptions that several tabs share are site boilerplate
    /// (the ChatGPT banner, "Meet Gemini, Google's AI assistant…"), not about the page.
    private var boilerplate: (images: Set<String>, summaries: Set<String>) {
        var images: [String: Int] = [:]
        var summaries: [String: Int] = [:]
        for preview in previews.info.values {
            if let image = preview.imageURL { images[image, default: 0] += 1 }
            if let summary = preview.summary { summaries[summary, default: 0] += 1 }
        }
        return (Set(images.filter { $0.value > 1 }.keys), Set(summaries.filter { $0.value > 1 }.keys))
    }

    private func card(_ tab: BrowserTab, width: CGFloat, shared: (images: Set<String>, summaries: Set<String>),
                      readIn: String?, labelFrom: String?) -> some View {
        let category = library.category(for: tab)
        let shelfLabel: String? = category.id == labelFrom ? nil
            : labelFrom.map { library.tree.pathName(of: category.id, from: $0) } ?? library.pathName(of: category.id)
        var preview = previews.info[tab.address]
        var image = previews.images[tab.address]
        if let url = preview?.imageURL, shared.images.contains(url), preview?.isPDF != true { image = nil }
        if let summary = preview?.summary, shared.summaries.contains(summary) { preview?.summary = nil }
        return TabCard(tab: tab, preview: preview, image: image,
                       icon: previews.icons[tab.host], width: width,
                       shelfName: shelfLabel,
                       shelves: library.tree, currentCategory: category.id,
                       noteCount: notes.count(for: tab.address), saved: library.isSaved(tab),
                       open: { _ in open(readIn ?? category.id, tab, nil) },
                       done: { library.finish(tab, closeInHelium: closeInHelium) },
                       readLater: { library.saveForLater(tab, closeInHelium: closeInHelium) },
                       removeFromLater: { library.removeFromLater(tab.address) },
                       assign: { library.assign(tab, to: $0) },
                       fileSite: { library.fileSite(of: tab, in: $0) })
            .onAppear { previews.request(tab) }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 12) {
            if library.updating {
                ProgressView().controlSize(.small)
                Text("Gathering your tabs…").font(Theme.serif(26, italic: true)).foregroundStyle(Theme.ink2)
            } else {
                Text("The desk is clear.").font(Theme.serif(44)).foregroundStyle(Theme.ink)
                if library.error == nil {
                    Text("Every tab has been read. Open more in Helium and they’ll appear here.")
                        .font(Theme.sans(13.5)).foregroundStyle(Theme.ink3)
                }
            }
        }
    }

    private func select(_ id: String?) {
        withAnimation(.easeOut(duration: 0.2)) { selectedCategory = id }
    }

    static func roman(_ number: Int) -> String {
        let table: [(Int, String)] = [(10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")]
        var n = number, out = ""
        for (value, glyph) in table { while n >= value { out += glyph; n -= value } }
        return out
    }
}

private struct ShelfWord: View {
    let name: String
    let count: Int
    let selected: Bool
    var agent = false
    var size: CGFloat = 42
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 3) {
                Text(name)
                    .font(Theme.serif(size, italic: selected))
                    .tracking(-0.6 * size / 42)
                    .foregroundStyle(selected ? Theme.ink : hovered ? Theme.ink2 : Theme.ink3.opacity(0.7))
                if agent {
                    // Shelves an agent made: same type, a small mark so you know who filed them.
                    Image(systemName: "sparkle").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(selected ? Theme.accent : Theme.ink4)
                        .padding(.top, 10)
                        .help("Sorted by an agent. This shelf goes away once its tabs are read.")
                }
                Text("\(count)")
                    .font(Theme.mono(size < 30 ? 10 : 11, .medium))
                    .foregroundStyle(selected ? Theme.accent : Theme.ink4)
                    .padding(.top, size * 9 / 42)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.15), value: hovered)
        .accessibilityLabel("\(name), \(count) tabs")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A tab as a card: cover, source line, Garamond title, the page's own description.
struct TabCard: View {
    let tab: BrowserTab
    let preview: PagePreview?
    let image: NSImage?
    let icon: NSImage?
    let width: CGFloat
    let shelfName: String?
    let shelves: ShelfTree
    let currentCategory: String
    var noteCount = 0
    var saved = false
    /// Called with the card's cover frame in window coordinates.
    let open: (CGRect) -> Void
    let done: () -> Void
    var readLater: () -> Void = {}
    var removeFromLater: () -> Void = {}
    let assign: (String?) -> Void
    let fileSite: (String) -> Void

    @State private var hovered = false

    private var title: String {
        let page = tab.title.trimmed
        if !page.isEmpty { return page }
        return preview?.title ?? tab.displayTitle
    }

    private var coverHeight: CGFloat {
        if image != nil, let aspect = preview?.aspect { return width * min(max(aspect, 0.42), 0.85) }
        return width * 0.58
    }

    /// X posts and profiles: shown as the words themselves, not an empty cover.
    private var post: XPost? { image == nil ? XPost(tab: tab, preview: preview) : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cover
                .frame(width: width, height: coverHeight)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.white.opacity(hovered ? 0.14 : 0.06)))
                .overlay(alignment: .topTrailing) { if hovered { actions.padding(8).transition(.opacity) } }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Favicon(icon: icon, site: tab.sourceName, size: 14)
                    Text(preview?.siteName ?? tab.sourceName)
                        .font(Theme.mono(10.5)).foregroundStyle(Theme.ink3).lineLimit(1)
                    if tab.active {
                        Circle().fill(Theme.accent).frame(width: 5, height: 5)
                            .help("The tab you’re on in this Helium window")
                    }
                    if !tab.duplicates.isEmpty {
                        Text("×\(tab.copies.count)").font(Theme.mono(10)).foregroundStyle(Theme.ink4)
                            .help("Open \(tab.copies.count) times in Helium. Done closes every copy.")
                    }
                    Spacer(minLength: 6)
                    if noteCount > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "pencil.line").font(.system(size: 9, weight: .medium))
                            Text("\(noteCount)").font(Theme.mono(10.5))
                        }
                        .foregroundStyle(Theme.accent.opacity(0.85))
                        .help(noteCount == 1 ? "You have a note on this page" : "You have \(noteCount) notes on this page")
                    }
                    if let shelfName {
                        Text(shelfName).font(Theme.mono(10.5)).foregroundStyle(Theme.ink4).lineLimit(1)
                    } else if preview?.isPDF == true {
                        Text("PDF").font(Theme.mono(10.5)).foregroundStyle(Theme.ink4)
                    } else if let minutes = preview?.minutes {
                        Text("\(minutes) min").font(Theme.mono(10.5)).foregroundStyle(Theme.ink4)
                    }
                }
                Text(post?.byline ?? title)
                    .font(Theme.serif(20, .medium))
                    .lineSpacing(-1)
                    .foregroundStyle(hovered ? Color.white : Theme.ink)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                if post == nil, let summary = preview?.summary, summary.caseInsensitiveCompare(title) != .orderedSame {
                    Text(summary)
                        .font(Theme.sans(12.5))
                        .lineSpacing(3)
                        .foregroundStyle(Theme.ink3)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 13)
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { open(.zero) }
        .onHover { inside in withAnimation(.easeOut(duration: 0.16)) { hovered = inside } }
        .help(tab.readableURL == nil ? "Switch to this tab in Helium" : tab.address)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open(.zero) }
        .accessibilityAction(named: "Mark done", done)
    }

    @ViewBuilder private var cover: some View {
        if let post {
            PostCover(post: post, hovered: hovered)
        } else if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: width, height: coverHeight, alignment: .top)
                .clipped()
                // A flat dim instead of saturation/brightness filters: filters make every
                // visible cover re-render off-screen on each scroll frame.
                .overlay(Theme.ground.opacity(hovered ? 0 : 0.14))
        } else {
            TypeCover(site: tab.sourceName, icon: icon, loading: preview == nil && tab.readableURL != nil)
        }
    }

    private var actions: some View {
        HStack(spacing: 2) {
            CardAction(symbol: "checkmark", help: "Mark done") { done() }
            if tab.readableURL != nil && !saved {
                CardAction(symbol: "bookmark", help: "Read later") { readLater() }
            }
            Menu {
                if saved {
                    Button("Remove from Read later") { removeFromLater() }
                } else if tab.readableURL != nil {
                    Button("Read later") { readLater() }
                }
                Section("Move to shelf") {
                    ShelfMenuItems(tree: shelves, parent: nil, current: currentCategory) { assign($0) }
                    Button("Let Reading Desk decide") { assign(nil) }
                }
                if !tab.site.isEmpty {
                    Menu("Always file \(tab.site) in…") {
                        ShelfMenuItems(tree: shelves, parent: nil, current: nil, rulesOnly: true) { fileSite($0) }
                    }
                }
                Divider()
                if let url = tab.readableURL {
                    Button("Open in Helium") { Helium.open(url) }
                    Button("Copy link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    }
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.ink).frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(2)
        .background(Capsule().fill(Theme.ground.opacity(0.82)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1)))
    }
}

/// Shelf picker for menus. Submenu titles aren't clickable, so each submenu
/// repeats its parent as the first item.
private struct ShelfMenuItems: View {
    let tree: ShelfTree
    let parent: String?
    let current: String?
    /// Hide shelves that can't take a rule (Read later), for "Always file … in".
    var rulesOnly = false
    let pick: (String) -> Void

    var body: some View {
        ForEach(tree.children(of: parent).filter { !rulesOnly || $0.acceptsRules }) { shelf in
            if tree.children(of: shelf.id).isEmpty {
                item(shelf)
            } else {
                Menu {
                    item(shelf)
                    Divider()
                    ShelfMenuItems(tree: tree, parent: shelf.id, current: current, rulesOnly: rulesOnly, pick: pick)
                } label: {
                    if let current, tree.isInside(current, shelf.id) || current == shelf.id {
                        Label(shelf.name, systemImage: "checkmark")
                    } else {
                        Text(shelf.name)
                    }
                }
            }
        }
    }

    private func item(_ shelf: Category) -> some View {
        Button { pick(shelf.id) } label: {
            if shelf.id == current { Label(shelf.name, systemImage: "checkmark") } else { Text(shelf.name) }
        }
    }
}

private struct CardAction: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .frame(width: 28, height: 28)
                .foregroundStyle(hovered ? Theme.accentInk : Theme.ink)
                .background(Circle().fill(hovered ? Theme.accent : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }
}


/// What an X (Twitter) tab is about, read from its title, address and description.
/// Titles come as `Name on X: "post text" / X` for posts and `Name (@handle) / X` for profiles.
struct XPost {
    enum Kind { case post, profile, other }
    var kind: Kind
    var author: String?
    var handle: String?
    var text: String?

    init?(tab: BrowserTab, preview: PagePreview?) {
        let site = tab.site
        guard site == "x.com" || site == "twitter.com" || site.hasSuffix(".x.com") || site == "mobile.twitter.com" else { return nil }
        let parts = tab.url?.pathComponents.filter { $0 != "/" } ?? []
        let reserved: Set<String> = ["home", "explore", "search", "notifications", "messages", "settings", "i", "compose", "hashtag"]
        handle = parts.first.flatMap { reserved.contains($0.lowercased()) ? nil : $0 }
        kind = parts.count >= 3 && parts[1] == "status" ? .post : handle != nil && parts.count == 1 ? .profile : .other
        let title = (tab.title.trimmed.isEmpty ? preview?.title : tab.title)?.trimmed ?? ""
        if let post = Self.postTitle.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
           let name = Range(post.range(at: 1), in: title), let quoted = Range(post.range(at: 2), in: title) {
            author = String(title[name])
            // The description holds the whole post; the title cuts it off.
            text = preview?.summary?.trimmed.nonEmpty ?? String(title[quoted]).trimmed.nonEmpty
            kind = .post
        } else if let open = title.range(of: " (@"), let close = title.range(of: ")", range: open.upperBound..<title.endIndex) {
            author = String(title[..<open.lowerBound])
            handle = String(title[open.upperBound..<close.lowerBound])
            text = preview?.summary?.trimmed.nonEmpty
            kind = .profile
        } else {
            text = preview?.summary?.trimmed.nonEmpty
        }
        if let text, text.isEmpty { self.text = nil }
    }

    private static let postTitle = try! NSRegularExpression(pattern: #"^(.+?) on (?:X|Twitter): [“"](.*)[”"]\s*(?:/ (?:X|Twitter))?$"#,
                                                            options: [.dotMatchesLineSeparators])

    /// The line under the cover: who it's from.
    var byline: String {
        switch kind {
        case .post: author.map { "\($0)’s post" } ?? handle.map { "Post by @\($0)" } ?? "A post on X"
        case .profile: author ?? handle.map { "@\($0)" } ?? "Profile on X"
        case .other: author ?? handle.map { "@\($0) on X" } ?? "X"
        }
    }
}

/// An X tab without an image: the post's own words, set like a pull quote.
private struct PostCover: View {
    let post: XPost
    let hovered: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(hovered ? Theme.raised : Theme.surface)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 7) {
                    Image(systemName: post.kind == .profile ? "person.crop.circle" : "text.bubble")
                        .font(.system(size: 10.5, weight: .medium))
                    Text(post.handle.map { "@\($0)" } ?? "x.com")
                        .font(Theme.mono(10.5))
                        .lineLimit(1)
                }
                .foregroundStyle(Theme.ink3)
                if let text = post.text {
                    Text(text)
                        .font(Theme.serif(post.kind == .profile ? 17 : 19))
                        .lineSpacing(1)
                        .foregroundStyle(post.kind == .profile ? Theme.ink2 : Theme.ink)
                        .lineLimit(post.kind == .profile ? 5 : 7)
                        .padding(.leading, post.kind == .post ? 12 : 0)
                        .overlay(alignment: .leading) {
                            if post.kind == .post { Rectangle().fill(Theme.accent.opacity(0.7)).frame(width: 2) }
                        }
                } else {
                    Text(post.kind == .profile ? "Profile" : "Post")
                        .font(Theme.serif(24, italic: true)).foregroundStyle(Theme.ink3)
                }
                Spacer(minLength: 0)
            }
            .padding(18)
        }
    }
}

/// When a page has no image: a quiet bookplate with the site's mark and name.
private struct TypeCover: View {
    let site: String
    let icon: NSImage?
    let loading: Bool

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle().fill(Theme.surface)
            Canvas { context, size in
                var y: CGFloat = 18
                while y < size.height {
                    context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 0.5)), with: .color(Color.white.opacity(0.025)))
                    y += 18
                }
            }
            if loading {
                // Static: a pulsing placeholder per loading card keeps the whole grid animating.
                Rectangle().fill(Theme.raised).opacity(0.3)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Favicon(icon: icon, site: site, size: 26)
                    Text(site).font(Theme.serif(24, italic: true)).foregroundStyle(Theme.ink2).lineLimit(1)
                }
                .padding(18)
            }
        }
    }
}

struct Favicon: View {
    let icon: NSImage?
    let site: String
    let size: CGFloat

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                Text(String(site.prefix(1)).uppercased())
                    .font(Theme.serif(size * 0.78, .medium))
                    .foregroundStyle(Theme.ink2)
                    .frame(width: size, height: size)
                    .background(RoundedRectangle(cornerRadius: size * 0.22).fill(Theme.raised))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
        .accessibilityHidden(true)
    }
}

/// Wrapping row layout for the shelf index.
struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].items.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

// MARK: - Shelf editor

struct ShelvesEditor: View {
    @ObservedObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Shelves").font(Theme.serif(34))
                    Text("Top-level shelves are checked top to bottom. Inside a shelf, its sub-shelves are checked first, so a tab lands on the deepest shelf whose rules match it.")
                        .font(Theme.sans(12.5)).foregroundStyle(Theme.ink3)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(DeskButtonStyle(.primary))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 20)
            Hairline()
            HStack(spacing: 0) {
                sidebar.frame(width: 240)
                Hairline(vertical: true)
                if let id = selection, let category = library.category(withID: id) {
                    ShelfForm(library: library, category: category, select: { selection = $0 }).id(id)
                } else {
                    Text("Choose a shelf").font(Theme.serif(20, italic: true)).foregroundStyle(Theme.ink3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(width: 780, height: 580)
        .background(Theme.ground)
        .foregroundStyle(Theme.ink)
        .preferredColorScheme(.dark)
        .onAppear { selection = selection ?? library.categories.first?.id }
    }

    private var sidebar: some View {
        let totals = library.totals(library.grouped())
        // Number top-level shelves only; indent the rest.
        var number = 0
        let rows = library.tree.flattened().map { row -> (category: Category, depth: Int, number: Int?) in
            if row.depth == 0 { number += 1 }
            return (row.category, row.depth, row.depth == 0 ? number : nil)
        }
        let selectable = selection.flatMap(library.category(withID:)).map { !$0.isBuiltIn } ?? false
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows, id: \.category.id) { row in
                        let category = row.category
                        Button { selection = category.id } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(row.number.map(LibraryView.roman) ?? "").font(Theme.serif(13, italic: true))
                                    .foregroundStyle(selection == category.id ? Theme.accent : Theme.ink4)
                                    .frame(width: 24, alignment: .trailing)
                                Text(category.name).font(Theme.serif(row.depth == 0 ? 18 : 16))
                                    .foregroundStyle(selection == category.id ? Theme.ink : Theme.ink2).lineLimit(1)
                                    .padding(.leading, CGFloat(row.depth) * 14)
                                    .overlay(alignment: .leading) {
                                        if row.depth > 0 {
                                            Rectangle().fill(Theme.rule).frame(width: 1).padding(.leading, CGFloat(row.depth) * 14 - 8)
                                        }
                                    }
                                Spacer(minLength: 4)
                                Text("\(totals[category.id] ?? 0)").font(Theme.mono(10.5)).foregroundStyle(Theme.ink4)
                            }
                            .padding(.horizontal, 14).padding(.vertical, row.depth == 0 ? 8 : 6)
                            .background(selection == category.id ? Theme.surface : .clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 10)
            }
            Hairline()
            HStack {
                TextAction(title: "New shelf", systemImage: "plus") { selection = library.addCategory() }
                TextAction(title: "New sub-shelf", systemImage: "arrow.turn.down.right") {
                    selection = library.addCategory(inside: selection)
                }
                .disabled(!selectable)
                .opacity(selectable ? 1 : 0.4)
                .help(selectable ? "Create a shelf inside the selected shelf" : "Select a shelf other than Unsorted or Read later")
                .padding(.leading, 10)
                Spacer()
                Menu {
                    Button("Restore default shelves", role: .destructive) {
                        library.resetCategories()
                        selection = library.categories.first?.id
                    }
                } label: {
                    Image(systemName: "ellipsis").foregroundStyle(Theme.ink3).frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            .padding(.horizontal, 16).frame(height: 46)
        }
    }
}

private struct ShelfForm: View {
    @ObservedObject var library: Library
    let category: Category
    let select: (String?) -> Void

    @State private var name: String
    @State private var sites: String
    @State private var keywords: String

    init(library: Library, category: Category, select: @escaping (String?) -> Void) {
        self.library = library
        self.category = category
        self.select = select
        _name = State(initialValue: category.name)
        _sites = State(initialValue: category.domains.joined(separator: ", "))
        _keywords = State(initialValue: category.keywords.joined(separator: ", "))
    }

    private static func list(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private var pinned: [String] { library.siteRules.filter { $0.value == category.id }.map(\.key).sorted() }

    private var siblings: [Category] {
        library.tree.children(of: library.category(withID: category.id)?.parentID).filter { !$0.isBuiltIn }
    }

    /// Anything except itself, its own sub-shelves, or a built-in shelf.
    private var parentOptions: [Category] {
        library.tree.flattened().map(\.category).filter { library.tree.canNest(category.id, under: $0.id) }
    }

    /// "" means top level (Picker tags can't be optional).
    private var parentBinding: Binding<String> {
        Binding(get: { library.category(withID: category.id)?.parentID ?? "" },
                set: { library.setParent(category.id, to: $0.isEmpty ? nil : $0) })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                TextField("Shelf name", text: $name)
                    .textFieldStyle(.plain)
                    .font(Theme.serif(36))
                switch category.role {
                case .unsorted:
                    Text("Anything that doesn’t match another shelf lands here. It always comes last.")
                        .font(Theme.sans(13)).foregroundStyle(Theme.ink3)
                    autoSortField(label: "Move new tabs to the shelf that fits",
                                  hint: "Tabs no rule catches go to Claude, which moves each one to whichever shelf fits what the page is about. Tabs that fit nowhere stay here. Needs Claude Code.")
                case .agent:
                    VStack(alignment: .leading, spacing: 10) {
                        Text("An agent made this shelf and filed tabs onto it. It goes away by itself once those tabs are read. Keep it to make it one of your shelves, with its own rules.")
                            .font(Theme.sans(13)).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true)
                        Button("Keep this shelf") { library.keep(category.id) }.buttonStyle(DeskButtonStyle(.outline))
                    }
                case .readLater:
                    Text("Pages you save with Read later (the bookmark on a card or in the reader, or right-click a page). They stay here after their Helium tab closes, until you mark them done.")
                        .font(Theme.sans(13)).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true)
                case .user:
                    field("Inside", hint: "Sub-shelves are checked before the shelf they sit in, so a tab lands on the deepest shelf that matches.") {
                        Picker("Inside", selection: parentBinding) {
                            Text("None (top level)").tag("")
                            ForEach(parentOptions) { option in
                                Text(library.pathName(of: option.id)).tag(option.id)
                            }
                        }
                        .pickerStyle(.menu).labelsHidden().fixedSize()
                    }
                    autoSortField(label: "Sort new tabs into sub-shelves automatically",
                                  hint: "When new tabs land directly on this shelf, Claude reads what each is about and files it into a sub-shelf. It prefers the sub-shelves you made and adds at most 2 new ones per run. Needs Claude Code.")
                        .disabled(library.tree.children(of: category.id).isEmpty && !library.autoSortShelves.contains(category.id))
                    field("Sites", hint: "arxiv.org matches the site and its subdomains · docs. matches hosts starting with it · /blog/ matches anywhere in the address") {
                        TextField("arxiv.org, docs., /blog/", text: $sites, axis: .vertical).lineLimit(2...6).modifier(FieldBox())
                    }
                    field("Title words", hint: "Comma-separated words that appear in a tab’s title.") {
                        TextField("paper, syllabus, tutorial", text: $keywords, axis: .vertical).lineLimit(1...4).modifier(FieldBox())
                    }
                    if !pinned.isEmpty {
                        field("Pinned sites", hint: "Added from a card’s menu with “Always file … in”. Click to unpin.") {
                            FlowLayout(spacing: 6, lineSpacing: 6) {
                                ForEach(pinned, id: \.self) { site in
                                    Button { library.unpinSite(site) } label: {
                                        HStack(spacing: 5) { Text(site); Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                                            .font(Theme.mono(11)).foregroundStyle(Theme.ink2)
                                            .padding(.horizontal, 10).padding(.vertical, 5)
                                            .overlay(Capsule().strokeBorder(Theme.rule))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    HStack(spacing: 8) {
                        Button { library.move(category.id, by: -1) } label: { Label("Earlier", systemImage: "arrow.up") }
                            .buttonStyle(DeskButtonStyle(.outline))
                            .disabled(siblings.first?.id == category.id)
                            .help("Move before the previous shelf at this level")
                        Button { library.move(category.id, by: 1) } label: { Label("Later", systemImage: "arrow.down") }
                            .buttonStyle(DeskButtonStyle(.outline))
                            .disabled(siblings.last?.id == category.id)
                            .help("Move after the next shelf at this level")
                        Spacer()
                        Button(role: .destructive) {
                            let parent = library.category(withID: category.id)?.parentID
                            library.delete(category.id)
                            select(parent ?? library.categories.first?.id)
                        } label: { Text("Delete shelf").foregroundStyle(Theme.error) }
                            .help("Shelves inside this one move up a level")
                            .buttonStyle(.plain).font(Theme.sans(12.5, .medium))
                    }
                }
            }
            .padding(28)
        }
        .onChange(of: name) { _, value in
            if !value.trimmed.isEmpty { library.update(category.id) { $0.name = value.trimmed } }
        }
        .onChange(of: sites) { _, value in library.update(category.id) { $0.domains = Self.list(value) } }
        .onChange(of: keywords) { _, value in library.update(category.id) { $0.keywords = Self.list(value) } }
    }

    private func autoSortField(label: String, hint: String) -> some View {
        field("Sort with Claude", hint: hint) {
            Toggle(label, isOn: Binding(get: { library.autoSortShelves.contains(category.id) },
                                        set: { library.setAutoSort(category.id, $0) }))
                .toggleStyle(.switch).controlSize(.small)
                .font(Theme.sans(12.5)).foregroundStyle(Theme.ink2)
        }
    }

    private func field<Content: View>(_ label: String, hint: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(label).font(Theme.serif(17, italic: true)).foregroundStyle(Theme.ink2)
            content()
            Text(hint).font(Theme.sans(11.5)).foregroundStyle(Theme.ink4).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct FieldBox: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(Theme.mono(12))
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.rule))
    }
}

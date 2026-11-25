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

    private func shelves(_ groups: [String: [BrowserTab]]) -> [Category] {
        library.categories
            .filter { !(groups[$0.id]?.isEmpty ?? true) }
            .sorted { lhs, rhs in
                if lhs.isOther != rhs.isOther { return rhs.isOther }
                if lhs.isLater != rhs.isLater { return lhs.isLater }
                return (groups[lhs.id]?.count ?? 0) > (groups[rhs.id]?.count ?? 0)
            }
    }

    private func readingTime(_ tabs: [BrowserTab]) -> String? {
        let minutes = tabs.compactMap { previews.info[$0.address]?.minutes }.reduce(0, +)
        guard minutes > 0 else { return nil }
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }

    var body: some View {
        let groups = library.grouped()
        let ordered = shelves(groups)
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
                    masthead(ordered, groups: groups)
                        .padding(.top, 30)
                    Hairline().padding(.top, 22)
                    if library.tabs.isEmpty {
                        empty.padding(.top, 60)
                    } else if let selected {
                        let tabs = matching(groups[selected.id] ?? [])
                        summary(tabs, category: selected).padding(.vertical, 18)
                        grid(tabs, columns: columns, width: columnWidth, shared: shared)
                    } else if !query.isEmpty {
                        let tabs = matching(library.tabs)
                        summary(tabs, category: nil).padding(.vertical, 18)
                        grid(tabs, columns: columns, width: columnWidth, shared: shared)
                    } else {
                        summary(library.tabs, category: nil).padding(.vertical, 18)
                        ForEach(Array(ordered.enumerated()), id: \.element.id) { index, category in
                            section(category, tabs: groups[category.id] ?? [], index: index, columns: columns, width: columnWidth, shared: shared)
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
            ShortcutButton("All shelves", "[") { select(nil) }
        }
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

    /// The shelf index: big Garamond words with superscript counts.
    private func masthead(_ ordered: [Category], groups: [String: [BrowserTab]]) -> some View {
        FlowLayout(spacing: 30, lineSpacing: 2) {
            ShelfWord(name: "All", count: library.tabs.count, selected: selectedCategory == nil) { select(nil) }
            ForEach(ordered) { category in
                ShelfWord(name: category.name, count: groups[category.id]?.count ?? 0,
                          selected: selectedCategory == category.id, agent: category.isAgentMade) { select(category.id) }
            }
        }
    }

    private func summary(_ tabs: [BrowserTab], category: Category?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
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

    private func section(_ category: Category, tabs: [BrowserTab], index: Int, columns: Int, width: CGFloat, shared: (images: Set<String>, summaries: Set<String>)) -> some View {
        let shown = Array(tabs.prefix(columns * 2))
        return VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(Self.roman(index + 1)).font(Theme.serif(15, italic: true)).foregroundStyle(Theme.accent)
                Button { select(category.id) } label: {
                    Text(category.name).font(Theme.serif(30)).foregroundStyle(Theme.ink)
                }
                .buttonStyle(.plain)
                Text("\(tabs.count)").font(Theme.mono(11)).foregroundStyle(Theme.ink3)
                if let time = readingTime(tabs) {
                    Text("· \(time)").font(Theme.mono(11)).foregroundStyle(Theme.ink4)
                }
                Spacer()
                if tabs.count > shown.count {
                    TextAction(title: "All \(tabs.count)", systemImage: "arrow.right", trailing: true) { select(category.id) }
                        .padding(.trailing, 14)
                }
                if tabs.contains(where: { $0.readableURL != nil }) {
                    Button { open(category.id, nil, nil) } label: { Text("Read shelf") }
                        .buttonStyle(DeskButtonStyle(.outline))
                }
            }
            grid(shown, columns: columns, width: width, shared: shared)
        }
        .padding(.top, index == 0 ? 8 : 44)
        .padding(.bottom, 4)
    }

    private func grid(_ tabs: [BrowserTab], columns: Int, width: CGFloat, shared: (images: Set<String>, summaries: Set<String>)) -> some View {
        Group {
            if tabs.isEmpty {
                Text(query.isEmpty ? "Nothing on this shelf." : "No tabs match “\(query)”.")
                    .font(Theme.serif(20, italic: true)).foregroundStyle(Theme.ink3).padding(.vertical, 30)
            } else {
                HStack(alignment: .top, spacing: gutter) {
                    ForEach(0..<columns, id: \.self) { column in
                        LazyVStack(alignment: .leading, spacing: 34) {
                            ForEach(Array(tabs.enumerated()).filter { $0.offset % columns == column }, id: \.element.id) { _, tab in
                                card(tab, width: width, shared: shared)
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

    private func card(_ tab: BrowserTab, width: CGFloat, shared: (images: Set<String>, summaries: Set<String>)) -> some View {
        let category = library.category(for: tab)
        var preview = previews.info[tab.address]
        var image = previews.images[tab.address]
        if let url = preview?.imageURL, shared.images.contains(url), preview?.isPDF != true { image = nil }
        if let summary = preview?.summary, shared.summaries.contains(summary) { preview?.summary = nil }
        return TabCard(tab: tab, preview: preview, image: image,
                       icon: previews.icons[tab.host], width: width,
                       shelfName: selectedCategory == nil && !query.isEmpty ? category.name : nil,
                       categories: library.categories, currentCategory: category.id,
                       noteCount: notes.count(for: tab.address), saved: library.isSaved(tab),
                       open: { _ in open(category.id, tab, nil) },
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
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 3) {
                Text(name)
                    .font(Theme.serif(42, italic: selected))
                    .tracking(-0.6)
                    .foregroundStyle(selected ? Theme.ink : hovered ? Theme.ink2 : Theme.ink3.opacity(0.7))
                if agent {
                    // Shelves an agent made: same type, a small mark so you know who filed them.
                    Image(systemName: "sparkle").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(selected ? Theme.accent : Theme.ink4)
                        .padding(.top, 10)
                        .help("Sorted by an agent. This shelf goes away once its tabs are read.")
                }
                Text("\(count)")
                    .font(Theme.mono(11, .medium))
                    .foregroundStyle(selected ? Theme.accent : Theme.ink4)
                    .padding(.top, 9)
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
    let categories: [Category]
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
                    ForEach(categories) { option in
                        Button { assign(option.id) } label: {
                            if option.id == currentCategory { Label(option.name, systemImage: "checkmark") } else { Text(option.name) }
                        }
                    }
                    Button("Let Reading Desk decide") { assign(nil) }
                }
                if !tab.site.isEmpty {
                    Menu("Always file \(tab.site) in…") {
                        ForEach(categories) { option in Button(option.name) { fileSite(option.id) } }
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
                    Text("A tab is filed on the first shelf, top to bottom, whose rules match it.")
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
        let groups = library.grouped()
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(library.categories.enumerated()), id: \.element.id) { index, category in
                        Button { selection = category.id } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(LibraryView.roman(index + 1)).font(Theme.serif(13, italic: true))
                                    .foregroundStyle(selection == category.id ? Theme.accent : Theme.ink4)
                                    .frame(width: 24, alignment: .trailing)
                                Text(category.name).font(Theme.serif(18))
                                    .foregroundStyle(selection == category.id ? Theme.ink : Theme.ink2).lineLimit(1)
                                Spacer(minLength: 4)
                                Text("\(groups[category.id]?.count ?? 0)").font(Theme.mono(10.5)).foregroundStyle(Theme.ink4)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 8)
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                TextField("Shelf name", text: $name)
                    .textFieldStyle(.plain)
                    .font(Theme.serif(36))
                if category.isOther {
                    Text("Anything that doesn’t match another shelf lands here. It always comes last.")
                        .font(Theme.sans(13)).foregroundStyle(Theme.ink3)
                } else if category.isAgentMade {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("An agent made this shelf and filed tabs onto it. It goes away by itself once those tabs are read. Keep it to make it one of your shelves, with its own rules.")
                            .font(Theme.sans(13)).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true)
                        Button("Keep this shelf") { library.keep(category.id) }.buttonStyle(DeskButtonStyle(.outline))
                    }
                } else if category.isLater {
                    Text("Pages you save with Read later (the bookmark on a card or in the reader, or right-click a page). They stay here after their Helium tab closes, until you mark them done.")
                        .font(Theme.sans(13)).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true)
                } else {
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
                            .disabled(library.categories.first?.id == category.id)
                        Button { library.move(category.id, by: 1) } label: { Label("Later", systemImage: "arrow.down") }
                            .buttonStyle(DeskButtonStyle(.outline))
                        Spacer()
                        Button(role: .destructive) {
                            library.delete(category.id)
                            select(library.categories.first?.id)
                        } label: { Text("Delete shelf").foregroundStyle(Theme.error) }
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

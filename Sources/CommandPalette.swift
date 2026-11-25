import SwiftUI

extension Notification.Name {
    static let openPalette = Notification.Name("ReadingDesk.openPalette")
}

/// ⌘⇧P: a centered search over every tab and shelf, by title, site, shelf,
/// address and the page's own description.
struct CommandPalette: View {
    @ObservedObject var library: Library
    @ObservedObject var previews: Previews
    let close: () -> Void
    let openTab: (BrowserTab) -> Void
    let openShelf: (String) -> Void

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    enum Item: Identifiable {
        case shelf(Category, count: Int)
        case tab(BrowserTab, Category)

        var id: String {
            switch self {
            case .shelf(let category, _): "shelf:" + category.id
            case .tab(let tab, _): "tab:" + tab.id
            }
        }
    }

    private var terms: [String] {
        query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private var items: [Item] {
        let groups = library.grouped()
        let words = terms
        let shelves: [Item] = library.categories.compactMap { category in
            let count = groups[category.id]?.count ?? 0
            guard count > 0 else { return nil }
            if words.isEmpty { return .shelf(category, count: count) }
            let name = category.name.lowercased()
            return words.allSatisfy { name.contains($0) } ? .shelf(category, count: count) : nil
        }
        if words.isEmpty {
            return Array(shelves.prefix(4)) + library.tabs.prefix(30).map { .tab($0, library.category(for: $0)) }
        }
        let tabs = library.tabs.compactMap { tab -> (Int, Item)? in
            let category = library.category(for: tab)
            guard let score = Self.score(tab, category: category, preview: previews.info[tab.address], terms: words) else { return nil }
            return (score, .tab(tab, category))
        }
        .sorted { $0.0 > $1.0 }
        .prefix(60)
        .map(\.1)
        return Array(shelves.prefix(3)) + tabs
    }

    static func score(_ tab: BrowserTab, category: Category, preview: PagePreview?, terms: [String]) -> Int? {
        let title = tab.displayTitle.lowercased()
        let site = tab.site
        let shelf = category.name.lowercased()
        let address = tab.address.lowercased()
        let summary = (preview?.summary ?? "").lowercased()
        let siteName = (preview?.siteName ?? "").lowercased()
        var total = 0
        for term in terms {
            if title.hasPrefix(term) { total += 60 }
            else if title.range(of: "\\b" + NSRegularExpression.escapedPattern(for: term), options: .regularExpression) != nil { total += 45 }
            else if title.contains(term) { total += 30 }
            else if site.hasPrefix(term) || site.contains("." + term) || siteName.hasPrefix(term) { total += 40 }
            else if site.contains(term) || siteName.contains(term) { total += 25 }
            else if shelf.contains(term) { total += 20 }
            else if address.contains(term) { total += 12 }
            else if summary.contains(term) { total += 8 }
            else { return nil }
        }
        return total + (tab.active ? 3 : 0)
    }

    var body: some View {
        let results = items
        ZStack(alignment: .top) {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture(perform: close)
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .regular)).foregroundStyle(Theme.ink3)
                    TextField("Search by title, site, shelf…", text: $query)
                        .textFieldStyle(.plain)
                        .font(Theme.sans(18))
                        .focused($focused)
                        .onSubmit { activate(results, inHelium: false) }
                        .onKeyPress(.upArrow) { move(-1, count: results.count); return .handled }
                        .onKeyPress(.downArrow) { move(1, count: results.count); return .handled }
                        .onKeyPress(.escape) { close(); return .handled }
                        .onKeyPress(keys: [.return], phases: .down) { press in
                            guard press.modifiers.contains(.command) else { return .ignored }
                            activate(results, inHelium: true)
                            return .handled
                        }
                    Text("esc").font(Theme.mono(10)).foregroundStyle(Theme.ink4)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.rule))
                }
                .padding(.horizontal, 20)
                .frame(height: 60)
                Hairline()
                if results.isEmpty {
                    VStack(spacing: 6) {
                        Text("Nothing matches “\(query)”.").font(Theme.serif(20, italic: true)).foregroundStyle(Theme.ink2)
                        Text("Try a site name like arxiv, a word from the title, or a shelf.").font(Theme.sans(12.5)).foregroundStyle(Theme.ink3)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                                    if index == 0 || kind(results[index - 1]) != kind(item) {
                                        Text(kind(item) == 0 ? "Shelves" : (terms.isEmpty ? "Recently in Helium" : "Tabs"))
                                            .font(Theme.serif(13, italic: true)).foregroundStyle(Theme.ink3)
                                            .padding(.horizontal, 20).padding(.top, index == 0 ? 10 : 14).padding(.bottom, 4)
                                    }
                                    row(item, selected: index == selection)
                                        .id(index)
                                        .onHover { if $0 { selection = index } }
                                        .onTapGesture { selection = index; activate(results, inHelium: false) }
                                }
                            }
                            .padding(.bottom, 8)
                        }
                        .frame(maxHeight: 440)
                        .onChange(of: selection) { _, value in proxy.scrollTo(value, anchor: nil) }
                    }
                }
                Hairline()
                HStack(spacing: 16) {
                    hint("↑↓", "move")
                    hint("↩", "read")
                    hint("⌘↩", "open in Helium")
                    Spacer()
                    Text("\(library.tabs.count) tabs").font(Theme.mono(10)).foregroundStyle(Theme.ink4)
                }
                .padding(.horizontal, 20)
                .frame(height: 36)
            }
            .frame(width: 680)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.09)))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.6), radius: 40, y: 20)
            .padding(.top, 110)
        }
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in selection = 0 }
    }

    private func kind(_ item: Item) -> Int {
        if case .shelf = item { return 0 }
        return 1
    }

    private func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }

    private func activate(_ results: [Item], inHelium: Bool) {
        guard results.indices.contains(selection) else { return }
        switch results[selection] {
        case .shelf(let category, _):
            openShelf(category.id)
        case .tab(let tab, _):
            if inHelium, let url = tab.readableURL { Helium.open(url) } else { openTab(tab) }
        }
        close()
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key).font(Theme.mono(10, .medium)).foregroundStyle(Theme.ink2)
            Text(label).font(Theme.sans(11)).foregroundStyle(Theme.ink4)
        }
    }

    @ViewBuilder private func row(_ item: Item, selected: Bool) -> some View {
        HStack(spacing: 13) {
            switch item {
            case .shelf(let category, let count):
                Image(systemName: "books.vertical").font(.system(size: 13)).foregroundStyle(Theme.accent)
                    .frame(width: 20, height: 20)
                Text(highlighted(category.name, size: 17)).lineLimit(1)
                Spacer(minLength: 8)
                Text("\(count) tabs").font(Theme.mono(10.5)).foregroundStyle(Theme.ink3)
            case .tab(let tab, let category):
                Favicon(icon: previews.icons[tab.host], site: tab.sourceName, size: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(highlighted(tab.displayTitle, size: 16)).lineLimit(1)
                    HStack(spacing: 6) {
                        if tab.active { Circle().fill(Theme.accent).frame(width: 5, height: 5) }
                        Text(tab.sourceName).font(Theme.mono(10.5)).foregroundStyle(Theme.ink3)
                    }
                }
                Spacer(minLength: 8)
                Text(category.name).font(Theme.sans(11.5)).foregroundStyle(Theme.ink3).lineLimit(1)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 50)
        .background(selected ? Theme.raised : .clear)
        .overlay(alignment: .leading) {
            if selected { Rectangle().fill(Theme.accent).frame(width: 2) }
        }
        .contentShape(Rectangle())
    }

    /// Serif title with the matched words picked out in the accent color.
    private func highlighted(_ text: String, size: CGFloat) -> AttributedString {
        var result = AttributedString(text)
        result.font = Theme.serif(size, .medium)
        result.foregroundColor = Theme.ink
        let lower = text.lowercased()
        for term in terms where !term.isEmpty {
            var searchStart = lower.startIndex
            let length = result.characters.count
            while let range = lower.range(of: term, range: searchStart..<lower.endIndex) {
                // Map by character offset: lowercasing can shift String indices.
                let from = lower.distance(from: lower.startIndex, to: range.lowerBound)
                let to = lower.distance(from: lower.startIndex, to: range.upperBound)
                if to <= length {
                    let start = result.characters.index(result.startIndex, offsetBy: from)
                    let end = result.characters.index(result.startIndex, offsetBy: to)
                    result[start..<end].foregroundColor = Theme.accent
                }
                searchStart = range.upperBound
            }
        }
        return result
    }
}

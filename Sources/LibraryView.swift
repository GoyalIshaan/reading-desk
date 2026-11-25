import SwiftUI

struct LibraryView: View {
    @ObservedObject var library: Library
    @Binding var selectedShelf: Shelf?
    @Binding var fullscreenOnOpen: Bool
    let open: (Shelf, BrowserTab?) -> Void

    @State private var search = ""
    @FocusState private var searchFocused: Bool

    private var grouped: [Shelf: [BrowserTab]] { Dictionary(grouping: library.tabs, by: library.shelf(for:)) }
    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 390), spacing: 14, alignment: .top)]

    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func matching(_ tabs: [BrowserTab]) -> [BrowserTab] {
        query.isEmpty ? tabs : tabs.filter { tab in
            tab.displayTitle.localizedCaseInsensitiveContains(query) || tab.address.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        let groups = grouped
        VStack(spacing: 0) {
            topBar
            SurfaceRule()
            if let error = library.error {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle")
                    Text(error).textSelection(.enabled)
                    Spacer()
                }
                .font(.callout).foregroundStyle(Theme.error)
                .padding(.horizontal, 26).padding(.vertical, 10)
                .background(Theme.panel)
                SurfaceRule()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let shelf = selectedShelf {
                        detailHeader(for: shelf, tabs: groups[shelf] ?? [])
                        tabList(matching(groups[shelf] ?? []))
                    } else {
                        libraryHeader
                        if library.tabs.isEmpty {
                            empty
                        } else if query.isEmpty {
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                                ForEach(Shelf.allCases) { shelf in
                                    if let tabs = groups[shelf], !tabs.isEmpty {
                                        TopicCard(shelf: shelf, tabs: tabs) { select(shelf) }
                                    }
                                }
                            }
                        } else {
                            tabList(matching(library.tabs))
                        }
                    }
                }
                .padding(.horizontal, 34).padding(.top, 26).padding(.bottom, 32)
                .frame(maxWidth: 1250)
                .frame(maxWidth: .infinity)
                .id(selectedShelf)
            }
            .frame(maxHeight: .infinity)
        }
        .background(Theme.paper)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { select(nil) } label: {
                HStack(spacing: 8) {
                    DeskMark()
                    Text("Reading Desk").font(Theme.display(16))
                }
            }
            .buttonStyle(.plain)
            .help("Back to topics")
            Spacer(minLength: 12)
            HStack(spacing: 7) {
                Circle().fill(library.tabs.isEmpty ? Theme.muted : Theme.accent).frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text(library.sample ? "Sample tabs" : "Helium")
                Text("·").accessibilityHidden(true)
                Text("\(library.tabs.count) tabs").monospacedDigit()
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.muted)
            Menu {
                Toggle("Enter full screen when opening a tab", isOn: $fullscreenOnOpen)
            } label: {
                Label("Reading options", systemImage: "slider.horizontal.3")
                    .labelStyle(.iconOnly).frame(width: 25, height: 28)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            Button { library.refresh() } label: {
                Label(library.updating ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(DeskButtonStyle())
            .disabled(library.updating)
        }
        .padding(.horizontal, 24).frame(height: 49)
    }

    private var libraryHeader: some View {
        HStack(alignment: .bottom, spacing: 15) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Tab library").font(Theme.display(39)).tracking(-1.3)
                    .accessibilityAddTraits(.isHeader)
                Text(query.isEmpty ? "Topics" : "Search results")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 12)
            searchField("Find a tab by title or site").frame(width: 300)
        }
    }

    private func detailHeader(for shelf: Shelf, tabs: [BrowserTab]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Button { select(nil) } label: { Label("All topics", systemImage: "chevron.left") }
                .buttonStyle(DeskButtonStyle())
                .keyboardShortcut("[", modifiers: .command)
            HStack(spacing: 14) {
                TopicIcon(shelf: shelf, size: 48)
                VStack(alignment: .leading, spacing: 1) {
                    Text(shelf.rawValue).font(Theme.display(35)).tracking(-1.1)
                        .accessibilityAddTraits(.isHeader)
                    Text(tabs.count == 1 ? "1 open tab" : "\(tabs.count) open tabs")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.muted)
                }
                Spacer()
                if tabs.contains(where: { $0.readableURL != nil }) {
                    Button { open(shelf, nil) } label: { Label("Start reading", systemImage: "arrow.up.right") }
                        .buttonStyle(DeskButtonStyle(prominent: true))
                }
            }
            searchField("Search this topic")
        }
    }

    private func select(_ shelf: Shelf?) {
        selectedShelf = shelf
        search = ""
        searchFocused = false
    }

    private func searchField(_ placeholder: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
            TextField(placeholder, text: $search)
                .font(.system(size: 13))
                .textFieldStyle(.plain)
                .focused($searchFocused)
            if !query.isEmpty {
                DeskIcon("xmark.circle.fill", help: "Clear search") { search = "" }
            } else {
                Button("⌘ K") { searchFocused = true }
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .buttonStyle(.plain)
                    .keyboardShortcut("k", modifiers: .command)
                    .foregroundStyle(Theme.muted)
                    .accessibilityLabel("Focus tab search")
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 36)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(searchFocused ? Theme.accent : Theme.line) }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            if library.updating {
                ProgressView().controlSize(.small)
                Text("Reading open tabs…").font(.callout).foregroundStyle(Theme.muted)
            } else {
                Text("No tabs to show").font(Theme.display(23))
                if library.error == nil {
                    Text("Open a tab in Helium, then refresh the library.").font(.callout).foregroundStyle(Theme.muted)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 9))
    }

    private func tabList(_ tabs: [BrowserTab]) -> some View {
        Group {
            if tabs.isEmpty {
                Text(query.isEmpty ? "No tabs in this topic." : "No tabs match “\(query)”.")
                    .font(.callout).foregroundStyle(Theme.muted).padding(.vertical, 12)
            } else {
                LazyVStack(spacing: 7) {
                    ForEach(tabs) { tab in
                        let shelf = library.shelf(for: tab)
                        TabRow(tab: tab, shelf: shelf, showTopic: selectedShelf == nil, open: { open(shelf, tab) }) { assignment in
                            library.assign(tab, to: assignment)
                        }
                    }
                }
            }
        }
    }
}

private struct TopicIcon: View {
    let shelf: Shelf
    let size: CGFloat

    var body: some View {
        Image(systemName: shelf.symbol)
            .font(.system(size: size * 0.41, weight: .medium))
            .foregroundStyle(shelf.tint)
            .frame(width: size, height: size)
            .background(shelf.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)
    }
}

private struct TopicCard: View {
    let shelf: Shelf
    let tabs: [BrowserTab]
    let action: () -> Void
    @State private var hovered = false
    private var countLabel: String { tabs.count == 1 ? "1 tab" : "\(tabs.count) tabs" }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    TopicIcon(shelf: shelf, size: 41)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(hovered ? shelf.tint : Theme.muted)
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 12)
                Text(shelf.rawValue).font(Theme.display(20)).tracking(-0.3)
                Text(countLabel)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted)
                    .padding(.top, 3)
            }
            .padding(15)
            .frame(maxWidth: .infinity, minHeight: 130, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 10).fill(hovered ? Theme.raised : Theme.panel)
                RoundedRectangle(cornerRadius: 10).strokeBorder(hovered ? shelf.tint.opacity(0.68) : Theme.line)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel("\(shelf.rawValue), \(countLabel)")
    }
}

private struct TabRow: View {
    let tab: BrowserTab
    let shelf: Shelf
    let showTopic: Bool
    let open: () -> Void
    let assign: (Shelf?) -> Void

    @State private var hovered = false

    var body: some View {
        HStack(spacing: 2) {
            Button(action: open) {
                HStack(spacing: 11) {
                    Group {
                        if tab.host.isEmpty {
                            Image(systemName: tab.readableURL == nil ? "macwindow" : "doc.text")
                        } else {
                            Text(String(tab.sourceName.prefix(1)).uppercased()).font(Theme.display(15))
                        }
                    }
                    .foregroundStyle(shelf.tint)
                    .frame(width: 33, height: 33)
                    .background(shelf.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tab.displayTitle)
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                        Text(tab.sourceName)
                            .font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if showTopic {
                        Text(shelf.rawValue).font(.system(size: 11, weight: .medium))
                            .foregroundStyle(shelf.tint).lineLimit(1)
                    }
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(hovered ? shelf.tint : Theme.muted)
                        .padding(.horizontal, 5)
                        .accessibilityHidden(true)
                }
                .padding(.vertical, 9).padding(.leading, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tab.readableURL == nil ? "Switch to this tab in Helium" : tab.address)
            Menu {
                Button("Automatic category") { assign(nil) }
                Divider()
                ForEach(Shelf.allCases) { category in
                    Button { assign(category) } label: {
                        if category == shelf { Label(category.rawValue, systemImage: "checkmark") }
                        else { Text(category.rawValue) }
                    }
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)).frame(width: 26)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Change category for \(tab.displayTitle)")
        }
        .padding(.trailing, 6)
        .background {
            RoundedRectangle(cornerRadius: 8).fill(hovered ? Theme.raised : Theme.panel)
            RoundedRectangle(cornerRadius: 8).strokeBorder(hovered ? Theme.muted.opacity(0.35) : Theme.line)
        }
        .onHover { hovered = $0 }
    }
}

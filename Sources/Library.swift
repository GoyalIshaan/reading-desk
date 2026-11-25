import AppKit
import Foundation

/// A shelf that tabs are filed into. Shelves can be nested via `parentID`.
struct Category: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var symbol: String
    var hue: Double
    var domains: [String] = []
    var keywords: [String] = []
    /// nil for top-level shelves. Optional so older saved shelves still decode.
    var parentID: String? = nil

    static let otherID = "other"
    var isOther: Bool { id == Self.otherID }

    /// Site rules accept three forms:
    /// - `arxiv.org`  matches the domain and any subdomain
    /// - `docs.`      matches hosts that start with it
    /// - `/blog/`     matches anywhere in the URL
    func matches(_ tab: BrowserTab) -> Bool {
        let host = tab.host
        let address = tab.address.lowercased()
        let title = tab.title.lowercased()
        for raw in domains {
            let rule = raw.trimmingCharacters(in: .whitespaces).lowercased()
            guard !rule.isEmpty else { continue }
            if rule.contains("/") {
                if address.contains(rule) { return true }
            } else if rule.hasSuffix(".") {
                if host.hasPrefix(rule) { return true }
            } else {
                let bare = rule.hasPrefix(".") ? String(rule.dropFirst()) : rule
                if host == bare || host.hasSuffix("." + bare) { return true }
            }
        }
        return keywords.contains { word in
            let word = word.trimmingCharacters(in: .whitespaces).lowercased()
            return !word.isEmpty && title.contains(word)
        }
    }

    static let defaults: [Category] = [
        Category(id: "ai", name: "AI assistants", symbol: "sparkle", hue: 0.46,
                 domains: ["chatgpt.com", "claude.ai", "gemini.google.com", "perplexity.ai", "grok.com"]),
        Category(id: "research", name: "Papers & research", symbol: "books.vertical", hue: 0.10,
                 domains: ["arxiv.org", "openreview.net", "semanticscholar.org", "acm.org", "ieee.org", "paperswithcode.com",
                           "nature.com", "springer.com", "doi.org", "nih.gov", "scholar.google.com"],
                 keywords: ["arxiv", "technical report"]),
        Category(id: "learning", name: "Courses & learning", symbol: "graduationcap", hue: 0.74,
                 domains: ["canvas.net", "instructure.com", "coursera.org", "edx.org", "gradescope.com", "khanacademy.org",
                           "prairielearn.com", "zybooks.com", "edu"],
                 keywords: ["syllabus", "office hours", "lecture notes"]),
        Category(id: "writing", name: "Writing & documents", symbol: "doc.text", hue: 0.04,
                 domains: ["docs.google.com", "drive.google.com", "notion.so", "overleaf.com", "dropbox.com",
                           "sharepoint.com", "figma.com", "coda.io"]),
        Category(id: "communication", name: "Communication", symbol: "bubble.left.and.bubble.right", hue: 0.15,
                 domains: ["mail.google.com", "outlook.com", "outlook.office.com", "slack.com", "discord.com", "linear.app",
                           "linkedin.com", "reddit.com", "x.com", "bsky.app", "twitter.com"]),
        Category(id: "media", name: "Media", symbol: "play.rectangle", hue: 0.94,
                 domains: ["youtube.com", "youtu.be", "vimeo.com", "twitch.tv", "spotify.com", "netflix.com"]),
        Category(id: "engineering", name: "Code & engineering", symbol: "chevron.left.forwardslash.chevron.right", hue: 0.58,
                 domains: ["github.com", "gitlab.com", "codeberg.org", "stackoverflow.com", "huggingface.co",
                           "developer.mozilla.org", "developer.apple.com", "pytorch.org", "rust-lang.org", "godbolt.org",
                           "llvm.org", "pypi.org", "npmjs.com", "docs.", "developer.", "/docs/"],
                 keywords: ["api reference", "documentation", "language reference"]),
        Category(id: otherID, name: "Everything else", symbol: "rectangle.on.rectangle", hue: 0.66),
    ]

    /// Names used by the first version of the app, for migrating saved assignments.
    static let legacyNames: [String: String] = [
        "Papers & research": "research", "Code & engineering": "engineering", "Courses & learning": "learning",
        "AI assistants": "ai", "Writing & documents": "writing", "Media": "media",
        "Communication": "communication", "Other tabs": otherID,
    ]
}

/// Read-only helpers over the flat shelf list. Siblings keep the order they
/// have in the flat array.
struct ShelfTree {
    static let separator = " › "

    private let byID: [String: Category]
    private let kids: [String?: [Category]]

    init(_ categories: [Category]) {
        byID = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        kids = Dictionary(grouping: categories, by: \.parentID)
    }

    func shelf(_ id: String) -> Category? { byID[id] }

    /// Direct children in order; nil gives the top-level shelves.
    func children(of id: String?) -> [Category] { kids[id] ?? [] }

    /// Ancestors from the root down, ending with the shelf itself.
    func path(of id: String) -> [Category] {
        var chain: [Category] = []
        var next: String? = id
        while let current = next, let shelf = byID[current], !chain.contains(where: { $0.id == current }) {
            chain.insert(shelf, at: 0)
            next = shelf.parentID
        }
        return chain
    }

    /// e.g. "AI research › Post-training". Pass `from` to drop that ancestor and everything above it.
    func pathName(of id: String, from ancestor: String? = nil) -> String {
        var chain = path(of: id)
        if let ancestor, let cut = chain.firstIndex(where: { $0.id == ancestor }) { chain.removeFirst(cut + 1) }
        return chain.map(\.name).joined(separator: Self.separator)
    }

    func isInside(_ id: String, _ ancestor: String) -> Bool {
        path(of: id).dropLast().contains { $0.id == ancestor }
    }

    /// Every shelf with its depth, parents before children.
    func flattened() -> [(category: Category, depth: Int)] {
        func walk(_ parent: String?, _ depth: Int) -> [(category: Category, depth: Int)] {
            children(of: parent).flatMap { [($0, depth)] + walk($0.id, depth + 1) }
        }
        return walk(nil, 0)
    }

    /// No cycles, and "Everything else" can't be a parent or a child.
    func canNest(_ id: String, under parent: String?) -> Bool {
        guard id != Category.otherID, byID[id] != nil else { return false }
        guard let parent else { return true }
        return parent != id && parent != Category.otherID && byID[parent] != nil && !isInside(parent, id)
    }

    /// Rolls direct tab counts up so each shelf's total includes its sub-shelves.
    func totals(_ direct: [String: Int]) -> [String: Int] {
        var totals: [String: Int] = [:]
        for (id, count) in direct {
            for shelf in path(of: id) { totals[shelf.id, default: 0] += count }
        }
        return totals
    }

    /// Lower-cased path parts. "›", ">" and "/" all count as separators.
    static func components(_ text: String) -> [String] {
        text.split(whereSeparator: { "›>/".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    /// Fixes up saved data: bad or cyclic parents become top-level.
    static func sanitized(_ list: [Category]) -> [Category] {
        var list = list
        let ids = Set(list.map(\.id))
        for index in list.indices {
            let parent = list[index].parentID
            if list[index].isOther || parent == Category.otherID || parent == list[index].id || parent.map({ !ids.contains($0) }) == true {
                list[index].parentID = nil
            }
        }
        for index in list.indices {
            var seen: Set<String> = [list[index].id]
            var next = list[index].parentID
            while let current = next {
                if seen.contains(current) { list[index].parentID = nil; break }
                seen.insert(current)
                next = list.first { $0.id == current }?.parentID
            }
        }
        return list
    }
}

struct BrowserTab: Decodable, Identifiable, Hashable {
    struct Copy: Hashable { let windowID: String; let id: String }

    let id: String
    let windowID: String
    let title: String
    let address: String
    var windowOrder = 0
    var tabOrder = 0
    var active = false
    /// Other Helium tabs showing the same address. Closed together on Done.
    var duplicates: [Copy] = []

    private enum CodingKeys: String, CodingKey { case id, windowID, title, address, windowOrder, tabOrder, active }

    init(id: String, windowID: String, title: String, address: String) {
        self.id = id
        self.windowID = windowID
        self.title = title
        self.address = address
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        windowID = try container.decode(String.self, forKey: .windowID)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        address = try container.decodeIfPresent(String.self, forKey: .address) ?? ""
        windowOrder = try container.decodeIfPresent(Int.self, forKey: .windowOrder) ?? 0
        tabOrder = try container.decodeIfPresent(Int.self, forKey: .tabOrder) ?? 0
        active = try container.decodeIfPresent(Bool.self, forKey: .active) ?? false
    }

    var copies: [Copy] { [Copy(windowID: windowID, id: id)] + duplicates }

    /// New-tab pages, settings and other browser internals aren't reading material.
    var isInternal: Bool {
        guard let scheme = url?.scheme?.lowercased() else { return address.isEmpty }
        return ["chrome", "helium", "about", "chrome-extension", "devtools", "view-source", "edge"].contains(scheme)
    }

    var url: URL? { URL(string: address) }
    var host: String { url?.host?.lowercased() ?? "" }
    var site: String { host.hasPrefix("www.") ? String(host.dropFirst(4)) : host }
    var sourceName: String {
        if !host.isEmpty { return site }
        if url?.isFileURL == true { return "Local file" }
        return url?.scheme ?? "Helium"
    }

    var displayTitle: String { title.isEmpty ? (address.isEmpty ? "New tab" : address) : title }
    var readableURL: URL? {
        guard let url, url.isFileURL || (["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil) else { return nil }
        return url
    }
}

enum Helium {
    static let bundleID = "net.imput.helium"

    struct ImportError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static var running: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    static func run(_ arguments: [String] = []) async throws -> Data {
        guard let script = Bundle.main.url(forResource: "helium", withExtension: "js") else {
            throw ImportError(message: "The Helium script is missing. Rebuild Reading Desk.")
        }
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-l", "JavaScript", script.path] + arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 18, execute: timeout)
            defer { timeout.cancel() }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let details = String(decoding: data, as: UTF8.self)
                if details.contains("-1743") || details.contains("Apple events") {
                    throw ImportError(message: "Allow Reading Desk to control Helium in System Settings → Privacy & Security → Automation.")
                }
                if process.terminationReason == .uncaughtSignal {
                    throw ImportError(message: "Helium didn’t respond. If macOS is asking for permission, allow it, then refresh.")
                }
                throw ImportError(message: details.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return data
        }.value
    }

    static func open(_ url: URL) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }
}

@MainActor
final class Library: ObservableObject {
    @Published var tabs: [BrowserTab] = []
    @Published private(set) var categories: [Category] { didSet { tree = ShelfTree(categories) } }
    private(set) var tree = ShelfTree([])
    @Published private(set) var assignments: [String: String]
    @Published private(set) var siteRules: [String: String]
    @Published private(set) var finishedToday: Int
    /// Shelves where Claude files new tabs into sub-shelves.
    @Published private(set) var autoSortShelves: Set<String>
    @Published var updating = false
    @Published var error: String?
    @Published var loaded = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var rawCount = 0
    @Published var sample = ProcessInfo.processInfo.arguments.contains("--sample")

    private var refreshTask: Task<Void, Never>?
    /// Tabs finished this session. Hidden even if a refresh races the close.
    private var finished: Set<String> = []
    private let defaults = UserDefaults.standard

    init() {
        let store = UserDefaults.standard
        var loadedCategories = (store.data(forKey: "shelves.v2")).flatMap { try? JSONDecoder().decode([Category].self, from: $0) }
            ?? Category.defaults
        if let index = loadedCategories.firstIndex(where: \.isOther) {
            loadedCategories.append(loadedCategories.remove(at: index))
        } else {
            loadedCategories.append(Category.defaults.last!)
        }
        let sanitized = ShelfTree.sanitized(loadedCategories)
        categories = sanitized
        tree = ShelfTree(sanitized)

        if let saved = store.dictionary(forKey: "assignments.v2") as? [String: String] {
            assignments = saved
        } else if let legacy = store.dictionary(forKey: "categories") as? [String: String] {
            assignments = legacy.compactMapValues { Category.legacyNames[$0] }
        } else {
            assignments = [:]
        }
        siteRules = store.dictionary(forKey: "siteRules.v2") as? [String: String] ?? [:]
        // Ignore ids for shelves that no longer exist.
        autoSortShelves = Set(store.stringArray(forKey: "autoSort.v1") ?? []).filter { id in sanitized.contains { $0.id == id } }

        let today = Self.dayStamp()
        finishedToday = store.string(forKey: "finished.day") == today ? store.integer(forKey: "finished.count") : 0
    }

    // MARK: Tabs

    func refresh() {
        guard refreshTask == nil else { return }
        if sample {
            tabs = Self.sampleTabs.filter { !finished.contains($0.id) }
            loaded = true
            return
        }
        updating = true
        error = nil
        refreshTask = Task {
            defer {
                updating = false
                loaded = true
                refreshTask = nil
            }
            guard Helium.running else {
                error = "Open Helium to import its tabs."
                return
            }
            do {
                let imported = try JSONDecoder().decode([BrowserTab].self, from: try await Helium.run())
                rawCount = imported.count
                tabs = Self.merge(imported.filter { !finished.contains($0.id) })
                lastUpdated = .now
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// One card per address, in Helium's order (front window first, left to right).
    static func merge(_ imported: [BrowserTab]) -> [BrowserTab] {
        var order: [String] = []
        var byAddress: [String: BrowserTab] = [:]
        for tab in imported.sorted(by: { ($0.windowOrder, $0.tabOrder) < ($1.windowOrder, $1.tabOrder) }) where !tab.isInternal {
            if var existing = byAddress[tab.address] {
                existing.duplicates.append(BrowserTab.Copy(windowID: tab.windowID, id: tab.id))
                byAddress[tab.address] = existing
            } else {
                byAddress[tab.address] = tab
                order.append(tab.address)
            }
        }
        return order.compactMap { byAddress[$0] }
    }

    /// Marks a tab as read: hides it here and, optionally, closes it in Helium.
    func finish(_ tab: BrowserTab, closeInHelium: Bool) {
        tab.copies.forEach { finished.insert($0.id) }
        tabs.removeAll { $0.id == tab.id }
        let today = Self.dayStamp()
        finishedToday = (defaults.string(forKey: "finished.day") == today ? finishedToday : 0) + 1
        defaults.set(today, forKey: "finished.day")
        defaults.set(finishedToday, forKey: "finished.count")
        guard closeInHelium, !sample else { return }
        Task {
            do { _ = try await Helium.run(["close"] + tab.copies.flatMap { [$0.windowID, $0.id] }) }
            catch { self.error = "Couldn’t close the tab in Helium: \(error.localizedDescription)" }
        }
    }

    // MARK: Filing

    var other: Category { categories.last { $0.isOther } ?? Category.defaults.last! }

    func category(withID id: String) -> Category? { tree.shelf(id) }

    func pathName(of id: String) -> String { tree.pathName(of: id) }

    /// Looks a shelf up by id, name or path (for the bridge and CLI).
    /// If a name is shared, the top-level shelf wins; use a path to pick a nested one.
    func category(matching token: String) -> Category? {
        let token = token.trimmed
        if let exact = category(withID: token) { return exact }
        let ordered = tree.flattened().map(\.category)
        let named = ordered.filter { $0.name.caseInsensitiveCompare(token) == .orderedSame }
        if named.count == 1 { return named[0] }
        let parts = ShelfTree.components(token)
        if parts.count > 1, let match = ordered.first(where: { ShelfTree.components(tree.pathName(of: $0.id)) == parts }) {
            return match
        }
        return named.first { $0.parentID == nil } ?? named.first
    }

    /// "A › B" -> (parent: "A", leaf: "B"). "/" doesn't split, so "CI/CD" stays one name.
    static func splitCreatePath(_ name: String) -> (parent: String?, leaf: String) {
        let parts = name.split(whereSeparator: { "›>".contains($0) }).map { String($0).trimmed }.filter { !$0.isEmpty }
        guard parts.count > 1 else { return (nil, name.trimmed) }
        return (parts.dropLast().joined(separator: ShelfTree.separator), parts.last!)
    }

    /// Assign by raw URL, for the bridge (no BrowserTab needed).
    func assign(address: String, to id: String?) {
        assignments[address] = id
        defaults.set(assignments, forKey: "assignments.v2")
    }

    func fileSite(_ site: String, to id: String) {
        let site = site.lowercased()
        guard !site.isEmpty else { return }
        siteRules[site] = id
        defaults.set(siteRules, forKey: "siteRules.v2")
    }

    /// Return a shelf with this name, creating one if there isn't yet.
    /// With `parentID`, only that shelf's direct children count and a new shelf goes inside it.
    @discardableResult
    func ensureCategory(named name: String, symbol: String?, parentID: String? = nil) -> Category {
        let candidates = parentID.map { tree.children(of: $0) } ?? tree.flattened().map(\.category)
        if let existing = candidates.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return existing }
        let id = addCategory(inside: parentID)
        update(id) { shelf in
            shelf.name = name
            if let symbol { shelf.symbol = symbol }
        }
        return category(withID: id) ?? other
    }

    /// Manual picks and site rules win. Otherwise top-level shelves are checked in order,
    /// and sub-shelves are checked before their parent so the most specific shelf wins.
    func category(for tab: BrowserTab) -> Category {
        if let id = assignments[tab.address], let manual = category(withID: id) { return manual }
        if let id = siteRules[tab.site], let site = category(withID: id) { return site }
        func deepest(_ shelf: Category) -> Category? {
            for child in tree.children(of: shelf.id) { if let hit = deepest(child) { return hit } }
            return shelf.matches(tab) ? shelf : nil
        }
        for shelf in tree.children(of: nil) where !shelf.isOther {
            if let hit = deepest(shelf) { return hit }
        }
        return other
    }

    /// Tabs filed directly on each shelf (not counting sub-shelves).
    func grouped() -> [String: [BrowserTab]] {
        Dictionary(grouping: tabs) { category(for: $0).id }
    }

    func totals(_ groups: [String: [BrowserTab]]) -> [String: Int] {
        tree.totals(groups.mapValues(\.count))
    }

    /// Non-empty shelves under `parent`, biggest first, "Everything else" last.
    func visibleChildren(of parent: String?, totals: [String: Int]) -> [Category] {
        tree.children(of: parent).enumerated()
            .filter { (totals[$0.element.id] ?? 0) > 0 }
            .sorted { lhs, rhs in
                if lhs.element.isOther != rhs.element.isOther { return rhs.element.isOther }
                let (left, right) = (totals[lhs.element.id] ?? 0, totals[rhs.element.id] ?? 0)
                return left != right ? left > right : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// All tabs under a shelf in page order: sub-shelves first, then its own tabs.
    /// The reader uses this too, so it follows the page top to bottom.
    func orderedTabs(in id: String, groups: [String: [BrowserTab]], totals: [String: Int]) -> [BrowserTab] {
        visibleChildren(of: id, totals: totals).flatMap { orderedTabs(in: $0.id, groups: groups, totals: totals) }
            + (groups[id] ?? [])
    }

    func orderedTabs(in id: String) -> [BrowserTab] {
        let groups = grouped()
        return orderedTabs(in: id, groups: groups, totals: totals(groups))
    }

    func assign(_ tab: BrowserTab, to id: String?) {
        assignments[tab.address] = id
        defaults.set(assignments, forKey: "assignments.v2")
    }

    /// "Always file this site here" — wins over shelf rules, loses to a manual pick.
    func fileSite(of tab: BrowserTab, in id: String) {
        guard !tab.site.isEmpty else { return }
        siteRules[tab.site] = id
        assignments[tab.address] = nil
        defaults.set(siteRules, forKey: "siteRules.v2")
        defaults.set(assignments, forKey: "assignments.v2")
    }

    func setAutoSort(_ id: String, _ on: Bool) {
        guard category(withID: id) != nil || !on else { return }
        if on { autoSortShelves.insert(id) } else { autoSortShelves.remove(id) }
        defaults.set(Array(autoSortShelves), forKey: "autoSort.v1")
    }

    func unpinSite(_ site: String) {
        siteRules[site] = nil
        defaults.set(siteRules, forKey: "siteRules.v2")
    }

    // MARK: Editing shelves

    func update(_ id: String, _ change: (inout Category) -> Void) {
        guard let index = categories.firstIndex(where: { $0.id == id }) else { return }
        change(&categories[index])
        saveCategories()
    }

    /// New top-level shelves go first; new sub-shelves go last among their siblings.
    @discardableResult
    func addCategory(inside parent: String? = nil) -> String {
        let parent = parent.flatMap { tree.shelf($0) != nil && $0 != Category.otherID ? $0 : nil }
        let shelf = Category(id: UUID().uuidString, name: parent == nil ? "New shelf" : "New sub-shelf",
                             symbol: "bookmark", hue: 0, parentID: parent)
        if parent == nil {
            categories.insert(shelf, at: 0)
        } else {
            categories.insert(shelf, at: categories.firstIndex(where: \.isOther) ?? categories.count)
        }
        saveCategories()
        return shelf.id
    }

    /// Moves a shelf under a new parent (nil = top level), as its last child.
    func setParent(_ id: String, to parent: String?) {
        guard tree.canNest(id, under: parent), let index = categories.firstIndex(where: { $0.id == id }),
              categories[index].parentID != parent else { return }
        var shelf = categories.remove(at: index)
        shelf.parentID = parent
        categories.insert(shelf, at: categories.firstIndex(where: \.isOther) ?? categories.count)
        saveCategories()
    }

    /// Sub-shelves of a deleted shelf move up a level into its spot.
    func delete(_ id: String) {
        guard id != Category.otherID, let deleted = category(withID: id) else { return }
        let childIDs = Set(tree.children(of: id).map(\.id))
        var list = categories
        var children = list.filter { childIDs.contains($0.id) }
        for index in children.indices { children[index].parentID = deleted.parentID }
        list.removeAll { childIDs.contains($0.id) }
        if let slot = list.firstIndex(where: { $0.id == id }) {
            list.remove(at: slot)
            list.insert(contentsOf: children, at: slot)
        }
        categories = list
        setAutoSort(id, false)
        assignments = assignments.filter { $0.value != id }
        siteRules = siteRules.filter { $0.value != id }
        defaults.set(assignments, forKey: "assignments.v2")
        defaults.set(siteRules, forKey: "siteRules.v2")
        saveCategories()
    }

    /// Reorders a shelf among its siblings.
    func move(_ id: String, by offset: Int) {
        guard let shelf = category(withID: id), !shelf.isOther else { return }
        let siblings = tree.children(of: shelf.parentID).filter { !$0.isOther }
        guard let position = siblings.firstIndex(where: { $0.id == id }), siblings.indices.contains(position + offset),
              let from = categories.firstIndex(where: { $0.id == id }),
              let to = categories.firstIndex(where: { $0.id == siblings[position + offset].id }) else { return }
        categories.swapAt(from, to)
        saveCategories()
    }

    func resetCategories() {
        categories = Category.defaults
        autoSortShelves = []
        defaults.removeObject(forKey: "autoSort.v1")
        siteRules = [:]
        defaults.set(siteRules, forKey: "siteRules.v2")
        saveCategories()
    }

    private func saveCategories() {
        if let data = try? JSONEncoder().encode(categories) { defaults.set(data, forKey: "shelves.v2") }
    }

    private static func dayStamp() -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: .now)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }

    static let sampleTabs: [BrowserTab] = [
        ("Attention Is All You Need", "https://arxiv.org/abs/1706.03762"),
        ("FlashAttention: Fast and Memory-Efficient Exact Attention", "https://arxiv.org/abs/2205.14135"),
        ("Distilling the Knowledge in a Neural Network", "https://arxiv.org/abs/1503.02531"),
        ("MLIR Language Reference", "https://mlir.llvm.org/docs/LangRef/"),
        ("PyTorch documentation", "https://pytorch.org/docs/stable/index.html"),
        ("tinygrad · GitHub", "https://github.com/tinygrad/tinygrad"),
        ("Apple Developer Documentation", "https://developer.apple.com/documentation/webkit/wkwebview"),
        ("MIT OpenCourseWare", "https://ocw.mit.edu/"),
        ("Machine Learning · Coursera", "https://www.coursera.org/learn/machine-learning"),
        ("ChatGPT", "https://chatgpt.com/"),
        ("Claude", "https://claude.ai/"),
        ("Research notes · Google Docs", "https://docs.google.com/"),
        ("Compiler design lecture · YouTube", "https://www.youtube.com/"),
        ("Paul Graham — How to Do Great Work", "https://paulgraham.com/greatwork.html"),
    ].enumerated().map { index, entry in
        BrowserTab(id: String(index), windowID: "1", title: entry.0, address: entry.1)
    }
}

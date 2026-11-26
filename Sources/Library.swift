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
    /// Created by an agent through the bridge, not by you. Such a shelf holds the tabs the
    /// agent filed there and quietly goes away once they're all read, unless you keep it.
    var madeByAgent: Bool?

    static let otherID = "other"
    static let laterID = "later"

    /// What kind of shelf this is. Saved data stays as before (a magic id or the
    /// `madeByAgent` flag); everything that depends on the kind switches over this,
    /// so adding a kind makes the compiler point at every decision it affects.
    enum Role: Equatable {
        /// The catch-all. Always last, triaged by Claude rather than sorted into sub-shelves.
        case unsorted
        /// Pages saved for later. Wins filing and outlives the Helium tab.
        case readLater
        case user
        /// Made by an agent; goes away once its tabs are read, unless kept.
        case agent
    }

    var role: Role {
        switch id {
        case Self.otherID: .unsorted
        case Self.laterID: .readLater
        default: madeByAgent == true ? .agent : .user
        }
    }

    /// How "Sort with Claude" treats this shelf.
    enum SortMode: Equatable {
        /// Move each tab to whichever other shelf fits; never create shelves.
        case triage
        /// File tabs into this shelf's sub-shelves, creating a few if needed.
        case intoSubShelves
        /// Nothing to sort into.
        case unavailable
    }

    /// Built-in shelves can be renamed but never deleted, nested, reordered or matched by rules.
    var isBuiltIn: Bool {
        switch role {
        case .unsorted, .readLater: true
        case .user, .agent: false
        }
    }

    var sortMode: SortMode {
        switch role {
        case .unsorted: .triage
        case .readLater: .unavailable
        case .user, .agent: .intoSubShelves
        }
    }

    /// Can be the target of a site rule or a stored "Move to shelf" pick. Read later only
    /// holds pages actually saved to it (which outlive their tabs), so a rule can't point there.
    var acceptsRules: Bool {
        switch role {
        case .readLater: false
        case .unsorted, .user, .agent: true
        }
    }

    var isOther: Bool { role == .unsorted }
    var isLater: Bool { role == .readLater }
    var isAgentMade: Bool { role == .agent }

    static let later = Category(id: laterID, name: "Read later", symbol: "clock", hue: 0.08)

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
        later,
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
        Category(id: otherID, name: "Unsorted", symbol: "rectangle.on.rectangle", hue: 0.66),
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
struct ShelfTree: Equatable {
    static let separator = " › "

    private struct CompiledRules {
        let paths: [String]
        let prefixes: [String]
        let hosts: [String]
        let keywords: [String]

        init(_ category: Category) {
            var paths: [String] = []
            var prefixes: [String] = []
            var hosts: [String] = []
            for raw in category.domains {
                let rule = raw.trimmingCharacters(in: .whitespaces).lowercased()
                guard !rule.isEmpty else { continue }
                if rule.contains("/") { paths.append(rule) }
                else if rule.hasSuffix(".") { prefixes.append(rule) }
                else { hosts.append(rule.hasPrefix(".") ? String(rule.dropFirst()) : rule) }
            }
            self.paths = paths
            self.prefixes = prefixes
            self.hosts = hosts
            self.keywords = category.keywords
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
        }

        func matches(host: String, address: String, title: String) -> Bool {
            for rule in hosts where host == rule || host.hasSuffix("." + rule) { return true }
            for rule in prefixes where host.hasPrefix(rule) { return true }
            for rule in paths where address.contains(rule) { return true }
            for word in keywords where title.contains(word) { return true }
            return false
        }
    }

    private let categories: [Category]
    private let byID: [String: Category]
    private let kids: [String?: [Category]]
    private let rules: [String: CompiledRules]

    static func == (lhs: ShelfTree, rhs: ShelfTree) -> Bool {
        lhs.categories == rhs.categories
    }

    init(_ categories: [Category]) {
        self.categories = categories
        byID = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        kids = Dictionary(grouping: categories, by: \.parentID)
        rules = Dictionary(categories.map { ($0.id, CompiledRules($0)) }, uniquingKeysWith: { first, _ in first })
    }

    func matches(_ id: String, host: String, address: String, title: String) -> Bool {
        rules[id]?.matches(host: host, address: address, title: title) ?? false
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

    /// Built-in shelves (Unsorted, Read later) stay top-level and never hold sub-shelves.
    func canHoldChildren(_ id: String) -> Bool {
        byID[id].map { !$0.isBuiltIn } ?? false
    }

    /// No cycles, and built-in shelves can't be a parent or a child.
    func canNest(_ id: String, under parent: String?) -> Bool {
        guard let shelf = byID[id], !shelf.isBuiltIn else { return false }
        guard let parent else { return true }
        return parent != id && canHoldChildren(parent) && !isInside(parent, id)
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
        let parents = Set(list.filter { !$0.isBuiltIn }.map(\.id))
        for index in list.indices {
            let parent = list[index].parentID
            if list[index].isBuiltIn || parent == list[index].id || parent.map({ !parents.contains($0) }) == true {
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

enum Browser: String, CaseIterable, Codable, Identifiable, Hashable {
    case helium
    case chrome
    case safari

    var id: Self { self }

    var name: String {
        switch self {
        case .helium: "Helium"
        case .chrome: "Chrome"
        case .safari: "Safari"
        }
    }

    var fullName: String {
        switch self {
        case .helium: "Helium"
        case .chrome: "Google Chrome"
        case .safari: "Safari"
        }
    }

    var bundleID: String {
        switch self {
        case .helium: "net.imput.helium"
        case .chrome: "com.google.Chrome"
        case .safari: "com.apple.Safari"
        }
    }

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }
}

enum BrowserSource: String, CaseIterable, Identifiable, Hashable {
    case all
    case helium
    case chrome
    case safari

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "All browsers"
        case .helium: "Helium"
        case .chrome: "Chrome"
        case .safari: "Safari"
        }
    }

    var browsers: [Browser] {
        switch self {
        case .all: Browser.allCases
        case .helium: [.helium]
        case .chrome: [.chrome]
        case .safari: [.safari]
        }
    }

    var next: BrowserSource {
        let all = Self.allCases
        guard let i = all.firstIndex(of: self) else { return .all }
        return all[(i + 1) % all.count]
    }
}

struct BrowserTab: Decodable, Identifiable, Hashable {
    struct Copy: Hashable {
        let browser: Browser
        let windowID: String
        let id: String
        let address: String

        var key: String { "\(browser.rawValue):\(windowID):\(id)" }
    }

    let id: String
    let rawID: String
    let windowID: String
    let browser: Browser?
    let title: String
    let address: String
    var windowOrder = 0
    var tabOrder = 0
    var active = false
    /// Other browser tabs showing the same address. Closed together on Done.
    var duplicates: [Copy] = []

    private enum CodingKeys: String, CodingKey { case id, windowID, browser, title, address, windowOrder, tabOrder, active }

    init(id: String, windowID: String, title: String, address: String, browser: Browser? = nil) {
        self.rawID = id
        self.windowID = windowID
        self.browser = browser
        self.id = browser.map { "\($0.rawValue):\(windowID):\(id)" } ?? id
        self.title = title
        self.address = address
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = try container.decode(String.self, forKey: .id)
        let decodedWindow = try container.decode(String.self, forKey: .windowID)
        let decodedBrowser = try container.decodeIfPresent(Browser.self, forKey: .browser)
        rawID = decodedID
        windowID = decodedWindow
        browser = decodedBrowser
        id = decodedBrowser.map { "\($0.rawValue):\(decodedWindow):\(decodedID)" } ?? decodedID
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        address = try container.decodeIfPresent(String.self, forKey: .address) ?? ""
        windowOrder = try container.decodeIfPresent(Int.self, forKey: .windowOrder) ?? 0
        tabOrder = try container.decodeIfPresent(Int.self, forKey: .tabOrder) ?? 0
        active = try container.decodeIfPresent(Bool.self, forKey: .active) ?? false
    }

    var copies: [Copy] {
        let own = browser.map { [Copy(browser: $0, windowID: windowID, id: rawID, address: address)] } ?? []
        return own + duplicates
    }

    var copyKey: String { browser.map { "\($0.rawValue):\(windowID):\(rawID)" } ?? id }

    /// Distinct browser names where this tab is currently open.
    var browserLabel: String {
        var names: [String] = []
        for copy in copies where !names.contains(copy.browser.name) {
            names.append(copy.browser.name)
        }
        return names.isEmpty ? "browser" : names.joined(separator: " & ")
    }

    /// New-tab pages, settings and other browser internals aren't reading material.
    var isInternal: Bool {
        guard let scheme = url?.scheme?.lowercased() else { return address.isEmpty }
        return [
            "chrome", "helium", "about", "chrome-extension", "devtools", "view-source", "edge",
            "favorites", "safari-resource", "safari-extension", "safari-web-extension", "topsites", "bookmarks", "history",
        ].contains(scheme)
    }

    var url: URL? { URL(string: address) }
    var host: String { url?.host?.lowercased() ?? "" }
    var site: String { host.hasPrefix("www.") ? String(host.dropFirst(4)) : host }
    var sourceName: String {
        if !host.isEmpty { return site }
        if url?.isFileURL == true { return "Local file" }
        return url?.scheme ?? browser?.name ?? "Web"
    }

    var displayTitle: String { title.isEmpty ? (address.isEmpty ? "New tab" : address) : title }
    var readableURL: URL? {
        guard let url, url.isFileURL || (["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil) else { return nil }
        return url
    }
}

enum Browsers {
    struct ImportError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func run(_ browser: Browser, arguments: [String] = []) async throws -> Data {
        guard let script = Bundle.main.url(forResource: "browsers", withExtension: "js") else {
            throw ImportError(message: "The browser script is missing. Rebuild Reading Desk.")
        }
        let browserArg = browser.rawValue
        let fullName = browser.fullName
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-l", "JavaScript", script.path, browserArg] + arguments
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
                    throw ImportError(message: "Allow Reading Desk to control \(fullName) in System Settings → Privacy & Security → Automation.")
                }
                if process.terminationReason == .uncaughtSignal {
                    throw ImportError(message: "\(fullName) didn’t respond. If macOS is asking for permission, allow it, then refresh.")
                }
                throw ImportError(message: details.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return data
        }.value
    }

    static func focus(_ tab: BrowserTab) async throws {
        guard let browser = tab.browser else { return }
        _ = try await run(browser, arguments: ["focus", tab.windowID, tab.rawID, tab.address])
    }

    static func close(_ copies: [BrowserTab.Copy]) async throws {
        let grouped = Dictionary(grouping: copies, by: \.browser)
        for browser in Browser.allCases {
            guard let group = grouped[browser], !group.isEmpty else { continue }
            _ = try await run(browser, arguments: ["close"] + group.flatMap { [$0.windowID, $0.id, $0.address] })
        }
    }

    static func open(_ url: URL, in browser: Browser? = nil) {
        let target = browser
            ?? Browser.allCases.first(where: \.isRunning)
            ?? Browser.allCases.first(where: \.isInstalled)
        guard let target, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target.bundleID) else {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }
}

@MainActor
final class Library: ObservableObject {
    @Published var tabs: [BrowserTab] = [] { didSet { filingCache = nil } }
    @Published private(set) var categories: [Category] { didSet { tree = ShelfTree(categories); filingCache = nil } }
    private(set) var tree = ShelfTree([])
    @Published private(set) var assignments: [String: String] { didSet { filingCache = nil } }
    @Published private(set) var siteRules: [String: String] { didSet { filingCache = nil } }
    @Published private(set) var finishedToday: Int
    /// Shelves where Claude files new tabs into sub-shelves.
    @Published private(set) var autoSortShelves: Set<String>
    @Published private(set) var updating = false
    @Published var error: String?
    @Published private(set) var loaded = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var rawCount = 0
    @Published var browserSource: BrowserSource {
        didSet {
            defaults.set(browserSource.rawValue, forKey: "browserSource.v1")
            refreshTask?.cancel()
            refreshTask = nil
            refresh()
        }
    }
    /// Browsers that contributed tabs on the latest refresh.
    @Published private(set) var connectedBrowsers: [Browser] = []
    @Published var sample = ProcessInfo.processInfo.arguments.contains("--sample")

    var activeSourceLabel: String {
        if !connectedBrowsers.isEmpty { return connectedBrowsers.map(\.name).joined(separator: ", ") }
        return browserSource == .all ? "Browser" : browserSource.title
    }

    /// Preferred browser when opening a link that isn't tied to a specific tab (bookmarks, notes, chats).
    var preferredOpenBrowser: Browser? {
        if browserSource != .all { return browserSource.browsers.first }
        return connectedBrowsers.first ?? Browser.allCases.first(where: \.isRunning)
    }
    /// Pages saved to Read later, newest first. They outlive their Helium tabs.
    @Published private(set) var later: [SavedSource] { didSet { laterAddresses = Set(later.map(\.address)); filingCache = nil } }
    /// Cached: `category(for:)` checks it for every tab on every render.
    private var laterAddresses: Set<String> = []
    /// Permanent bookmarks, newest first. Never removed when marking a tab Done.
    @Published private(set) var bookmarks: [Bookmark] { didSet { rebuildBookmarkLookup() } }
    private var bookmarkAddresses: Set<String> = []
    private var bookmarkKeys: Set<String> = []
    static let bookmarksID = "__bookmarks__"
    /// Memoized filing results so LibraryView redraws don't re-run every rule across every tab.
    private struct FilingCache {
        let byAddress: [String: Category]
        let groups: [String: [BrowserTab]]
        let totals: [String: Int]
    }
    private var filingCache: FilingCache?
    /// Agent shelves made this session, with when: they get a grace period to be filled.
    private var agentShelvesMade: [String: Date] = [:]
    /// Helium tabs this app already closed, so a later Done doesn't try again.
    private var closed: Set<String> = []

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
        if !loadedCategories.contains(where: \.isLater) { loadedCategories.insert(Category.later, at: 0) }
        if let index = loadedCategories.firstIndex(where: \.isLater), loadedCategories[index].symbol == "bookmark" {
            loadedCategories[index].symbol = "clock"
        }
        // "Everything else" sat right next to "Everything" in the index; the catch-all is now "Unsorted".
        if let index = loadedCategories.firstIndex(where: \.isOther), loadedCategories[index].name == "Everything else" {
            loadedCategories[index].name = "Unsorted"
        }
        let sanitized = ShelfTree.sanitized(loadedCategories)
        categories = sanitized
        tree = ShelfTree(sanitized)
        let saved = store.data(forKey: "readLater.v1").flatMap { try? JSONDecoder().decode([SavedSource].self, from: $0) } ?? []
        later = saved
        laterAddresses = Set(saved.map(\.address))  // didSet doesn't run during init
        let loadedBookmarks = store.data(forKey: "bookmarks.v1").flatMap { try? JSONDecoder().decode([Bookmark].self, from: $0) } ?? []
        bookmarks = loadedBookmarks
        bookmarkAddresses = Set(loadedBookmarks.map(\.address))
        bookmarkKeys = Set(loadedBookmarks.compactMap { SourceKey.key(for: $0.address) })

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
        browserSource = store.string(forKey: "browserSource.v1").flatMap(BrowserSource.init(rawValue:)) ?? .all

        // Older builds could point a rule at Read later, which then showed pages there that weren't saved.
        let ruleless = Set(sanitized.filter { !$0.acceptsRules }.map(\.id))
        assignments = assignments.filter { !ruleless.contains($0.value) }
        siteRules = siteRules.filter { !ruleless.contains($0.value) }
    }

    // MARK: Tabs

    func refresh() {
        guard refreshTask == nil else { return }
        if sample {
            tabs = withSaved(Self.sampleTabs.filter { !finished.contains($0.copyKey) })
            loaded = true
            return
        }
        updating = true
        error = nil
        let source = browserSource
        refreshTask = Task {
            defer {
                updating = false
                loaded = true
                refreshTask = nil
            }
            let targets = source.browsers.filter(\.isRunning)
            guard !targets.isEmpty else {
                // Saved Read later pages outlive browser tabs, so keep them visible even when closed.
                connectedBrowsers = []
                tabs = withSaved([])
                error = source == .all
                    ? "Open Helium, Chrome, or Safari to import open tabs."
                    : "Open \(source.title) to import its tabs."
                return
            }

            var results: [Browser: [BrowserTab]] = [:]
            var failures: [String] = []

            await withTaskGroup(of: (Browser, Result<[BrowserTab], Error>).self) { group in
                for browser in targets {
                    group.addTask {
                        do {
                            let data = try await Browsers.run(browser)
                            let decoded = try JSONDecoder().decode([BrowserTab].self, from: data)
                            return (browser, .success(decoded))
                        } catch {
                            return (browser, .failure(error))
                        }
                    }
                }
                for await (browser, result) in group {
                    switch result {
                    case .success(let list): results[browser] = list
                    case .failure(let err): failures.append(err.localizedDescription)
                    }
                }
            }

            guard !Task.isCancelled else { return }

            let succeeded = Browser.allCases.filter { results[$0] != nil }
            if !succeeded.isEmpty {
                let imported = succeeded.flatMap { results[$0] ?? [] }
                connectedBrowsers = succeeded
                rawCount = imported.count
                tabs = withSaved(Self.merge(imported.filter { !finished.contains($0.copyKey) }))
                lastUpdated = .now
                pruneAgentShelves()
                if !failures.isEmpty {
                    self.error = failures.joined(separator: " ")
                }
            } else {
                connectedBrowsers = []
                if tabs.isEmpty { tabs = withSaved([]) }
                self.error = failures.joined(separator: " ")
            }
        }
    }

    /// One card per address, ordered by browser then front window first, left to right.
    static func merge(_ imported: [BrowserTab]) -> [BrowserTab] {
        var order: [String] = []
        var byAddress: [String: BrowserTab] = [:]
        let browserRank: (Browser?) -> Int = { browser in
            browser.flatMap { Browser.allCases.firstIndex(of: $0) } ?? Browser.allCases.count
        }
        let sorted = imported.sorted {
            (browserRank($0.browser), $0.windowOrder, $0.tabOrder) < (browserRank($1.browser), $1.windowOrder, $1.tabOrder)
        }
        for tab in sorted where !tab.isInternal {
            if var existing = byAddress[tab.address] {
                if let browser = tab.browser {
                    existing.duplicates.append(BrowserTab.Copy(browser: browser, windowID: tab.windowID, id: tab.rawID, address: tab.address))
                }
                byAddress[tab.address] = existing
            } else {
                byAddress[tab.address] = tab
                order.append(tab.address)
            }
        }
        return order.compactMap { byAddress[$0] }
    }

    /// Saved pages whose browser tab is gone still get a card, after the open tabs.
    private func withSaved(_ open: [BrowserTab]) -> [BrowserTab] {
        let present = Set(open.map(\.address))
        return open + later.filter { !present.contains($0.address) }.map(\.tab)
    }

    func isSaved(_ tab: BrowserTab) -> Bool { laterAddresses.contains(tab.address) }

    /// Puts a page on the Read later shelf and, optionally, closes its browser tab(s).
    func saveForLater(_ tab: BrowserTab, closeInBrowser: Bool) {
        guard tab.readableURL != nil else { return }
        if !isSaved(tab) {
            later.insert(SavedSource(address: tab.address, title: tab.displayTitle, saved: .now), at: 0)
            saveLater()
        }
        let copies = tab.copies.filter { $0.windowID != SavedSource.windowID && !closed.contains($0.key) }
        guard closeInBrowser, !sample, !copies.isEmpty else { return }
        copies.forEach { finished.insert($0.key); closed.insert($0.key) }
        if let index = tabs.firstIndex(where: { $0.address == tab.address }),
           let saved = later.first(where: { $0.address == tab.address }) {
            tabs[index] = saved.tab
        }
        let label = tab.browserLabel
        Task {
            do { try await Browsers.close(copies) }
            catch { self.error = "Couldn’t close the tab in \(label): \(error.localizedDescription)" }
        }
    }

    /// Takes a page off Read later. If its Helium tab is still open it goes back to its usual shelf.
    func removeFromLater(_ address: String) {
        later.removeAll { $0.address == address }
        saveLater()
        tabs.removeAll { $0.windowID == SavedSource.windowID && $0.address == address }
    }

    private func saveLater() {
        if let data = try? JSONEncoder().encode(later) { defaults.set(data, forKey: "readLater.v1") }
    }

    // MARK: Bookmarks

    private func rebuildBookmarkLookup() {
        bookmarkAddresses = Set(bookmarks.map(\.address))
        bookmarkKeys = Set(bookmarks.compactMap { SourceKey.key(for: $0.address) })
    }

    func isBookmarked(_ address: String) -> Bool {
        if bookmarkAddresses.contains(address) { return true }
        if let key = SourceKey.key(for: address), bookmarkKeys.contains(key) { return true }
        return false
    }

    func isBookmarked(_ url: URL?) -> Bool {
        guard let url else { return false }
        return isBookmarked(url.removingFragment.absoluteString) || isBookmarked(url.absoluteString)
    }

    func isBookmarked(_ tab: BrowserTab) -> Bool {
        isBookmarked(tab.address)
    }

    func bookmark(for address: String) -> Bookmark? {
        if let exact = bookmarks.first(where: { $0.address == address }) { return exact }
        guard let key = SourceKey.key(for: address) else { return nil }
        return bookmarks.first { SourceKey.key(for: $0.address) == key }
    }

    @discardableResult
    func addBookmark(address: String, title: String, note: String? = nil) -> Bookmark {
        let cleanAddress = URL(string: address)?.removingFragment.absoluteString ?? address
        let cleanTitle = title.trimmed.isEmpty ? cleanAddress : title.trimmed
        if let existing = bookmark(for: cleanAddress) { return existing }
        let cleanNote = note?.trimmed.nonEmpty
        let entry = Bookmark(address: cleanAddress, title: cleanTitle, saved: .now, note: cleanNote)
        bookmarks.insert(entry, at: 0)
        saveBookmarks()
        return entry
    }

    @discardableResult
    func removeBookmark(address: String) -> Bookmark? {
        let key = SourceKey.key(for: address)
        guard let index = bookmarks.firstIndex(where: {
            $0.address == address || (key != nil && SourceKey.key(for: $0.address) == key)
        }) else { return nil }
        let removed = bookmarks.remove(at: index)
        saveBookmarks()
        return removed
    }

    func restoreBookmark(_ entry: Bookmark) {
        guard !isBookmarked(entry.address) else { return }
        bookmarks.insert(entry, at: 0)
        bookmarks.sort { $0.saved > $1.saved }
        saveBookmarks()
    }

    @discardableResult
    func toggleBookmark(address: String, title: String) -> (added: Bool, bookmark: Bookmark) {
        if let removed = removeBookmark(address: address) {
            return (false, removed)
        }
        return (true, addBookmark(address: address, title: title))
    }

    func updateBookmark(address: String, title: String, note: String?) {
        guard let index = bookmarks.firstIndex(where: { $0.address == address }) else { return }
        let cleanTitle = title.trimmed
        if !cleanTitle.isEmpty { bookmarks[index].title = cleanTitle }
        bookmarks[index].note = note?.trimmed.nonEmpty
        saveBookmarks()
    }

    private func saveBookmarks() {
        if let data = try? JSONEncoder().encode(bookmarks) { defaults.set(data, forKey: "bookmarks.v1") }
    }

    /// Marks a tab as read: hides it here and, optionally, closes it in the browser.
    func finish(_ tab: BrowserTab, closeInBrowser: Bool) {
        tab.copies.forEach { finished.insert($0.key) }
        finished.insert(tab.copyKey)
        tabs.removeAll { $0.id == tab.id || $0.address == tab.address }
        if isSaved(tab) {
            later.removeAll { $0.address == tab.address }
            saveLater()
        }
        let today = Self.dayStamp()
        finishedToday = (defaults.string(forKey: "finished.day") == today ? finishedToday : 0) + 1
        defaults.set(today, forKey: "finished.day")
        defaults.set(finishedToday, forKey: "finished.count")
        let copies = tab.copies.filter { $0.windowID != SavedSource.windowID && !closed.contains($0.key) }
        guard closeInBrowser, !sample, !copies.isEmpty else { return }
        copies.forEach { closed.insert($0.key) }
        let label = tab.browserLabel
        Task {
            do { try await Browsers.close(copies) }
            catch { self.error = "Couldn’t close the tab in \(label): \(error.localizedDescription)" }
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
    /// Read later is the exception: it saves the page instead of storing a pick, and needs an open tab.
    @discardableResult
    func assign(address: String, to id: String?) -> Bool {
        if let id, category(withID: id)?.acceptsRules == false {
            guard id == Category.laterID, let tab = tabs.first(where: { $0.address == address }) else { return false }
            saveForLater(tab, closeInBrowser: false)
            return true
        }
        assignments[address] = id
        defaults.set(assignments, forKey: "assignments.v2")
        return true
    }

    @discardableResult
    func fileSite(_ site: String, to id: String) -> Bool {
        let site = site.lowercased()
        guard !site.isEmpty, category(withID: id)?.acceptsRules == true else { return false }
        siteRules[site] = id
        defaults.set(siteRules, forKey: "siteRules.v2")
        return true
    }

    /// Return a shelf with this name, creating one if there isn't yet. Used by agents through
    /// the bridge, so a new shelf is marked as theirs and goes after your own.
    /// With `parentID`, only that shelf's direct children count and a new shelf goes inside it.
    @discardableResult
    func ensureCategory(named name: String, symbol: String?, parentID: String? = nil) -> Category {
        let parentID = parentID.flatMap { tree.canHoldChildren($0) ? $0 : nil }
        let candidates = parentID.map { tree.children(of: $0) } ?? tree.flattened().map(\.category)
        if let existing = candidates.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return existing }
        let shelf = Category(id: UUID().uuidString, name: name, symbol: symbol ?? "sparkles", hue: 0,
                             parentID: parentID, madeByAgent: true)
        categories.insert(shelf, at: categories.firstIndex(where: \.isOther) ?? categories.count)
        agentShelvesMade[shelf.id] = .now
        saveCategories()
        return shelf
    }

    /// Turns an agent's shelf into one of yours, so it stays even when empty.
    func keep(_ id: String) {
        update(id) { $0.madeByAgent = nil }
    }

    /// Agent shelves exist for the tabs they hold. Once those are all read (and you
    /// haven't given the shelf rules of its own), the shelf goes. A shelf whose
    /// sub-shelves still hold tabs counts as used.
    private func pruneAgentShelves() {
        let used = totals(grouped()).filter { $0.value > 0 }
        let pinned = Set(siteRules.values)
        // An agent makes a shelf, then files tabs onto it in a later step; don't prune in between.
        let settling = Set(agentShelvesMade.filter { Date.now.timeIntervalSince($0.value) < 600 }.keys)
        let stale = categories.filter { $0.isAgentMade && $0.domains.isEmpty && $0.keywords.isEmpty
            && !pinned.contains($0.id) && !autoSortShelves.contains($0.id)
            && used[$0.id] == nil && !settling.contains($0.id) }
        stale.forEach { delete($0.id) }
    }

    var laterShelf: Category { categories.first { $0.isLater } ?? Category.later }

    private func computeFiling() -> FilingCache {
        if let filingCache { return filingCache }
        var byAddress: [String: Category] = [:]
        byAddress.reserveCapacity(tabs.count)
        var groups: [String: [BrowserTab]] = [:]
        for tab in tabs {
            let category = resolveCategory(for: tab)
            byAddress[tab.address] = category
            groups[category.id, default: []].append(tab)
        }
        let totals = tree.totals(groups.mapValues(\.count))
        let cache = FilingCache(byAddress: byAddress, groups: groups, totals: totals)
        filingCache = cache
        return cache
    }

    private func resolveCategory(for tab: BrowserTab) -> Category {
        if laterAddresses.contains(tab.address) { return laterShelf }
        if let id = assignments[tab.address], let manual = category(withID: id) { return manual }
        if let id = siteRules[tab.site], let site = category(withID: id) { return site }
        let host = tab.host
        let address = tab.address.lowercased()
        let title = tab.title.lowercased()
        func deepest(_ shelf: Category) -> Category? {
            for child in tree.children(of: shelf.id) { if let hit = deepest(child) { return hit } }
            return tree.matches(shelf.id, host: host, address: address, title: title) ? shelf : nil
        }
        for shelf in tree.children(of: nil) where !shelf.isBuiltIn {
            if let hit = deepest(shelf) { return hit }
        }
        return other
    }

    /// Read later wins, then manual picks and site rules. Otherwise top-level shelves are checked
    /// in order, and sub-shelves are checked before their parent so the most specific shelf wins.
    func category(for tab: BrowserTab) -> Category {
        if let hit = filingCache?.byAddress[tab.address] { return hit }
        return resolveCategory(for: tab)
    }

    /// Tabs filed directly on each shelf (not counting sub-shelves).
    func grouped() -> [String: [BrowserTab]] {
        computeFiling().groups
    }

    func totals(_ groups: [String: [BrowserTab]]) -> [String: Int] {
        if let filingCache { return filingCache.totals }
        return tree.totals(groups.mapValues(\.count))
    }

    /// Non-empty shelves under `parent`: "Read later" first, then biggest first, "Unsorted" last.
    func visibleChildren(of parent: String?, totals: [String: Int]) -> [Category] {
        tree.children(of: parent).enumerated()
            .filter { (totals[$0.element.id] ?? 0) > 0 }
            .sorted { lhs, rhs in
                if lhs.element.isOther != rhs.element.isOther { return rhs.element.isOther }
                if lhs.element.isLater != rhs.element.isLater { return lhs.element.isLater }
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
        if id == Category.laterID { return saveForLater(tab, closeInBrowser: false) }
        // A saved page with no open browser tab only exists on Read later, so it stays there.
        guard tab.windowID != SavedSource.windowID else { return }
        if isSaved(tab) {
            later.removeAll { $0.address == tab.address }
            saveLater()
        }
        assignments[tab.address] = id
        defaults.set(assignments, forKey: "assignments.v2")
    }

    /// "Always file this site here" — wins over shelf rules, loses to a manual pick.
    func fileSite(of tab: BrowserTab, in id: String) {
        guard !tab.site.isEmpty, category(withID: id)?.acceptsRules == true else { return }
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
        let parent = parent.flatMap { tree.canHoldChildren($0) ? $0 : nil }
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
        guard let deleted = category(withID: id), !deleted.isBuiltIn else { return }
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
        agentShelvesMade[id] = nil
        setAutoSort(id, false)
        assignments = assignments.filter { $0.value != id }
        siteRules = siteRules.filter { $0.value != id }
        defaults.set(assignments, forKey: "assignments.v2")
        defaults.set(siteRules, forKey: "siteRules.v2")
        saveCategories()
    }

    /// Reorders a shelf among its siblings.
    func move(_ id: String, by offset: Int) {
        guard let shelf = category(withID: id), !shelf.isBuiltIn else { return }
        let siblings = tree.children(of: shelf.parentID).filter { !$0.isBuiltIn }
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

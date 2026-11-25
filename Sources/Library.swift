import AppKit
import Foundation

/// A shelf that tabs are filed into. Shelves are checked in order; a tab lands
/// on the first shelf whose sites or keywords match it, otherwise on "Other".
struct Category: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var symbol: String
    var hue: Double
    var domains: [String] = []
    var keywords: [String] = []
    /// Created by an agent through the bridge, not by you. Such a shelf holds the tabs the
    /// agent filed there and quietly goes away once they're all read, unless you keep it.
    var madeByAgent: Bool?

    var isAgentMade: Bool { madeByAgent == true }

    static let otherID = "other"
    static let laterID = "later"
    var isOther: Bool { id == Self.otherID }
    var isLater: Bool { id == Self.laterID }
    /// Built-in shelves that can be renamed but never deleted.
    var isBuiltIn: Bool { isOther || isLater }

    static let later = Category(id: laterID, name: "Read later", symbol: "bookmark", hue: 0.08)

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
    @Published private(set) var categories: [Category]
    @Published private(set) var assignments: [String: String]
    @Published private(set) var siteRules: [String: String]
    @Published private(set) var finishedToday: Int
    @Published var updating = false
    @Published var error: String?
    @Published var loaded = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var rawCount = 0
    @Published var sample = ProcessInfo.processInfo.arguments.contains("--sample")
    /// Pages saved to Read later, newest first. They outlive their Helium tabs.
    @Published private(set) var later: [SavedSource]
    private var laterAddresses: Set<String> { Set(later.map(\.address)) }
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
        // "Everything else" sat right next to "Everything" in the index; the catch-all is now "Unsorted".
        if let index = loadedCategories.firstIndex(where: \.isOther), loadedCategories[index].name == "Everything else" {
            loadedCategories[index].name = "Unsorted"
        }
        categories = loadedCategories
        later = store.data(forKey: "readLater.v1").flatMap { try? JSONDecoder().decode([SavedSource].self, from: $0) } ?? []

        if let saved = store.dictionary(forKey: "assignments.v2") as? [String: String] {
            assignments = saved
        } else if let legacy = store.dictionary(forKey: "categories") as? [String: String] {
            assignments = legacy.compactMapValues { Category.legacyNames[$0] }
        } else {
            assignments = [:]
        }
        siteRules = store.dictionary(forKey: "siteRules.v2") as? [String: String] ?? [:]

        let today = Self.dayStamp()
        finishedToday = store.string(forKey: "finished.day") == today ? store.integer(forKey: "finished.count") : 0
    }

    // MARK: Tabs

    func refresh() {
        guard refreshTask == nil else { return }
        if sample {
            tabs = withSaved(Self.sampleTabs.filter { !finished.contains($0.id) })
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
                tabs = withSaved(Self.merge(imported.filter { !finished.contains($0.id) }))
                lastUpdated = .now
                pruneAgentShelves()
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

    /// Saved pages whose Helium tab is gone still get a card, after the open tabs.
    private func withSaved(_ open: [BrowserTab]) -> [BrowserTab] {
        let present = Set(open.map(\.address))
        return open + later.filter { !present.contains($0.address) }.map(\.tab)
    }

    func isSaved(_ tab: BrowserTab) -> Bool { laterAddresses.contains(tab.address) }

    /// Puts a page on the Read later shelf and, optionally, closes its Helium tab.
    func saveForLater(_ tab: BrowserTab, closeInHelium: Bool) {
        guard tab.readableURL != nil else { return }
        if !isSaved(tab) {
            later.insert(SavedSource(address: tab.address, title: tab.displayTitle, saved: .now), at: 0)
            saveLater()
        }
        let copies = tab.copies.filter { $0.windowID != SavedSource.windowID && !closed.contains($0.id) }
        guard closeInHelium, !sample, !copies.isEmpty else { return }
        copies.forEach { finished.insert($0.id); closed.insert($0.id) }
        if let index = tabs.firstIndex(where: { $0.address == tab.address }),
           let saved = later.first(where: { $0.address == tab.address }) {
            tabs[index] = saved.tab
        }
        Task {
            do { _ = try await Helium.run(["close"] + copies.flatMap { [$0.windowID, $0.id] }) }
            catch { self.error = "Couldn’t close the tab in Helium: \(error.localizedDescription)" }
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

    /// Marks a tab as read: hides it here and, optionally, closes it in Helium.
    func finish(_ tab: BrowserTab, closeInHelium: Bool) {
        tab.copies.forEach { finished.insert($0.id) }
        tabs.removeAll { $0.id == tab.id || $0.address == tab.address }
        if isSaved(tab) {
            later.removeAll { $0.address == tab.address }
            saveLater()
        }
        let today = Self.dayStamp()
        finishedToday = (defaults.string(forKey: "finished.day") == today ? finishedToday : 0) + 1
        defaults.set(today, forKey: "finished.day")
        defaults.set(finishedToday, forKey: "finished.count")
        let copies = tab.copies.filter { $0.windowID != SavedSource.windowID && !closed.contains($0.id) }
        guard closeInHelium, !sample, !copies.isEmpty else { return }
        copies.forEach { closed.insert($0.id) }
        Task {
            do { _ = try await Helium.run(["close"] + copies.flatMap { [$0.windowID, $0.id] }) }
            catch { self.error = "Couldn’t close the tab in Helium: \(error.localizedDescription)" }
        }
    }

    // MARK: Filing

    var other: Category { categories.last { $0.isOther } ?? Category.defaults.last! }

    func category(withID id: String) -> Category? { categories.first { $0.id == id } }

    /// Resolve a category by id, or failing that by name (case-insensitive) —
    /// so the external bridge can take either from an agent.
    func category(matching token: String) -> Category? {
        category(withID: token) ?? categories.first { $0.name.caseInsensitiveCompare(token) == .orderedSame }
    }

    /// Assign by raw URL, for the bridge (no BrowserTab needed).
    func assign(address: String, to id: String?) {
        if id == Category.laterID, let tab = tabs.first(where: { $0.address == address }) {
            return saveForLater(tab, closeInHelium: false)
        }
        assignments[address] = id
        defaults.set(assignments, forKey: "assignments.v2")
    }

    func fileSite(_ site: String, to id: String) {
        let site = site.lowercased()
        guard !site.isEmpty else { return }
        siteRules[site] = id
        defaults.set(siteRules, forKey: "siteRules.v2")
    }

    /// Return a category with this name, creating one if there isn't yet. Used by agents
    /// through the bridge, so a new shelf is marked as theirs and goes after your own.
    @discardableResult
    func ensureCategory(named name: String, symbol: String?) -> Category {
        if let existing = categories.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return existing }
        let shelf = Category(id: UUID().uuidString, name: name, symbol: symbol ?? "sparkles", hue: 0, madeByAgent: true)
        categories.insert(shelf, at: max(0, categories.count - 1))
        agentShelvesMade[shelf.id] = .now
        saveCategories()
        return shelf
    }

    /// Turns an agent's shelf into one of yours, so it stays even when empty.
    func keep(_ id: String) {
        update(id) { $0.madeByAgent = nil }
    }

    /// Agent shelves exist for the tabs they hold. Once those are all read (and you
    /// haven't given the shelf rules of its own), the shelf goes.
    private func pruneAgentShelves() {
        let used = Set(tabs.map { category(for: $0).id })
        // An agent makes a shelf, then files tabs onto it in a later step; don't prune in between.
        let settling = Set(agentShelvesMade.filter { Date.now.timeIntervalSince($0.value) < 600 }.keys)
        let stale = categories.filter { $0.isAgentMade && $0.domains.isEmpty && $0.keywords.isEmpty
            && !used.contains($0.id) && !settling.contains($0.id) }
        stale.forEach { delete($0.id) }
    }

    var laterShelf: Category { categories.first { $0.isLater } ?? Category.later }

    func category(for tab: BrowserTab) -> Category {
        if laterAddresses.contains(tab.address) { return laterShelf }
        if let id = assignments[tab.address], let manual = category(withID: id) { return manual }
        if let id = siteRules[tab.site], let site = category(withID: id) { return site }
        return categories.first { !$0.isBuiltIn && $0.matches(tab) } ?? other
    }

    func grouped() -> [String: [BrowserTab]] {
        Dictionary(grouping: tabs) { category(for: $0).id }
    }

    func assign(_ tab: BrowserTab, to id: String?) {
        if id == Category.laterID { return saveForLater(tab, closeInHelium: false) }
        // A saved page with no Helium tab only exists on Read later, so it stays there.
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
        guard !tab.site.isEmpty else { return }
        siteRules[tab.site] = id
        assignments[tab.address] = nil
        defaults.set(siteRules, forKey: "siteRules.v2")
        defaults.set(assignments, forKey: "assignments.v2")
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

    @discardableResult
    func addCategory() -> String {
        let shelf = Category(id: UUID().uuidString, name: "New shelf", symbol: "bookmark", hue: 0)
        categories.insert(shelf, at: 0)
        saveCategories()
        return shelf.id
    }

    func delete(_ id: String) {
        guard id != Category.otherID, id != Category.laterID else { return }
        categories.removeAll { $0.id == id }
        assignments = assignments.filter { $0.value != id }
        siteRules = siteRules.filter { $0.value != id }
        defaults.set(assignments, forKey: "assignments.v2")
        defaults.set(siteRules, forKey: "siteRules.v2")
        saveCategories()
    }

    func move(_ id: String, by offset: Int) {
        guard let index = categories.firstIndex(where: { $0.id == id }), !categories[index].isOther else { return }
        let target = index + offset
        guard target >= 0, target < categories.count - 1 else { return }
        categories.swapAt(index, target)
        saveCategories()
    }

    func resetCategories() {
        categories = Category.defaults
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

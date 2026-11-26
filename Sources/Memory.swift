import Foundation

/// Small things Reading Desk remembers between launches: where you were on each
/// page, which PDF page you were on, and what you had open when you quit.
@MainActor
enum ReadingMemory {
    private static let defaults = UserDefaults.standard
    private static let limit = 300

    // MARK: Scroll and page positions

    private static var scrolls: [String: Double]?
    private static var scrollOrder: [String]?
    private static var pages: [String: Int]?
    private static var pageOrder: [String]?
    private static var dirtyScrolls = false
    private static var dirtyPages = false
    private static var flushWork: DispatchWorkItem?

    private static func key(_ url: URL) -> String { url.removingFragment.absoluteString }

    private static func loadScrolls() -> [String: Double] {
        if let scrolls { return scrolls }
        let loaded = defaults.dictionary(forKey: "scroll.v1") as? [String: Double] ?? [:]
        scrolls = loaded
        scrollOrder = defaults.stringArray(forKey: "scroll.order.v1") ?? Array(loaded.keys)
        return loaded
    }

    private static func loadPages() -> [String: Int] {
        if let pages { return pages }
        let loaded = defaults.dictionary(forKey: "pdfPage.v1") as? [String: Int] ?? [:]
        pages = loaded
        pageOrder = defaults.stringArray(forKey: "pdfPage.order.v1") ?? Array(loaded.keys)
        return loaded
    }

    static func scroll(for url: URL) -> Double? {
        loadScrolls()[key(url)]
    }

    static func setScroll(_ y: Double, for url: URL) {
        var all = loadScrolls()
        var order = scrollOrder ?? []
        let k = key(url)
        all[k] = y
        touch(k, in: &order, trimming: &all)
        scrolls = all
        scrollOrder = order
        dirtyScrolls = true
        scheduleFlush()
    }

    static func page(for url: URL) -> Int? {
        loadPages()[key(url)]
    }

    static func setPage(_ index: Int, for url: URL) {
        var all = loadPages()
        var order = pageOrder ?? []
        let k = key(url)
        all[k] = index
        touch(k, in: &order, trimming: &all)
        pages = all
        pageOrder = order
        dirtyPages = true
        scheduleFlush()
    }

    /// Keeps the most recently used entries so the store doesn't grow forever.
    private static func touch<Value>(_ key: String, in order: inout [String], trimming all: inout [String: Value]) {
        order.removeAll { $0 == key }
        order.append(key)
        if order.count > limit {
            for stale in order.prefix(order.count - limit) { all[stale] = nil }
            order.removeFirst(order.count - limit)
        }
    }

    /// Coalesces frequent scroll/page updates so UserDefaults isn't rewritten twice a second while scrolling.
    private static func scheduleFlush() {
        guard flushWork == nil else { return }
        let work = DispatchWorkItem { flush() }
        flushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    static func flush() {
        flushWork?.cancel()
        flushWork = nil
        if dirtyScrolls, let scrolls, let scrollOrder {
            defaults.set(scrolls, forKey: "scroll.v1")
            defaults.set(scrollOrder, forKey: "scroll.order.v1")
            dirtyScrolls = false
        }
        if dirtyPages, let pages, let pageOrder {
            defaults.set(pages, forKey: "pdfPage.v1")
            defaults.set(pageOrder, forKey: "pdfPage.order.v1")
            dirtyPages = false
        }
    }

    // MARK: Session

    /// What was on screen when you were last reading.
    struct Session: Codable, Equatable {
        var categoryID: String
        var address: String
        var title: String
        var notePath: String?
    }

    static var session: Session? {
        get { defaults.data(forKey: "session.v1").flatMap { try? JSONDecoder().decode(Session.self, from: $0) } }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: "session.v1") }
            else { defaults.removeObject(forKey: "session.v1") }
        }
    }

    /// Notes picked for a source, by `SourceKey`.
    static func notePath(for key: String) -> String? {
        (defaults.dictionary(forKey: "sourceNotes.v1") as? [String: String])?[key]
    }

    static func setNotePath(_ path: String?, for key: String) {
        var all = defaults.dictionary(forKey: "sourceNotes.v1") as? [String: String] ?? [:]
        all[key] = path
        defaults.set(all, forKey: "sourceNotes.v1")
    }
}

/// A page saved to the Read later shelf. It stays here after its Helium tab closes.
struct SavedSource: Codable, Hashable {
    var address: String
    var title: String
    var saved: Date

    static let windowID = "later"

    var tab: BrowserTab {
        BrowserTab(id: Self.windowID + ":" + address, windowID: Self.windowID, title: title, address: address)
    }
}

/// A page bookmarked to keep and revisit anytime. Unlike Read later,
/// marking a tab Done never removes a bookmark — it stays until you remove it.
struct Bookmark: Codable, Identifiable, Hashable {
    var address: String
    var title: String
    var saved: Date
    var note: String? = nil

    var id: String { address }
    static let windowID = "bookmark"

    var tab: BrowserTab {
        BrowserTab(id: Self.windowID + ":" + address, windowID: Self.windowID, title: title, address: address)
    }
}

/// Today as `2026-11-24`, in the local time zone (ISO 8601 formatting defaults to UTC).
func localDay(_ date: Date = .now) -> String {
    let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
}

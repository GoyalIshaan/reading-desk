import Foundation

/// Small things Reading Desk remembers between launches: where you were on each
/// page, which PDF page you were on, and what you had open when you quit.
enum ReadingMemory {
    private static let defaults = UserDefaults.standard
    private static let limit = 300

    // MARK: Scroll and page positions

    private static func key(_ url: URL) -> String { url.removingFragment.absoluteString }

    static func scroll(for url: URL) -> Double? {
        (defaults.dictionary(forKey: "scroll.v1") as? [String: Double])?[key(url)]
    }

    static func setScroll(_ y: Double, for url: URL) {
        var all = defaults.dictionary(forKey: "scroll.v1") as? [String: Double] ?? [:]
        all[key(url)] = y
        touch(key(url), in: "scroll.order.v1", trimming: &all)
        defaults.set(all, forKey: "scroll.v1")
    }

    static func page(for url: URL) -> Int? {
        (defaults.dictionary(forKey: "pdfPage.v1") as? [String: Int])?[key(url)]
    }

    static func setPage(_ index: Int, for url: URL) {
        var all = defaults.dictionary(forKey: "pdfPage.v1") as? [String: Int] ?? [:]
        all[key(url)] = index
        touch(key(url), in: "pdfPage.order.v1", trimming: &all)
        defaults.set(all, forKey: "pdfPage.v1")
    }

    /// Keeps the most recently used entries so the store doesn't grow forever.
    private static func touch<Value>(_ key: String, in orderKey: String, trimming all: inout [String: Value]) {
        var order = defaults.stringArray(forKey: orderKey) ?? []
        order.removeAll { $0 == key }
        order.append(key)
        if order.count > limit {
            for stale in order.prefix(order.count - limit) { all[stale] = nil }
            order.removeFirst(order.count - limit)
        }
        defaults.set(order, forKey: orderKey)
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

/// Today as `2026-11-24`, in the local time zone (ISO 8601 formatting defaults to UTC).
func localDay(_ date: Date = .now) -> String {
    let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
}

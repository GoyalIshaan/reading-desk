import Foundation

/// Small things Reading Desk remembers between launches: where you were on each
/// page, which PDF page you were on, and what you had open when you quit.
@MainActor
enum ReadingMemory {
    private static let defaults = UserDefaults.standard
    private static let limit = 300

    // MARK: Scroll and page positions

    /// An LRU map backed by UserDefaults: values, order, and dirty status stay coupled.
    @MainActor
    private struct LRUStore<Value> {
        private enum State {
            case unloaded
            case clean(values: [String: Value], order: [String])
            case dirty(values: [String: Value], order: [String])
        }

        let valuesKey: String
        let orderKey: String
        private var state: State = .unloaded

        init(valuesKey: String, orderKey: String) {
            self.valuesKey = valuesKey
            self.orderKey = orderKey
        }

        mutating func get(_ key: String) -> Value? {
            let (values, _) = ensureLoaded()
            return values[key]
        }

        mutating func set(_ value: Value, for key: String) {
            var (values, order) = ensureLoaded()
            values[key] = value
            order.removeAll { $0 == key }
            order.append(key)
            if order.count > limit {
                for stale in order.prefix(order.count - limit) { values[stale] = nil }
                order.removeFirst(order.count - limit)
            }
            state = .dirty(values: values, order: order)
        }

        mutating func flush(to defaults: UserDefaults) {
            guard case .dirty(let values, let order) = state else { return }
            defaults.set(values, forKey: valuesKey)
            defaults.set(order, forKey: orderKey)
            state = .clean(values: values, order: order)
        }

        private mutating func ensureLoaded() -> ([String: Value], [String]) {
            switch state {
            case .clean(let values, let order), .dirty(let values, let order):
                return (values, order)
            case .unloaded:
                let values = defaults.dictionary(forKey: valuesKey) as? [String: Value] ?? [:]
                let order = defaults.stringArray(forKey: orderKey) ?? Array(values.keys)
                state = .clean(values: values, order: order)
                return (values, order)
            }
        }
    }

    private static var scrolls = LRUStore<Double>(valuesKey: "scroll.v1", orderKey: "scroll.order.v1")
    private static var pages = LRUStore<Int>(valuesKey: "pdfPage.v1", orderKey: "pdfPage.order.v1")
    private static var flushWork: DispatchWorkItem?

    private static func key(_ url: URL) -> String { url.removingFragment.absoluteString }

    static func scroll(for url: URL) -> Double? {
        scrolls.get(key(url))
    }

    static func setScroll(_ y: Double, for url: URL) {
        scrolls.set(y, for: key(url))
        scheduleFlush()
    }

    static func page(for url: URL) -> Int? {
        pages.get(key(url))
    }

    static func setPage(_ index: Int, for url: URL) {
        pages.set(index, for: key(url))
        scheduleFlush()
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
        scrolls.flush(to: defaults)
        pages.flush(to: defaults)
    }

    // MARK: Session

    /// What was on screen when you were last reading.
    struct Session: Codable, Equatable {
        enum Source: Equatable {
            case bookmarks
            case shelf(String)
        }

        var source: Source
        var address: String
        var title: String
        var notePath: String?

        private static let bookmarksToken = "__bookmarks__"

        private enum CodingKeys: String, CodingKey { case categoryID, address, title, notePath }

        init(source: Source, address: String, title: String, notePath: String?) {
            self.source = source
            self.address = address
            self.title = title
            self.notePath = notePath
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let raw = try container.decode(String.self, forKey: .categoryID)
            source = raw == Self.bookmarksToken ? .bookmarks : .shelf(raw)
            address = try container.decode(String.self, forKey: .address)
            title = try container.decode(String.self, forKey: .title)
            notePath = try container.decodeIfPresent(String.self, forKey: .notePath)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch source {
            case .bookmarks: try container.encode(Self.bookmarksToken, forKey: .categoryID)
            case .shelf(let id): try container.encode(id, forKey: .categoryID)
            }
            try container.encode(address, forKey: .address)
            try container.encode(title, forKey: .title)
            try container.encodeIfPresent(notePath, forKey: .notePath)
        }
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

/// A page saved to the Read later shelf. It stays here after its browser tab closes.
struct SavedSource: Codable, Hashable {
    var address: String
    var title: String
    var saved: Date

    var tab: BrowserTab {
        BrowserTab(origin: .readLater, title: title, address: address)
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

    var tab: BrowserTab {
        BrowserTab(origin: .bookmark, title: title, address: address)
    }
}

/// Today as `2026-11-24`, in the local time zone (ISO 8601 formatting defaults to UTC).
func localDay(_ date: Date = .now) -> String {
    let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
}

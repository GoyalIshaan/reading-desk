import Foundation

/// Which notes in the vault talk about which sources.
///
/// Every note is scanned for links. A note whose `source:` property (or
/// `Source:` line) points at a page is *the* note for that page, the one
/// highlights go into. Any other note that links to the page is listed as an
/// earlier note about it. Files are only re-read when they change.
@MainActor
final class NoteIndex: ObservableObject {
    struct Ref: Hashable {
        let path: String
        let isSource: Bool
    }

    @Published private(set) var byKey: [String: [Ref]] = [:]
    private let scanner = NoteScanner()

    func rebuild(_ notes: [Note]) async {
        let result = await scanner.scan(notes)
        if result != byKey { byKey = result }
    }

    func refs(for address: String) -> [Ref] {
        guard let key = SourceKey.key(for: address) else { return [] }
        return byKey[key] ?? []
    }

    func count(for address: String) -> Int { refs(for: address).count }

    /// Records a note right away (after a highlight creates it) without waiting for a rescan.
    func add(_ path: String, isSource: Bool, for address: String) {
        guard let key = SourceKey.key(for: address) else { return }
        var refs = byKey[key] ?? []
        guard !refs.contains(where: { $0.path == path }) else { return }
        refs.insert(Ref(path: path, isSource: isSource), at: 0)
        byKey[key] = refs
    }
}

private actor NoteScanner {
    private struct Cached { let modified: Date; let links: [(key: String, isSource: Bool)] }
    private var cache: [String: Cached] = [:]

    private static let link = try! NSRegularExpression(pattern: #"https?://[^\s<>()\[\]"'`]+"#)
    private static let sourceLine = try! NSRegularExpression(
        pattern: #"^(?:source|url|link)\s*:\s*<?(\S+?)>?\s*$"#, options: [.anchorsMatchLines, .caseInsensitive])

    func scan(_ notes: [Note]) -> [String: [NoteIndex.Ref]] {
        var live: Set<String> = []
        var result: [String: [NoteIndex.Ref]] = [:]
        for note in notes {
            live.insert(note.path)
            let links: [(key: String, isSource: Bool)]
            if let cached = cache[note.path], cached.modified == note.modified {
                links = cached.links
            } else {
                links = Self.links(in: note.url)
                cache[note.path] = Cached(modified: note.modified, links: links)
            }
            for link in links {
                var refs = result[link.key] ?? []
                if let index = refs.firstIndex(where: { $0.path == note.path }) {
                    if link.isSource && !refs[index].isSource { refs[index] = NoteIndex.Ref(path: note.path, isSource: true) }
                } else {
                    refs.append(NoteIndex.Ref(path: note.path, isSource: link.isSource))
                }
                result[link.key] = refs
            }
        }
        cache = cache.filter { live.contains($0.key) }
        // Notes arrive newest first; keep that order, but put source notes on top.
        return result.mapValues { refs in refs.filter(\.isSource) + refs.filter { !$0.isSource } }
    }

    private static func links(in url: URL) -> [(key: String, isSource: Bool)] {
        // Never memory-map: vaults often live in iCloud Drive, and a mapped file that iCloud
        // evicts takes the app down (SIGBUS). Notes iCloud hasn't downloaded are skipped, not fetched.
        let keys: Set<URLResourceKey> = [.fileSizeKey, .ubiquitousItemDownloadingStatusKey]
        if let values = try? url.resourceValues(forKeys: keys) {
            if values.ubiquitousItemDownloadingStatus == .notDownloaded { return [] }
            if let size = values.fileSize, size > 4_000_000 { return [] }
        }
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return [] }
        let whole = NSRange(text.startIndex..., in: text)
        var found: [(String, Bool)] = []
        var seen: Set<String> = []
        // Only the top of a note counts for "source": the properties block or the first few lines.
        let head = String(text.prefix(1500))
        let headRange = NSRange(head.startIndex..., in: head)
        for match in sourceLine.matches(in: head, range: headRange) {
            guard let range = Range(match.range(at: 1), in: head), let key = SourceKey.key(for: String(head[range])) else { continue }
            if seen.insert(key).inserted { found.append((key, true)) }
        }
        for match in link.matches(in: text, range: whole) {
            guard let range = Range(match.range, in: text) else { continue }
            var address = String(text[range])
            while let last = address.last, ".,;:!?*_>".contains(last) { address.removeLast() }
            guard let key = SourceKey.key(for: address) else { continue }
            if seen.insert(key).inserted { found.append((key, false)) }
        }
        return found
    }
}

import Foundation

/// An in-memory index over the open tabs, built for the ⇧⌘P palette.
///
/// Every tab is split into weighted fields (title, site, shelf, address, description).
/// Their words go into one vocabulary with postings back to the tabs. A query word
/// is matched against the vocabulary, not against each tab, so a lookup costs
/// O(vocabulary) rather than O(tabs × text). Words match exactly, by prefix, inside a
/// longer word, or approximately by shared trigrams (so typos still find things).
/// A tab doesn't need every query word to appear: it is ranked by how much of the
/// query it covers, weighted by how rare each matched word is (IDF).
struct SearchIndex {
    enum Field: Int, CaseIterable {
        case title, site, shelf, address, summary, body

        var weight: Double {
            switch self {
            case .title: 3.0
            case .site: 2.4
            case .shelf: 1.4
            case .address: 1.0
            case .summary: 0.8
            case .body: 0.5
            }
        }
    }

    struct Hit {
        let index: Int
        let score: Double
        /// Vocabulary words that matched, used to highlight the title and snippet.
        let words: Set<String>
        /// Where the best non-title match was, for the secondary line.
        let snippet: String?
    }

    private struct Posting { let doc: Int; let field: Field }

    private struct Entry {
        let word: String
        let length: Int
        /// Sorted, unique trigrams packed as 3 × 21-bit Unicode scalars (zero String allocations).
        let trigrams: [UInt64]
        var postings: [Posting] = []
        var idf: Double = 0
    }

    private var vocabulary: [Entry] = []
    private var summaries: [String] = []
    private var bodies: [String] = []
    private var titles: [String] = []
    private var documentCount = 0

    init(documents: [[Field: String]]) {
        documentCount = documents.count
        var lookup: [String: Int] = [:]
        summaries = documents.map { $0[.summary] ?? "" }
        bodies = documents.map { $0[.body] ?? "" }
        titles = documents.map { Self.fold($0[.title] ?? "") }
        for (doc, fields) in documents.enumerated() {
            for (field, text) in fields {
                for word in Set(Self.words(in: text)) {
                    if let slot = lookup[word] {
                        vocabulary[slot].postings.append(Posting(doc: doc, field: field))
                    } else {
                        lookup[word] = vocabulary.count
                        vocabulary.append(Entry(word: word, length: word.count, trigrams: Self.trigrams(word),
                                                postings: [Posting(doc: doc, field: field)]))
                    }
                }
            }
        }
        let total = Double(documentCount)
        for index in vocabulary.indices {
            var docs = Set<Int>()
            for posting in vocabulary[index].postings { docs.insert(posting.doc) }
            let count = Double(docs.count)
            vocabulary[index].idf = log(1 + (total - count + 0.5) / (count + 0.5))
        }
    }

    /// Lowercased, accent-folded words. Hosts like `x.com` also stay whole so they match as typed.
    static func words(in text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var result: [String] = []
        var current = ""
        var dotted = ""
        func flush() {
            if !current.isEmpty { result.append(current); current = "" }
        }
        for character in folded {
            if character.isLetter || character.isNumber {
                current.append(character)
                dotted.append(character)
            } else {
                flush()
                if character == "." || character == "-" { dotted.append(character) } else {
                    if dotted.contains(".") || dotted.contains("-") { result.append(dotted.trimmingCharacters(in: CharacterSet(charactersIn: ".-"))) }
                    dotted = ""
                }
            }
        }
        flush()
        if dotted.contains(".") || dotted.contains("-") { result.append(dotted.trimmingCharacters(in: CharacterSet(charactersIn: ".-"))) }
        return result
    }

    /// Query words. A typed host such as `x.com` stays one term instead of also
    /// searching for "x" and "com", which would match nearly every tab.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    static func queryTerms(_ query: String) -> [String] {
        let all = words(in: query).filter { !$0.isEmpty }
        let joined = all.filter { $0.contains(".") || $0.contains("-") }
        let parts = Set(joined.flatMap { $0.split(whereSeparator: { $0 == "." || $0 == "-" }).map(String.init) })
        var seen = Set<String>()
        return all.filter { (joined.contains($0) || !parts.contains($0)) && seen.insert($0).inserted }
    }

    static func trigrams(_ word: String) -> [UInt64] {
        var scalars: [UInt64] = [32, 32]
        scalars.reserveCapacity(word.unicodeScalars.count + 3)
        for s in word.unicodeScalars { scalars.append(UInt64(s.value & 0x1FFFFF)) }
        scalars.append(32)
        guard scalars.count >= 3 else { return [] }
        var grams: [UInt64] = []
        grams.reserveCapacity(scalars.count - 2)
        for start in 0...(scalars.count - 3) {
            grams.append((scalars[start] << 42) | (scalars[start + 1] << 21) | scalars[start + 2])
        }
        grams.sort()
        var unique: [UInt64] = []
        unique.reserveCapacity(grams.count)
        for gram in grams where unique.last != gram { unique.append(gram) }
        return unique
    }

    private static func sharedCount(_ a: [UInt64], _ b: [UInt64]) -> Int {
        var i = 0, j = 0, count = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] { count += 1; i += 1; j += 1 }
            else if a[i] < b[j] { i += 1 }
            else { j += 1 }
        }
        return count
    }

    /// How well a query word matches a vocabulary word, 0…1.
    private static func quality(_ term: String, _ termLength: Int, _ termGrams: [UInt64], _ entry: Entry) -> Double {
        let word = entry.word
        if word == term { return 1 }
        if word.hasPrefix(term) { return termLength >= 2 ? 0.85 : 0.55 }
        if termLength >= 3 && word.contains(term) { return 0.55 }
        guard termLength >= 4, abs(entry.length - termLength) <= 3 else { return 0 }
        let shared = Double(sharedCount(termGrams, entry.trigrams))
        let dice = 2 * shared / Double(termGrams.count + entry.trigrams.count)
        return dice >= 0.6 ? dice * 0.7 : 0
    }

    func search(_ query: String, limit: Int = 60) -> [Hit] {
        let terms = Self.queryTerms(query)
        guard !terms.isEmpty, documentCount > 0 else { return [] }

        var scores = [Double](repeating: 0, count: documentCount)
        var covered = [Int](repeating: 0, count: documentCount)
        var matched = [Set<String>](repeating: [], count: documentCount)
        var snippetWord = [String?](repeating: nil, count: documentCount)
        var bodyWord = [String?](repeating: nil, count: documentCount)

        for term in terms {
            let termLength = term.count
            let grams = termLength >= 4 ? Self.trigrams(term) : []
            // Best contribution of this term per document, across all words and fields.
            var best = [Double](repeating: 0, count: documentCount)
            for entry in vocabulary {
                let q = Self.quality(term, termLength, grams, entry)
                guard q > 0 else { continue }
                let idfWeight = q * (0.6 + entry.idf)
                for posting in entry.postings {
                    let value = idfWeight * posting.field.weight
                    if value > best[posting.doc] { best[posting.doc] = value }
                    matched[posting.doc].insert(entry.word)
                    if posting.field == .summary && snippetWord[posting.doc] == nil { snippetWord[posting.doc] = entry.word }
                    if posting.field == .body && bodyWord[posting.doc] == nil { bodyWord[posting.doc] = entry.word }
                }
            }
            for doc in 0..<documentCount where best[doc] > 0 {
                scores[doc] += best[doc]
                covered[doc] += 1
            }
        }

        let phrase = Self.fold(query).trimmingCharacters(in: .whitespaces)
        let needed = max(1, Int((Double(terms.count) * 0.5).rounded(.up)))
        var hits: [Hit] = []
        for doc in 0..<documentCount where covered[doc] >= needed {
            let coverage = Double(covered[doc]) / Double(terms.count)
            let snippet = snippetWord[doc].flatMap { Self.snippet(summaries[doc], around: $0) }
                ?? bodyWord[doc].flatMap { Self.snippet(bodies[doc], around: $0) }
            var score = scores[doc] * (0.4 + 0.6 * coverage * coverage)
            // The whole query, as typed, at the start of or inside the title.
            if phrase.count >= 2 {
                if titles[doc].hasPrefix(phrase) { score *= 1.5 } else if titles[doc].contains(phrase) { score *= 1.25 }
            }
            hits.append(Hit(index: doc, score: score, words: matched[doc], snippet: snippet))
        }
        hits.sort { $0.score != $1.score ? $0.score > $1.score : titles[$0.index].count < titles[$1.index].count }
        return Array(hits.prefix(limit))
    }

    /// About 90 characters of the description around the first matched word.
    static func snippet(_ text: String, around word: String) -> String? {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        guard folded.count == text.count, let range = folded.range(of: word) else { return nil }
        let offset = folded.distance(from: folded.startIndex, to: range.lowerBound)
        let start = max(0, offset - 30)
        let characters = Array(text)
        let end = min(characters.count, start + 90)
        var piece = String(characters[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        if start > 0 { piece = "…" + piece }
        if end < characters.count { piece += "…" }
        return piece
    }
}

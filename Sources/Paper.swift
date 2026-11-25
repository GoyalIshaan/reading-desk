import PDFKit
import SwiftUI
import WebKit

/// PDFs open here instead of WebKit's viewer, which hides the selection and page
/// from the app. PDFKit gives us the outline (for jumping between sections),
/// the page you're on, and exactly which page a highlighted passage came from.
@MainActor
final class PaperReader: NSObject, ObservableObject {
    struct Section: Identifiable, Hashable {
        let id: Int
        let title: String
        let level: Int
        let pageIndex: Int
        /// How far up the page the heading sits (PDF points, origin at the bottom), when the outline says.
        var top: CGFloat?
    }

    let url: URL
    /// Optional 0-based page parsed from a `#page=N` fragment on the opening URL.
    private let requestedPage: Int?
    let view = DeskPDFView()
    @Published private(set) var loading = true
    @Published private(set) var failure: String?
    @Published private(set) var pageIndex = 0
    @Published private(set) var pageCount = 0
    @Published private(set) var sections: [Section] = []
    @Published private(set) var title: String?

    /// A finished selection (mouse up), or nil when it's cleared.
    var onSelection: ((Excerpt.Partial?) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var destinations: [Int: PDFDestination] = [:]

    init(url: URL) {
        self.requestedPage = Self.fragmentPage(in: url)
        self.url = url.removingFragment
        super.init()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = NSColor(Theme.ground)
        view.pageShadowsEnabled = false
        view.onMouseUp = { [weak self] in self?.reportSelection() }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pageChanged() }
        })
        observers.append(center.addObserver(forName: .PDFViewSelectionChanged, object: view, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.view.currentSelection?.string?.trimmed.isEmpty ?? true { self.onSelection?(nil) }
            }
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    private struct UncheckedBox<T>: @unchecked Sendable { let value: T }

    private static func fragmentPage(in url: URL) -> Int? {
        guard let fragment = url.fragment else { return nil }
        for part in fragment.split(separator: "&") {
            let pair = part.split(separator: "=", maxSplits: 1)
            if pair.count == 2, pair[0].lowercased() == "page", let n = Int(pair[1]), n >= 1 {
                return n - 1
            }
        }
        return nil
    }

    func load() async {
        loading = true
        failure = nil
        defer { loading = false }
        do {
            let document: PDFDocument?
            let targetURL = url
            if targetURL.isFileURL {
                document = await Task.detached(priority: .userInitiated) { UncheckedBox(value: PDFDocument(url: targetURL)) }.value.value
            } else {
                var request = URLRequest(url: targetURL, timeoutInterval: 30)
                request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                                 forHTTPHeaderField: "User-Agent")
                // Reuse the reading pane's sign-ins, so PDFs behind a login still open.
                let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
                    .filter { cookie in
                        guard let host = targetURL.host?.lowercased() else { return false }
                        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                        return host == domain || host.hasSuffix("." + domain)
                    }
                HTTPCookie.requestHeaderFields(with: cookies).forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
                let (data, _) = try await URLSession.shared.data(for: request)
                try Task.checkCancellation()
                guard data.starts(with: Array("%PDF".utf8)) || data.prefix(1024).range(of: Data("%PDF".utf8)) != nil else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                // Parse PDFDocument off the main thread so heavy papers don't hitch tab switching.
                document = await Task.detached(priority: .userInitiated) { UncheckedBox(value: PDFDocument(data: data)) }.value.value
            }
            try Task.checkCancellation()
            guard let document, document.pageCount > 0 else { throw CocoaError(.fileReadCorruptFile) }
            view.document = document
            pageCount = document.pageCount
            title = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?.trimmed
            sections = flatten(document)
            let startPage = requestedPage ?? ReadingMemory.page(for: url)
            if let startPage, startPage > 0, let page = document.page(at: min(startPage, document.pageCount - 1)) {
                // Wait a turn so the view has laid out before jumping.
                DispatchQueue.main.async { [weak self] in self?.view.go(to: page) }
            }
            pageChanged()
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            failure = error.localizedDescription
        }
    }

    private func flatten(_ document: PDFDocument) -> [Section] {
        guard let root = document.outlineRoot else { return [] }
        var result: [Section] = []
        func walk(_ item: PDFOutline, level: Int) {
            for index in 0..<item.numberOfChildren {
                guard let child = item.child(at: index) else { continue }
                if let label = child.label?.trimmed, !label.isEmpty,
                   let destination = child.destination, let page = destination.page {
                    let id = result.count
                    destinations[id] = destination
                    let y = destination.point.y
                    let top: CGFloat? = y.isFinite && y != kPDFDestinationUnspecifiedValue && y > 0 ? y : nil
                    result.append(Section(id: id, title: label, level: level, pageIndex: document.index(for: page), top: top))
                }
                if level < 3 { walk(child, level: level + 1) }
            }
        }
        walk(root, level: 1)
        return result
    }

    func go(to section: Section) {
        if let destination = destinations[section.id] { view.go(to: destination) }
        else if let page = view.document?.page(at: section.pageIndex) { view.go(to: page) }
    }

    func goToPage(_ index: Int) {
        guard let page = view.document?.page(at: index) else { return }
        view.go(to: page)
    }

    /// The section a spot sits in: the last outline entry that starts above it.
    /// `y` is in page space (origin at the bottom); without it, the page as a whole.
    func section(forPage index: Int, y: CGFloat? = nil) -> Section? {
        sections.last { section in
            if section.pageIndex < index { return true }
            guard section.pageIndex == index else { return false }
            guard let y, let top = section.top else { return y == nil }
            return top >= y - 4
        } ?? sections.last { $0.pageIndex < index }
    }

    private func pageChanged() {
        guard let document = view.document, let page = view.currentPage else { return }
        let index = document.index(for: page)
        if index != pageIndex { pageIndex = index }
        ReadingMemory.setPage(index, for: url)
        if view.currentSelection != nil { refreshSelectionRect() }
    }

    private func reportSelection() {
        guard let selection = view.currentSelection, let raw = selection.string,
              !raw.trimmed.isEmpty, let page = selection.pages.first, let document = view.document else {
            onSelection?(nil)
            return
        }
        let index = document.index(for: page)
        let top = selection.bounds(for: page).maxY
        onSelection?(Excerpt.Partial(text: Excerpt.tidy(raw, fromPDF: true), plain: raw, kind: .prose,
                                     section: section(forPage: index, y: top)?.title, page: index + 1,
                                     pageLabel: page.label, rect: rect(of: selection)))
    }

    func refreshSelectionRect() {
        guard let selection = view.currentSelection, !(selection.string?.trimmed.isEmpty ?? true) else { return }
        view.onSelectionMoved?(rect(of: selection))
    }

    private func rect(of selection: PDFSelection) -> CGRect? {
        guard let page = selection.pages.first else { return nil }
        let bounds = view.convert(selection.bounds(for: page), from: page)
        let top = view.isFlipped ? bounds.minY : view.bounds.height - bounds.maxY
        return CGRect(x: bounds.minX, y: top, width: bounds.width, height: bounds.height)
    }
}

final class DeskPDFView: PDFView {
    var onMouseUp: (() -> Void)?
    var extraMenuItems: (() -> [NSMenuItem])?

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        menu.insertExtras(extraMenuItems?() ?? [])
        return menu
    }
    var onSelectionMoved: ((CGRect?) -> Void)?
    private var scrollObserver: NSObjectProtocol?

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        onMouseUp?()
    }

    override func keyUp(with event: NSEvent) {
        super.keyUp(with: event)
        if event.modifierFlags.contains(.shift) { onMouseUp?() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard scrollObserver == nil, let clip = documentView?.enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let selection = self.currentSelection, let page = selection.pages.first,
                      !(selection.string?.trimmed.isEmpty ?? true) else { return }
                let bounds = self.convert(selection.bounds(for: page), from: page)
                let top = self.isFlipped ? bounds.minY : self.bounds.height - bounds.maxY
                self.onSelectionMoved?(CGRect(x: bounds.minX, y: top, width: bounds.width, height: bounds.height))
            }
        }
    }

    deinit {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
    }
}

struct PaperSurface: NSViewRepresentable {
    let paper: PaperReader
    func makeNSView(context: Context) -> DeskPDFView { paper.view }
    func updateNSView(_ nsView: DeskPDFView, context: Context) {}
}

struct PaperPane: View {
    @ObservedObject var paper: PaperReader

    var body: some View {
        ZStack {
            Theme.ground
            PaperSurface(paper: paper)
            if paper.loading {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Opening the PDF…").font(Theme.serif(18, italic: true)).foregroundStyle(Theme.ink3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.ground)
            }
        }
    }
}

extension Excerpt {
    /// What a reader knows about a selection, before the room adds the source.
    struct Partial {
        var text: String
        var plain: String
        var kind: Kind
        var section: String?
        var page: Int?
        var pageLabel: String?
        var rect: CGRect?

        func excerpt(title: String, url: URL) -> Excerpt {
            Excerpt(text: text, plain: plain, kind: kind, section: section, page: page, pageLabel: pageLabel,
                    sourceTitle: title, sourceURL: url.removingFragment, rect: rect)
        }
    }
}

/// Finds a BibTeX entry for a paper: arXiv, DOI and OpenReview have one for the
/// asking. Anything else gets a tidy @misc entry built from the title and link.
enum BibTeX {
    /// The entry, and whether it came from the publisher (false: built here as @misc).
    static func entry(for url: URL, title: String) async -> (text: String, published: Bool) {
        if let id = SourceKey.arxivID(url), let entry = await fetch("https://arxiv.org/bibtex/" + id) { return (entry, true) }
        if let doi = SourceKey.doi(in: url),
           let entry = await fetch("https://doi.org/" + doi, accept: "application/x-bibtex; charset=utf-8") { return (entry, true) }
        if url.host?.lowercased().hasSuffix("openreview.net") == true,
           let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value,
           let entry = await openReview(id) { return (entry, true) }
        return (misc(url: url, title: title), false)
    }

    /// Pages that are papers, where BibTeX and the paper tools make sense.
    static func isPaper(_ url: URL?) -> Bool {
        guard let url else { return false }
        if url.looksLikePDF || SourceKey.arxivID(url) != nil || SourceKey.doi(in: url) != nil { return true }
        let host = url.host?.lowercased() ?? ""
        return ["openreview.net", "semanticscholar.org", "aclanthology.org", "proceedings.mlr.press", "papers.nips.cc",
                "proceedings.neurips.cc", "dl.acm.org", "ieeexplore.ieee.org", "biorxiv.org", "medrxiv.org"]
            .contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private static func fetch(_ address: String, accept: String? = nil) async -> String? {
        guard let url = URL(string: address) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 12)
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8)?.trimmed, text.hasPrefix("@") else { return nil }
        return text
    }

    private static func openReview(_ id: String) async -> String? {
        for base in ["https://api2.openreview.net/notes?id=", "https://api.openreview.net/notes?id="] {
            guard let url = URL(string: base + (id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? id)),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let note = (json["notes"] as? [[String: Any]])?.first,
                  let content = note["content"] as? [String: Any] else { continue }
            let bib = (content["_bibtex"] as? [String: Any])?["value"] as? String ?? content["_bibtex"] as? String
            if let bib = bib?.trimmed, bib.hasPrefix("@") { return bib }
        }
        return nil
    }

    static func misc(url: URL, title: String) -> String {
        let words = title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let stop: Set<Substring> = ["a", "an", "the", "of", "on", "in", "for", "and", "to", "with"]
        let word = words.first { !stop.contains($0) }.map(String.init) ?? "source"
        let year = Calendar.current.component(.year, from: .now)
        let site = url.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? "web"
        let key = (site.split(separator: ".").first.map(String.init) ?? "web") + "\(year)" + word
        let day = localDay()
        let safeTitle = title.replacingOccurrences(of: "{", with: "\\{").replacingOccurrences(of: "}", with: "\\}")
        return """
        @misc{\(key),
          title        = {\(safeTitle)},
          howpublished = {\\url{\(url.absoluteString)}},
          note         = {Accessed \(day)}
        }
        """
    }
}

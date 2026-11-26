import AppKit
import CryptoKit
import ImageIO
import PDFKit
import WebKit

/// What a tab's card shows. Built from the page's own meta tags.
struct PagePreview: Codable, Equatable {
    var title: String?
    var summary: String?
    var siteName: String?
    var imageURL: String?
    var iconURL: String?
    var minutes: Int?
    /// About 300 words of the page's main text, for search. Nil in caches written
    /// before it existed; empty when the page couldn't be read.
    var text: String?
    var isPDF = false
    var hasImage = false
    var aspect: Double?
}

/// Fetches page metadata, a cover image (og:image, or a snapshot of the page
/// when there isn't a good one) and a favicon for every tab. Everything is
/// cached on disk so the library opens instantly the second time.
@MainActor
final class Previews: ObservableObject {
    @Published private(set) var info: [String: PagePreview] = [:]
    @Published private(set) var images: [String: NSImage] = [:]
    @Published private(set) var icons: [String: NSImage] = [:]
    /// Images and descriptions shared by multiple tabs are site boilerplate, not about the page.
    /// Maintained incrementally on flush so LibraryView doesn't scan every preview on each render.
    private(set) var sharedImages: Set<String> = []
    private(set) var sharedSummaries: Set<String> = []

    /// While reading, background fetching and snapshotting stop so the reader stays smooth.
    var paused = false
    private enum FlushSchedule {
        case idle
        case scheduled(fast: Bool, task: Task<Void, Never>)
    }

    private var pendingInfo: [String: PagePreview] = [:]
    private var pendingImages: [String: NSImage] = [:]
    private var pendingIcons: [String: NSImage] = [:]
    private var flushSchedule: FlushSchedule = .idle
    private var requested: Set<String> = []
    private var iconRequested: Set<String> = []
    private let directory: URL
    private let session: URLSession
    private let fetchSlots = Limiter(5)
    private let snapshotSlots = Limiter(2)

    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    /// Sites that only show a sign-in page to a fresh browser. They get a typographic cover instead.
    nonisolated private static let signedIn = ["mail.google.com", "calendar.google.com", "docs.google.com", "drive.google.com",
                                   "chatgpt.com", "claude.ai", "gemini.google.com", "notion.so", "slack.com",
                                   "discord.com", "linear.app", "outlook.office.com", "outlook.live.com",
                                   "web.whatsapp.com", "x.com", "twitter.com", "instagram.com", "facebook.com",
                                   "canvas.illinois.edu", "instructure.com", "gradescope.com", "prairielearn.com"]

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("dev.readingdesk.mac/previews-v2", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.httpAdditionalHeaders = ["User-Agent": Self.userAgent, "Accept-Language": "en-US,en;q=0.9"]
        session = URLSession(configuration: configuration)
    }

    func request(_ tab: BrowserTab) {
        guard let url = tab.readableURL, !url.isFileURL, !requested.contains(tab.address) else { return }
        requested.insert(tab.address)
        let address = tab.address
        let host = tab.host
        let key = Self.hash(address)
        let dir = directory
        // Read disk cache and decode JPEG off the main thread so scrolling never hitches.
        Task {
            let hit = await Task.detached(priority: .userInitiated) { () -> (PagePreview, NSImage?)? in
                let json = dir.appendingPathComponent(key + ".json")
                guard let data = try? Data(contentsOf: json),
                      let cached = try? JSONDecoder().decode(PagePreview.self, from: data) else { return nil }
                let image: NSImage? = cached.hasImage ? Self.decodeImage(at: dir.appendingPathComponent(key + ".jpg")) : nil
                return (cached, image)
            }.value
            if let (cached, image) = hit {
                publish(address, info: cached, image: image, fast: true)
                requestIcon(host: host, hint: cached.iconURL.flatMap(URL.init(string:)))
                if cached.text == nil && !cached.isPDF {
                    await backfillText(address: address, url: url, key: key, cached: cached)
                }
            } else {
                await build(address: address, url: url, key: key)
            }
        }
    }

    private func waitWhilePaused() async {
        while paused { try? await Task.sleep(for: .milliseconds(400)) }
    }

    /// Cards update in batches rather than once per image, so the grid doesn't
    /// re-render 145 times while previews stream in. Cache hits use a short batch
    /// window so the library fills in almost instantly without per-card storms.
    private func publish(_ address: String, info preview: PagePreview, image: NSImage?, fast: Bool = false) {
        pendingInfo[address] = preview
        if let image { pendingImages[address] = image }
        scheduleFlush(fast: fast)
    }

    private func publishIcon(_ host: String, image: NSImage, fast: Bool = false) {
        pendingIcons[host] = image
        scheduleFlush(fast: fast)
    }

    private func scheduleFlush(fast: Bool) {
        switch flushSchedule {
        case .scheduled(let currentlyFast, let existing):
            guard fast && !currentlyFast else { return }
            existing.cancel()
        case .idle:
            break
        }
        let delay: Duration = fast ? .milliseconds(35) : .milliseconds(300)
        let task = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            flushPending()
        }
        flushSchedule = .scheduled(fast: fast, task: task)
    }

    private func flushPending() {
        flushSchedule = .idle
        let infoChanged = !pendingInfo.isEmpty
        if infoChanged {
            info.merge(pendingInfo) { $1 }
            pendingInfo = [:]
            recomputeBoilerplate()
        }
        if !pendingImages.isEmpty {
            images.merge(pendingImages) { $1 }
            pendingImages = [:]
        }
        if !pendingIcons.isEmpty {
            icons.merge(pendingIcons) { $1 }
            pendingIcons = [:]
        }
    }

    private func recomputeBoilerplate() {
        var imageCounts: [String: Int] = [:]
        var summaryCounts: [String: Int] = [:]
        imageCounts.reserveCapacity(info.count)
        summaryCounts.reserveCapacity(info.count)
        for preview in info.values {
            if let image = preview.imageURL { imageCounts[image, default: 0] += 1 }
            if let summary = preview.summary { summaryCounts[summary, default: 0] += 1 }
        }
        sharedImages = Set(imageCounts.lazy.filter { $0.value > 1 }.map(\.key))
        sharedSummaries = Set(summaryCounts.lazy.filter { $0.value > 1 }.map(\.key))
    }

    /// Caches from before page text was kept: fetch just the HTML again for its text.
    private func backfillText(address: String, url: URL, key: String, cached: PagePreview) async {
        await waitWhilePaused()
        await fetchSlots.acquire()
        var preview = cached
        preview.text = ""
        if let (data, response) = try? await session.data(from: url),
           (response.mimeType?.lowercased() ?? "html").contains("html") {
            let html = String(decoding: data.prefix(2_500_000), as: UTF8.self)
            preview.text = await Task.detached(priority: .utility) { Self.parse(html, base: response.url ?? url).text }.value ?? ""
        }
        await fetchSlots.release()
        publish(address, info: preview, image: nil)
        let dir = directory
        let toSave = preview
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(toSave) {
                try? data.write(to: dir.appendingPathComponent(key + ".json"))
            }
        }
    }

    private func build(address: String, url: URL, key: String) async {
        await waitWhilePaused()
        await fetchSlots.acquire()
        var preview = PagePreview()
        do {
            var request = URLRequest(url: url)
            request.setValue("text/html,application/xhtml+xml,*/*;q=0.8", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            let mime = response.mimeType?.lowercased() ?? ""
            if mime.contains("pdf") || url.pathExtension.lowercased() == "pdf" {
                preview.isPDF = true
            } else if mime.contains("html") || mime.isEmpty {
                let html = String(decoding: data.prefix(2_500_000), as: UTF8.self)
                preview = await Task.detached(priority: .utility) { Self.parse(html, base: response.url ?? url) }.value
            }
        } catch {}

        var cover: NSImage?
        // Papers and PDFs: the first page *is* the best preview.
        if let pdf = Self.pdfURL(for: url, isPDF: preview.isPDF) {
            cover = await Self.firstPage(of: pdf, session: session)
            if cover != nil { preview.isPDF = true }
        }
        if cover == nil, let string = preview.imageURL, !Self.looksGeneric(string), let imageURL = URL(string: string),
           let (data, _) = try? await session.data(from: imageURL),
           let image = NSImage(data: data), Self.pixelWidth(image) >= 480 {
            cover = image
        }
        await fetchSlots.release()

        if cover == nil, Self.snapshottable(url) {
            await waitWhilePaused()
            await snapshotSlots.acquire()
            cover = await Snapshotter.snapshot(url)
            await snapshotSlots.release()
        }

        if preview.text == nil { preview.text = "" }
        let dir = directory
        let scaledResult: (NSImage, Data)? = if let cover {
            await Task.detached(priority: .utility) { Self.downscale(cover, width: 760) }.value
        } else { nil }
        var published: NSImage?
        if let (scaled, jpeg) = scaledResult {
            preview.hasImage = true
            preview.aspect = scaled.size.height / max(scaled.size.width, 1)
            published = scaled
            Task.detached(priority: .utility) { try? jpeg.write(to: dir.appendingPathComponent(key + ".jpg")) }
        }
        publish(address, info: preview, image: published)
        let toSave = preview
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(toSave) {
                try? data.write(to: dir.appendingPathComponent(key + ".json"))
            }
        }
        requestIcon(host: url.host?.lowercased() ?? "", hint: preview.iconURL.flatMap(URL.init(string:)))
    }

    private func requestIcon(host: String, hint: URL?) {
        guard !host.isEmpty, !iconRequested.contains(host) else { return }
        iconRequested.insert(host)
        let file = directory.appendingPathComponent("icon-" + Self.hash(host) + ".png")
        Task {
            if let cached = await Task.detached(priority: .userInitiated, operation: { Self.decodeImage(at: file) }).value {
                publishIcon(host, image: cached, fast: true)
                return
            }
            var candidates: [URL] = []
            if let hint { candidates.append(hint) }
            if let fallback = URL(string: "https://\(host)/favicon.ico") { candidates.append(fallback) }
            for candidate in candidates {
                guard let (data, response) = try? await session.data(from: candidate),
                      (response as? HTTPURLResponse)?.statusCode ?? 200 < 400 else { continue }
                let result = await Task.detached(priority: .utility) { () -> NSImage? in
                    guard let image = NSImage(data: data), image.isValid,
                          let (scaled, png) = Self.downscale(image, width: 64, format: .png) else { return nil }
                    try? png.write(to: file)
                    return scaled
                }.value
                if let scaled = result {
                    publishIcon(host, image: scaled)
                    return
                }
            }
        }
    }

    // MARK: Parsing

    nonisolated private static let metaTagRegex = try! NSRegularExpression(pattern: #"<meta\b[^>]*>"#, options: [.caseInsensitive])
    nonisolated private static let linkTagRegex = try! NSRegularExpression(pattern: #"<link\b[^>]*>"#, options: [.caseInsensitive])
    nonisolated private static let attrRegex = try! NSRegularExpression(pattern: #"([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#)
    nonisolated private static let numericEntityRegex = try! NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);")
    nonisolated private static let titleTagRegex = try! NSRegularExpression(pattern: #"<title[^>]*>([\s\S]*?)</title>"#, options: [.caseInsensitive])
    nonisolated private static let stripTagsRegex = try! NSRegularExpression(pattern: #"<[^>]+>"#)
    nonisolated private static let stripBlocksRegex = try! NSRegularExpression(
        pattern: #"<(script|style|noscript|svg|nav|header|footer|aside|form)\b[\s\S]*?</\1>"#, options: [.caseInsensitive])
    nonisolated private static let mainBlockRegexes = ["article", "main"].map {
        try! NSRegularExpression(pattern: "<\($0)\\b[\\s\\S]*?</\($0)>", options: [.caseInsensitive])
    }

    nonisolated static func parse(_ html: String, base: URL) -> PagePreview {
        var preview = PagePreview()
        var meta: [String: String] = [:]
        let range = NSRange(html.startIndex..., in: html)
        for match in metaTagRegex.matches(in: html, range: range) {
            guard let r = Range(match.range, in: html) else { continue }
            let attributes = Self.attributes(String(html[r]))
            guard let name = (attributes["property"] ?? attributes["name"] ?? attributes["itemprop"])?.lowercased(),
                  let content = attributes["content"], meta[name] == nil else { continue }
            meta[name] = decode(content)
        }
        var icons: [(Int, String)] = []
        for match in linkTagRegex.matches(in: html, range: range) {
            guard let r = Range(match.range, in: html) else { continue }
            let attributes = Self.attributes(String(html[r]))
            guard let rel = attributes["rel"]?.lowercased(), let href = attributes["href"] else { continue }
            if rel.contains("apple-touch-icon") { icons.append((0, href)) }
            else if rel.contains("icon") && !rel.contains("mask") { icons.append((rel.contains("shortcut") ? 2 : 1, href)) }
        }
        let titleTag: String? = titleTagRegex.firstMatch(in: html, range: range)
            .flatMap { Range($0.range(at: 1), in: html) }
            .map { raw in
                let s = String(html[raw])
                return stripTagsRegex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
            }

        preview.title = (meta["og:title"] ?? meta["twitter:title"] ?? titleTag.map(decode))?.trimmed.nonEmpty
        preview.summary = (meta["og:description"] ?? meta["description"] ?? meta["twitter:description"])?.trimmed.nonEmpty
        preview.siteName = meta["og:site_name"]?.trimmed.nonEmpty
        if let image = meta["og:image"] ?? meta["og:image:url"] ?? meta["twitter:image"] ?? meta["twitter:image:src"] {
            preview.imageURL = URL(string: image, relativeTo: base)?.absoluteString
        }
        if let icon = icons.sorted(by: { $0.0 < $1.0 }).first {
            preview.iconURL = URL(string: decode(icon.1), relativeTo: base)?.absoluteString
        }

        let text = plainText(html)
        let words = text.split(whereSeparator: { $0.isWhitespace }).filter { $0.count > 1 }
        if words.count > 150 { preview.minutes = max(1, Int((Double(words.count) / 230).rounded())) }
        // Search text comes from <article> or <main> when the page has one, so menus and
        // sidebars don't drown out what the page is about.
        let main = mainBlockRegexes.lazy.compactMap { regex -> String? in
            regex.firstMatch(in: html, range: range).flatMap { Range($0.range, in: html) }.map { String(html[$0]) }
        }.first
        let body = main.map(plainText).flatMap { $0.count > 200 ? $0 : nil } ?? text
        preview.text = String(decode(body).split(whereSeparator: { $0.isWhitespace }).prefix(300).joined(separator: " ").prefix(2400))
        return preview
    }

    nonisolated private static func plainText(_ html: String) -> String {
        let stripped = stripBlocksRegex.stringByReplacingMatches(in: html, range: NSRange(html.startIndex..., in: html), withTemplate: " ")
        return stripTagsRegex.stringByReplacingMatches(in: stripped, range: NSRange(stripped.startIndex..., in: stripped), withTemplate: " ")
    }

    nonisolated private static func attributes(_ tag: String) -> [String: String] {
        var result: [String: String] = [:]
        for match in attrRegex.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
            guard let key = Range(match.range(at: 1), in: tag) else { continue }
            let value = [2, 3, 4].compactMap { Range(match.range(at: $0), in: tag) }.first.map { String(tag[$0]) } ?? ""
            result[String(tag[key]).lowercased()] = value
        }
        return result
    }

    nonisolated private static func decode(_ string: String) -> String {
        guard string.contains("&") else { return string }
        var result = string
        let named = ["&amp;": "&", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " ",
                     "&mdash;": "—", "&ndash;": "–", "&hellip;": "…", "&rsquo;": "’", "&lsquo;": "‘", "&rdquo;": "”", "&ldquo;": "“"]
        for (entity, character) in named where result.contains(entity) {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        for match in numericEntityRegex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
            guard let whole = Range(match.range, in: result), let digits = Range(match.range(at: 2), in: result) else { continue }
            let hex = match.range(at: 1).length > 0
            if let code = UInt32(result[digits], radix: hex ? 16 : 10), let scalar = Unicode.Scalar(code) {
                result.replaceSubrange(whole, with: String(Character(scalar)))
            }
        }
        return result
    }

    // MARK: Images

    nonisolated private static func snapshottable(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return !signedIn.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Site-wide share images (logos, default banners) say nothing about the page.
    nonisolated private static func looksGeneric(_ image: String) -> Bool {
        let lower = image.lowercased()
        return ["logo", "default", "placeholder", "fallback", "favicon", "apple-touch"].contains { lower.contains($0) }
    }

    nonisolated private static func pdfURL(for url: URL, isPDF: Bool) -> URL? {
        if isPDF || url.pathExtension.lowercased() == "pdf" { return url }
        guard let host = url.host?.lowercased() else { return nil }
        if host.hasSuffix("arxiv.org"), url.path.hasPrefix("/abs/") {
            return URL(string: "https://arxiv.org/pdf/" + url.path.dropFirst(5))
        }
        if host.hasSuffix("openreview.net"), url.path == "/forum",
           let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value {
            return URL(string: "https://openreview.net/pdf?id=\(id)")
        }
        return nil
    }

    nonisolated private static func firstPage(of url: URL, session: URLSession) async -> NSImage? {
        guard let (data, _) = try? await session.data(from: url), data.count < 60_000_000,
              data.starts(with: Data("%PDF".utf8)) || data.prefix(1024).range(of: Data("%PDF".utf8)) != nil else { return nil }
        return await Task.detached(priority: .utility) { () -> NSImage? in
            guard let page = PDFDocument(data: data)?.page(at: 0) else { return nil }
            let bounds = page.bounds(for: .cropBox)
            let width: CGFloat = 900
            return page.thumbnail(of: NSSize(width: width, height: width * bounds.height / max(bounds.width, 1)), for: .cropBox)
        }.value
    }

    /// Reads and pre-decodes an image off the main thread so the first draw never stalls scrolling.
    nonisolated private static func decodeImage(at url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    nonisolated static func pixelWidth(_ image: NSImage) -> Int {
        image.representations.map(\.pixelsWide).max() ?? Int(image.size.width)
    }

    nonisolated static func downscale(_ image: NSImage, width: CGFloat, format: NSBitmapImageRep.FileType = .jpeg) -> (NSImage, Data)? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, width / CGFloat(cg.width))
        let size = CGSize(width: max(1, CGFloat(cg.width) * scale), height: max(1, CGFloat(cg.height) * scale))
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(cg, in: CGRect(origin: .zero, size: size))
        guard let output = context.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: output)
        let data = format == .jpeg ? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
                                   : rep.representation(using: .png, properties: [:])
        guard let data else { return nil }
        return (NSImage(cgImage: output, size: size), data)
    }

    nonisolated static func encode(_ image: NSImage, format: NSBitmapImageRep.FileType) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: format, properties: [:])
    }

    nonisolated static func hash(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

/// Renders a page in a private, off-screen web view and grabs its top fold.
@MainActor
enum Snapshotter {
    private final class Waiter: NSObject, WKNavigationDelegate {
        var continuation: CheckedContinuation<Void, Never>?
        func finish() { continuation?.resume(); continuation = nil }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish() }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish() }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish() }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish() }
    }

    static func snapshot(_ url: URL) async -> NSImage? {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let frame = NSRect(x: 0, y: 0, width: 1280, height: 840)
        let view = WKWebView(frame: frame, configuration: configuration)
        let window = NSWindow(contentRect: frame.offsetBy(dx: -30000, dy: -30000), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.contentView = view
        window.orderFrontRegardless()
        defer {
            view.stopLoading()
            window.orderOut(nil)
            window.contentView = nil
        }
        let waiter = Waiter()
        view.navigationDelegate = waiter
        view.load(URLRequest(url: url, timeoutInterval: 15))
        var timeout: Task<Void, Never>?
        await withCheckedContinuation { continuation in
            waiter.continuation = continuation
            timeout = Task {
                try? await Task.sleep(for: .seconds(16))
                waiter.finish()
            }
        }
        timeout?.cancel()
        try? await Task.sleep(for: .milliseconds(1400))
        let settings = WKSnapshotConfiguration()
        settings.rect = CGRect(x: 0, y: 0, width: 1280, height: 800)
        settings.snapshotWidth = 760
        return try? await view.takeSnapshot(configuration: settings)
    }
}

actor Limiter {
    private var available: Int
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(_ count: Int) { available = count }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        if waiting.isEmpty { available += 1 }
        else { waiting.removeFirst().resume() }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nonEmpty: String? { isEmpty ? nil : self }
}

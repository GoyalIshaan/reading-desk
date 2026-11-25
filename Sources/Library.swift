import AppKit
import Foundation

enum Shelf: String, CaseIterable, Identifiable {
    case research = "Papers & research"
    case engineering = "Code & engineering"
    case learning = "Courses & learning"
    case ai = "AI assistants"
    case writing = "Writing & documents"
    case media = "Media"
    case communication = "Communication"
    case other = "Other tabs"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .research: "books.vertical"
        case .engineering: "chevron.left.forwardslash.chevron.right"
        case .learning: "graduationcap"
        case .ai: "sparkle"
        case .writing: "doc.text"
        case .media: "play.rectangle"
        case .communication: "bubble.left.and.bubble.right"
        case .other: "rectangle.on.rectangle"
        }
    }

    static func classify(_ tab: BrowserTab) -> Self {
        let site = tab.host
        let title = tab.title.lowercased()
        let address = tab.address.lowercased()
        func matches(_ domains: String...) -> Bool {
            domains.contains { site == $0 || site.hasSuffix("." + $0) }
        }
        func mentions(_ terms: String...) -> Bool { terms.contains { title.contains($0) } }

        if matches("chatgpt.com", "claude.ai", "gemini.google.com", "perplexity.ai", "grok.com") { return .ai }
        if matches("arxiv.org", "openreview.net", "semanticscholar.org", "acm.org", "ieee.org", "paperswithcode.com", "nature.com", "springer.com", "doi.org", "nih.gov", "scholar.google.com") || mentions("arxiv", "technical report") { return .research }
        if matches("canvas.net", "instructure.com", "coursera.org", "edx.org", "gradescope.com", "khanacademy.org", "prairielearn.com", "zybooks.com") || site.hasSuffix(".edu") || mentions("syllabus", "office hours", "lecture notes") { return .learning }
        if matches("docs.google.com", "drive.google.com", "notion.so", "overleaf.com", "dropbox.com", "sharepoint.com", "figma.com", "coda.io") { return .writing }
        if matches("mail.google.com", "outlook.com", "outlook.office.com", "slack.com", "discord.com", "linear.app", "linkedin.com", "reddit.com", "x.com", "bsky.app", "twitter.com") { return .communication }
        if matches("youtube.com", "youtu.be", "vimeo.com", "twitch.tv", "spotify.com", "netflix.com") { return .media }
        if matches("github.com", "gitlab.com", "codeberg.org", "stackoverflow.com", "huggingface.co", "developer.mozilla.org", "developer.apple.com", "pytorch.org", "rust-lang.org", "godbolt.org", "llvm.org", "pypi.org", "npmjs.com") || site.hasPrefix("docs.") || site.hasPrefix("developer.") || address.contains("/docs/") || mentions("api reference", "documentation", "language reference") { return .engineering }
        return .other
    }
}

struct BrowserTab: Decodable, Identifiable, Hashable {
    let id: String
    let windowID: String
    let title: String
    let address: String

    var url: URL? { URL(string: address) }
    var host: String { url?.host?.lowercased() ?? "" }
    var sourceName: String {
        if !host.isEmpty { return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host }
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
    @Published var assignments: [String: String] = UserDefaults.standard.dictionary(forKey: "categories") as? [String: String] ?? [:]
    @Published var updating = false
    @Published var error: String?
    @Published var loaded = false
    @Published var sample = ProcessInfo.processInfo.arguments.contains("--sample")

    private var refreshTask: Task<Void, Never>?

    func refresh() {
        guard refreshTask == nil else { return }
        if sample {
            tabs = Self.sampleTabs
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
                tabs = try JSONDecoder().decode([BrowserTab].self, from: try await Helium.run())
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func shelf(for tab: BrowserTab) -> Shelf {
        assignments[tab.address].flatMap(Shelf.init(rawValue:)) ?? Shelf.classify(tab)
    }

    func assign(_ tab: BrowserTab, to shelf: Shelf?) {
        assignments[tab.address] = shelf?.rawValue
        UserDefaults.standard.set(assignments, forKey: "categories")
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
        ("Compiler design lecture · YouTube", "https://www.youtube.com/")
    ].enumerated().map { index, entry in
        BrowserTab(id: String(index), windowID: "1", title: entry.0, address: entry.1)
    }
}

import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Hosts the Obsidian-style reading view: a WKWebView running note.html with
/// markdown-it + KaTeX, talking to Swift for links, embeds, tasks and LaTeX.
@MainActor
final class NoteRenderer: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {
    let view: WKWebView
    weak var vault: Vault?
    private let scheme = DeskScheme()
    private var ready = false
    private var pending: [String: Any]?
    private var shown: (path: String, text: String)?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(scheme, forURLScheme: "desk")
        let controller = WKUserContentController()
        configuration.userContentController = controller
        view = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        controller.add(WeakHandler(self), name: "desk")
        view.navigationDelegate = self
        view.setValue(false, forKey: "drawsBackground")
        view.underPageBackgroundColor = NSColor(Theme.notes)
        view.isInspectable = ProcessInfo.processInfo.arguments.contains("--inspect")
        scheme.root = { [weak self] in self?.vault?.root }
        view.load(URLRequest(url: URL(string: "desk://app/note.html")!))
    }

    static let debug = ProcessInfo.processInfo.arguments.contains("--debug-notes")

    func show(_ note: Note, text: String) {
        if Self.debug { NSLog("ReadingDesk notes: show \(note.path) ready=\(ready)") }
        let keep = shown?.path == note.path
        if keep && shown?.text == text { return }
        shown = (note.path, text)
        let payload: [String: Any] = [
            "markdown": text, "path": note.path, "keepScroll": keep,
            "attachments": vault?.attachments ?? [],
        ]
        if ready { call("deskRender", payload) } else { pending = payload }
    }

    func forget() { shown = nil }

    private func call(_ function: String, _ arguments: Any...) {
        guard let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.fragmentsAllowed]),
              let json = String(data: data, encoding: .utf8) else { return }
        view.evaluateJavaScript("window.\(function).apply(null, \(json))") { _, error in
            if let error { NSLog("ReadingDesk notes: \(function) failed: \(error)") }
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        if Self.debug { NSLog("ReadingDesk notes ← \(type)") }
        switch type {
        case "log":
            NSLog("ReadingDesk notes JS: \(body["message"] ?? "")")
        case "ready":
            ready = true
            if let pending { call("deskRender", pending) }
            pending = nil
        case "open":
            guard let target = body["target"] as? String, let vault else { return }
            if let note = vault.resolve(target) { Task { await vault.open(note) } }
        case "embed":
            guard let id = body["id"] as? String, let target = body["target"] as? String, let vault else { return }
            Task {
                let text = await vault.resolve(target).asyncMap { await vault.contents(of: $0) } ?? nil
                call("deskFillEmbed", id, text as Any? ?? NSNull())
            }
        case "edit":
            // Typed in the live editor. Remember it as shown so the round trip
            // through vault.text doesn't re-render (and kill) the editor.
            guard let text = body["text"] as? String, let vault, let note = vault.selection else { return }
            shown = (note.path, text)
            vault.edit(text)
        case "toggleTask":
            guard let line = body["line"] as? Int else { return }
            vault?.toggleTask(atLine: line)
        case "latex":
            guard let id = body["id"] as? String, let source = body["source"] as? String,
                  let mode = (body["mode"] as? String).flatMap(Latex.Mode.init(rawValue:)) else { return }
            Task {
                switch await Latex.render(source, mode: mode) {
                case .success(let svg): call("deskFillLatex", id, source, mode.rawValue, svg, NSNull())
                case .failure(let error): call("deskFillLatex", id, source, mode.rawValue, NSNull(), error.message)
                }
            }
        case "copy":
            guard let text = body["text"] as? String else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case "external":
            guard let string = body["url"] as? String, let url = URL(string: string) else { return }
            if url.scheme == "desk", url.host == "vault", let root = vault?.root {
                NSWorkspace.shared.open(root.appendingPathComponent(url.path.removingPercentEncoding ?? url.path))
            } else if ["http", "https"].contains(url.scheme) {
                Helium.open(url)
            } else if url.scheme == "obsidian" || url.scheme == "mailto" {
                NSWorkspace.shared.open(url)
            }
        default:
            break
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        navigationAction.request.url?.scheme == "desk" ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if Self.debug { NSLog("ReadingDesk notes: page loaded \(webView.url?.absoluteString ?? "")") }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        NSLog("ReadingDesk notes: page failed to load: \(error)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false
        if let shown { pending = ["markdown": shown.text, "path": shown.path, "keepScroll": false, "attachments": vault?.attachments ?? []] }
        webView.load(URLRequest(url: URL(string: "desk://app/note.html")!))
    }
}

private extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async -> T) async -> T? {
        guard let self else { return nil }
        return await transform(self)
    }
}

/// WKUserContentController retains its handlers; this breaks the cycle.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// desk://app/… serves the bundled renderer, fonts and KaTeX.
/// desk://vault/… serves files from the open vault (images, PDFs), never outside it.
private final class DeskScheme: NSObject, WKURLSchemeHandler {
    var root: (@MainActor () -> URL?)?

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let path = (url.path.removingPercentEncoding ?? url.path).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var file: URL?
        if url.host == "app", let resources = Bundle.main.resourceURL {
            let base = path.hasPrefix("fonts/") ? resources.appendingPathComponent("Fonts") : resources.appendingPathComponent("web")
            let relative = path.hasPrefix("fonts/") ? String(path.dropFirst(6)) : path
            file = contained(base.appendingPathComponent(relative), in: base)
        } else if url.host == "vault", let base = MainActor.assumeIsolated({ root?() }) {
            file = contained(base.appendingPathComponent(path), in: base)
        }
        guard let file, let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": mime, "Content-Length": String(data.count), "Cache-Control": "no-cache"])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    private func contained(_ file: URL, in base: URL) -> URL? {
        let resolved = file.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = base.resolvingSymlinksInPath().standardizedFileURL.path
        return resolved.hasPrefix(prefix.hasSuffix("/") ? prefix : prefix + "/") ? URL(fileURLWithPath: resolved) : nil
    }
}

struct NoteWebView: NSViewRepresentable {
    let renderer: NoteRenderer
    func makeNSView(context: Context) -> WKWebView { renderer.view }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

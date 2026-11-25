import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Hosts the Obsidian-style reading view: a WKWebView running note.html with
/// markdown-it + KaTeX, talking to Swift for links, embeds, tasks and LaTeX.
@MainActor
final class NoteRenderer: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {
    let view: NoteEditorWebView
    weak var vault: Vault?
    private let scheme = DeskScheme()
    /// The page loads note.html, then says "ready". Until then the latest render waits here.
    private enum Page {
        case loading(pending: [String: Any]?)
        case ready
    }
    private var page: Page = .loading(pending: nil)
    private var ready: Bool { if case .ready = page { true } else { false } }
    private var shown: (path: String, text: String)?
    /// Set after a highlight: once the note re-renders, put the caret on the last line.
    private var caretToEnd = false

    override init() {
        // With macOS "smart quotes and dashes" on, typing `---` saves an em dash, so no
        // divider ever appears, and quotes in code get curled. WebKit has no per-field
        // switch; it reads these defaults. Source mode turns the same features off.
        UserDefaults.standard.register(defaults: [
            "WebAutomaticDashSubstitutionEnabled": false,
            "WebAutomaticQuoteSubstitutionEnabled": false,
            "WebAutomaticTextReplacementEnabled": false,
        ])
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(scheme, forURLScheme: "desk")
        let controller = WKUserContentController()
        configuration.userContentController = controller
        view = NoteEditorWebView(frame: .zero, configuration: configuration)
        super.init()
        view.pasteAttachments = { [weak self] in self?.paste($0) }
        view.format = { [weak self] in self?.apply($0) }
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
        switch page {
        case .ready:
            call("deskRender", payload)
            placeCaretIfAsked()
        case .loading:
            page = .loading(pending: payload)
        }
    }

    /// Asks for the caret at the end of the note on its next render (or now, if it's already shown).
    func startEditingAtEnd(_ note: Note, text: String) {
        caretToEnd = true
        if ready, shown?.path == note.path, shown?.text == text { placeCaretIfAsked() }
    }

    private func placeCaretIfAsked() {
        guard caretToEnd else { return }
        caretToEnd = false
        view.window?.makeFirstResponder(view)
        call("deskStartEditing")
        // The pane may only just have been put on screen; take focus once it's in the window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, let window = self.view.window, window.firstResponder !== self.view else { return }
            window.makeFirstResponder(self.view)
        }
        view.evaluateJavaScript("window.scrollTo({ top: document.documentElement.scrollHeight, behavior: 'smooth' })")
    }

    func forget() { shown = nil }

    /// What the live editor has under the cursor.
    private struct EditorState: Decodable {
        let text: String
        let start: Int
        let end: Int
    }

    private func editorState(orAppend: Bool) async -> EditorState? {
        let script = "JSON.stringify(window.deskEditorState(\(orAppend)))"
        guard let json = try? await view.evaluateJavaScript(script) as? String else { return nil }
        return try? JSONDecoder().decode(EditorState?.self, from: Data(json.utf8))
    }

    private func apply(_ format: TextFormat) {
        Task {
            guard let state = await editorState(orAppend: false) else { return }
            let edit = format.edit(state.text, selection: NSRange(location: state.start, length: state.end - state.start))
            call("deskReplace", edit.range.location, NSMaxRange(edit.range), edit.replacement,
                 edit.selection.location, NSMaxRange(edit.selection))
        }
    }

    /// Files the pasted images in the vault, then types their embeds at the cursor.
    private func paste(_ items: [PastedAttachment]) {
        Task {
            guard let vault, let markdown = vault.attach(items) else { return }
            call("deskSetAttachments", vault.attachments)
            guard let state = await editorState(orAppend: true) else { return }
            let caret = state.start + (markdown as NSString).length
            call("deskReplace", state.start, state.end, markdown, caret, caret)
        }
    }

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
            let waiting: [String: Any]? = if case .loading(let pending) = page { pending } else { nil }
            page = .ready
            if let waiting {
                call("deskRender", waiting)
                placeCaretIfAsked()
            }
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
        case "pasteFiles":
            if let items = PastedAttachment.read(from: .general) { paste(items) }
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
        page = .loading(pending: shown.map {
            ["markdown": $0.text, "path": $0.path, "keepScroll": false, "attachments": vault?.attachments ?? []]
        })
        webView.load(URLRequest(url: URL(string: "desk://app/note.html")!))
    }
}

private extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async -> T) async -> T? {
        guard let self else { return nil }
        return await transform(self)
    }
}

/// The notes web view, which takes over the edit commands a web page can't do alone.
final class NoteEditorWebView: WKWebView, FormattingEditor {
    var pasteAttachments: (([PastedAttachment]) -> Void)?
    var format: ((TextFormat) -> Void)?

    // A page can't put a pasted image into the vault, so that paste is handled here.
    // WKWebView doesn't declare `paste:`, hence calling its version through the runtime.
    @objc func paste(_ sender: Any?) {
        if let items = PastedAttachment.read(from: .general) {
            pasteAttachments?(items)
            return
        }
        let selector = #selector(paste(_:))
        guard let method = class_getInstanceMethod(WKWebView.self, selector) else { return }
        typealias Paste = @convention(c) (AnyObject, Selector, Any?) -> Void
        unsafeBitCast(method_getImplementation(method), to: Paste.self)(self, selector, sender)
    }

    /// Edit ▸ Select All means the whole note, not just the line being edited.
    override func selectAll(_ sender: Any?) {
        evaluateJavaScript("window.deskSelectAll()")
    }

    @objc func deskFormat(_ sender: Any?) {
        if let command = TextFormat.from(sender) { format?(command) }
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

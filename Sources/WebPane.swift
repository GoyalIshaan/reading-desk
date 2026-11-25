import SwiftUI
import WebKit

@MainActor
final class WebPage: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, WKScriptMessageHandler {
    struct State: Equatable {
        var url: URL?
        var back = false
        var forward = false
        var loading = false
    }

    @Published private(set) var state = State()
    @Published private(set) var failure: String?
    @Published private(set) var openedPage: WebPage?

    private var observations: [NSKeyValueObservation] = []
    private weak var opener: WebPage?
    private var openedPages: [WebPage] = []
    private var requested: URL?
    private var suppliedConfiguration: WKWebViewConfiguration?
    /// The reading pane reports selections and scroll position; chat panes don't.
    private let captures: Bool
    /// Selection / scroll messages from the injected capture script, with the web view they
    /// came from: the page itself, or a window a link opened over it.
    var onCapture: (([String: Any], WKWebView) -> Void)?
    /// The main frame turned out to be a PDF, which reads better in the paper reader.
    var onPDF: ((URL) -> Void)?
    /// Called when an in-pane popup closes, so stale selection bars can be cleared.
    var onDismissOpened: (() -> Void)?
    /// Extra items at the top of the right-click menu (Save to note, Ask…).
    var menuItems: (() -> [NSMenuItem])?

    static let debugCapture = ProcessInfo.processInfo.arguments.contains("--debug-capture")

    init(captures: Bool = false) {
        self.captures = captures
        super.init()
    }

    lazy var view: WKWebView = {
        let configuration = suppliedConfiguration ?? {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .default()
            // Present as Safari. Google (Gemini) refuses sign-in from "embedded" web views otherwise.
            configuration.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
            return configuration
        }()
        if captures {
            let controller = configuration.userContentController
            controller.addUserScript(WKUserScript(source: CaptureScript.source, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
            controller.add(CaptureHandler(self), name: "deskCapture")
        }
        let view = DeskWebView(frame: .zero, configuration: configuration)
        view.extraMenuItems = { [weak self] in self?.menuItems?() ?? [] }
        suppliedConfiguration = nil
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.allowsMagnification = true
        view.underPageBackgroundColor = NSColor(Theme.ground)
        view.isInspectable = ProcessInfo.processInfo.arguments.contains("--inspect")
        @MainActor func watch<Value>(_ path: KeyPath<DeskWebView, Value>) {
            observations.append(view.observe(path, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.update() }
            })
        }
        watch(\.url)
        watch(\.canGoBack)
        watch(\.canGoForward)
        watch(\.isLoading)
        return view
    }()

    private func update() {
        let next = State(url: view.url ?? requested, back: view.canGoBack,
                         forward: view.canGoForward, loading: view.isLoading)
        if next != state { state = next }
    }

    func load(_ url: URL) {
        if openedPage != nil {
            for child in openedPages { child.view.stopLoading() }
            openedPages.removeAll()
            openedPage = nil
        }
        failure = nil
        requested = url
        let next = State(url: url, back: view.canGoBack, forward: view.canGoForward, loading: true)
        if next != state { state = next }
        if url.isFileURL {
            view.loadFileURL(url, allowingReadAccessTo: url)
        } else {
            view.load(URLRequest(url: url))
        }
    }

    /// Drops the page's content (and most of its web process's memory).
    func unload() {
        for child in openedPages { child.view.stopLoading() }
        openedPages.removeAll()
        openedPage = nil
        view.stopLoading()
        view.loadHTMLString("", baseURL: nil)
        requested = nil
    }

    func retry() {
        if failure != nil, let url = state.url ?? requested { load(url) }
        else { view.reload() }
    }

    func copyLink() {
        guard let url = state.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        failure = nil
        update()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        update()
        if Self.debugCapture && (captures || opener != nil) {
            NSLog("RD capture: finished \(webView.url?.absoluteString ?? "")")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                webView.evaluateJavaScript("(() => { const p = [...document.querySelectorAll('p, font, td')].find(e => e.innerText && e.innerText.length > 80); if (!p) return 'no paragraph; installed=' + !!window.__deskCapture; const r = document.createRange(); r.selectNodeContents(p); const s = getSelection(); s.removeAllRanges(); s.addRange(r); document.dispatchEvent(new MouseEvent('mouseup', { bubbles: true })); return 'selected; installed=' + !!window.__deskCapture; })()") { result, error in NSLog("RD capture: select → \(String(describing: result)) \(String(describing: error))") }
            }
        }
        // Don't override a fragment jump (#section or #:~:text=…) with an older scroll position.
        guard captures, let url = webView.url, url.fragment == nil, let y = ReadingMemory.scroll(for: url), y > 40 else { return }
        webView.evaluateJavaScript("window.__deskRestore && window.__deskRestore(\(Int(y)))")
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if Self.debugCapture { NSLog("RD capture: message \((message.body as? [String: Any])?["type"] ?? "?") main=\(message.frameInfo.isMainFrame) same=\(message.webView === view)") }
        // Windows opened from this page share its configuration, script and handler, so
        // their messages arrive here too. Only the reading pane's family has this script.
        guard message.frameInfo.isMainFrame, let webView = message.webView,
              let body = message.body as? [String: Any] else { return }
        if body["type"] as? String == "scroll" {
            if let y = body["y"] as? Double, let url = webView.url {
                ReadingMemory.setScroll(y, for: url)
            }
            return
        }
        onCapture?(body, webView)
    }

    /// The page's headings, for the Contents menu.
    func outline() async -> [(level: Int, text: String)] {
        guard captures, let result = try? await view.evaluateJavaScript("window.__deskOutline ? window.__deskOutline() : []"),
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let text = item["text"] as? String, !text.isEmpty else { return nil }
            return ((item["level"] as? Int) ?? (item["level"] as? Double).map(Int.init) ?? 2, text)
        }
    }

    func jump(toHeading index: Int) {
        view.evaluateJavaScript("window.__deskJump && window.__deskJump(\(index))")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }

    private func fail(_ error: Error) {
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled || (nsError.domain == "WebKitErrorDomain" && nsError.code == 102) { return }
        failure = error.localizedDescription
        update()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        failure = "The page stopped responding."
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        if navigationAction.shouldPerformDownload { return .download }
        switch url.scheme?.lowercased() {
        case "http", "https", "about", "blob", "data":
            return .allow
        case "file":
            return requested?.isFileURL == true ? .allow : .cancel
        case "mailto", "tel", "obsidian":
            if navigationAction.navigationType == .linkActivated { NSWorkspace.shared.open(url) }
            return .cancel
        default:
            return .cancel
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if response.isForMainFrame, response.response.mimeType?.lowercased() == "application/pdf",
           let url = response.response.url, let onPDF {
            onPDF(url)
        }
        return response.canShowMIMEType ? .allow : .download
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        return await panel.begin() == .OK ? panel.url : nil
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        fail(error)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let child = WebPage()
        // WebKit supplies this configuration to retain the opener and storage
        // context for window.open, including a site's sign-in callbacks.
        child.suppliedConfiguration = configuration
        child.opener = self
        // A page opened from the reader gets the same right-click actions.
        child.menuItems = { [weak self] in self?.menuItems?() ?? [] }
        let childView = child.view
        openedPages.append(child)
        openedPage = child
        return childView
    }

    func webViewDidClose(_ webView: WKWebView) {
        opener?.dismiss(self)
    }

    func dismiss(_ page: WebPage) {
        guard openedPages.contains(where: { $0 === page }) else { return }
        page.view.stopLoading()
        openedPages.removeAll { $0 === page }
        if openedPage === page { openedPage = openedPages.last }
        onDismissOpened?()
    }

}

/// A web view whose right-click menu can lead with Reading Desk's own actions.
final class DeskWebView: WKWebView {
    var extraMenuItems: (() -> [NSMenuItem])?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        menu.insertExtras(extraMenuItems?() ?? [])
    }
}

/// A menu item that runs a closure.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}

extension NSMenu {
    /// Puts items at the top, above the system's own, with a separator between.
    func insertExtras(_ items: [NSMenuItem]) {
        guard !items.isEmpty else { return }
        if !self.items.isEmpty { insertItem(.separator(), at: 0) }
        for item in items.reversed() { insertItem(item, at: 0) }
    }
}

/// WKUserContentController retains its handlers; this keeps the page from leaking.
private final class CaptureHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

struct WebSurface: NSViewRepresentable {
    let page: WebPage

    func makeNSView(context: Context) -> WKWebView { page.view }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// A web page with no toolbar at all. The only chrome is a small floating pill
/// in the corner: a link button that expands on hover into back / forward /
/// reload / open-in-Helium.
struct BrowserPane: View {
    @ObservedObject var page: WebPage
    var showsChrome = true

    var body: some View {
        ZStack(alignment: .topTrailing) {
            WebSurface(page: page)
            if let failure = page.failure {
                FailureView(page: page, message: failure)
            } else if page.state.loading {
                LoadingStreak()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)
            }
            if showsChrome {
                // Bottom-right: site nav bars live at the top, so this rarely covers anything.
                PageChrome(page: page)
                    .padding(.bottom, 14).padding(.trailing, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .background(Theme.ground)
        .accessibilityHidden(page.openedPage != nil)
        .overlay {
            if let opened = page.openedPage {
                InPanePage(page: opened) { page.dismiss(opened) }
                    .id(ObjectIdentifier(opened))
            }
        }
    }
}

private struct InPanePage: View {
    @ObservedObject var page: WebPage
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                DeskIcon("chevron.left", help: "Go back") { page.view.goBack() }
                    .disabled(!page.state.back)
                DeskIcon("chevron.right", help: "Go forward") { page.view.goForward() }
                    .disabled(!page.state.forward)
                Text(page.state.url?.host ?? "New page")
                    .font(Theme.sans(12, .medium))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
                Spacer(minLength: 4)
                DeskIcon("xmark", help: "Close this page", action: close)
            }
            .padding(.horizontal, 10)
            .frame(height: 37)
            Hairline()
            BrowserPane(page: page, showsChrome: false)
        }
        .background(Theme.ground)
    }
}

private struct PageChrome: View {
    @ObservedObject var page: WebPage
    @State private var hovered = false
    @State private var copied = false

    var body: some View {
        if let url = page.state.url {
            HStack(spacing: 0) {
                // Back is always there once there's somewhere to go back to.
                if page.state.back || hovered {
                    ChromeButton("arrow.left", help: "Back (⌘[)") { page.view.goBack() }
                        .disabled(!page.state.back)
                }
                if page.state.forward || hovered {
                    ChromeButton("arrow.right", help: "Forward (⌘])") { page.view.goForward() }
                        .disabled(!page.state.forward)
                }
                if hovered {
                    ChromeButton(page.state.loading ? "xmark" : "arrow.clockwise", help: page.state.loading ? "Stop" : "Reload") {
                        if page.state.loading { page.view.stopLoading() } else { page.retry() }
                    }
                    ChromeButton("arrow.up.right", help: "Open in Helium") { Helium.open(url) }
                    Rectangle().fill(Theme.rule).frame(width: 1, height: 14).padding(.horizontal, 3)
                }
                ChromeButton(copied ? "checkmark" : "link", help: "Copy link") {
                    page.copyLink()
                    withAnimation(.easeOut(duration: 0.15)) { copied = true }
                    Task {
                        try? await Task.sleep(for: .seconds(1.4))
                        withAnimation(.easeOut(duration: 0.2)) { copied = false }
                    }
                }
                .foregroundStyle(copied ? Theme.accent : Theme.ink)
            }
            .padding(2)
            .background(Capsule().fill(Theme.ground.opacity(0.88)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.10)))
            .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
            .opacity(hovered || copied ? 1 : page.state.back ? 0.85 : 0.5)
            .environment(\.colorScheme, .dark)
            .onHover { inside in withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) { hovered = inside } }
        }
    }
}

/// Back / reload for the chat pane, which has no page chrome of its own.
struct ChatControls: View {
    @ObservedObject var page: WebPage

    var body: some View {
        HStack(spacing: 0) {
            DeskIcon("arrow.left", help: "Back") { page.view.goBack() }
                .disabled(!page.state.back)
            DeskIcon(page.state.loading ? "xmark" : "arrow.clockwise", help: page.state.loading ? "Stop" : "Reload") {
                if page.state.loading { page.view.stopLoading() } else { page.retry() }
            }
            if let url = page.state.url {
                DeskIcon("arrow.up.right", help: "Open in Helium") { Helium.open(url) }
            }
        }
    }
}

private struct ChromeButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    init(_ symbol: String, help: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.35)
        .help(help)
        .accessibilityLabel(help)
        .transition(.opacity.combined(with: .scale(scale: 0.8)))
    }
}

private struct LoadingStreak: View {
    @State private var phase = false

    var body: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(LinearGradient(colors: [.clear, Theme.accent, .clear], startPoint: .leading, endPoint: .trailing))
                .frame(width: geometry.size.width * 0.35, height: 2)
                .offset(x: phase ? geometry.size.width : -geometry.size.width * 0.35)
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false)) { phase = true }
                }
        }
        .frame(height: 2)
    }
}

private struct FailureView: View {
    @ObservedObject var page: WebPage
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("This page didn’t come through.").font(Theme.serif(34))
            Text(message).font(Theme.sans(13)).foregroundStyle(Theme.ink3)
            HStack(spacing: 10) {
                Button("Try again") { page.retry() }.buttonStyle(DeskButtonStyle(.primary))
                if let url = page.state.url {
                    Button("Open in Helium") { Helium.open(url) }.buttonStyle(DeskButtonStyle(.outline))
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: 440, alignment: .leading)
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ground)
    }
}

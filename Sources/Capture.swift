import CoreGraphics
import Foundation

/// A passage selected on the page (or in a PDF), ready to become a quote in a
/// note or a question in a chat.
struct Excerpt: Equatable {
    enum Kind: Equatable { case prose, code(language: String?) }

    /// Markdown-ready text: math is already `$…$` / `$$…$$`.
    var text: String
    /// The text as rendered on the page, for the scroll-to-text link.
    var plain: String
    var kind: Kind = .prose
    var section: String?
    /// 1-based PDF page, and the label printed on it (which can be "iv" or "12").
    var page: Int?
    var pageLabel: String?
    var sourceTitle: String
    var sourceURL: URL
    /// Where the selection sits, in the reading pane's coordinates (top-left origin).
    var rect: CGRect?

    /// A link back to exactly this passage: `#page=N` for PDFs, a text fragment for web pages.
    var link: URL {
        guard var components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false) else { return sourceURL }
        if let page {
            components.fragment = "page=\(page)"
            return components.url ?? sourceURL
        }
        let words = plain.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty, case .prose = kind else { return sourceURL }
        let directive: String
        if words.count <= 8 {
            directive = Self.fragmentEncode(words.joined(separator: " "))
        } else {
            directive = Self.fragmentEncode(words.prefix(4).joined(separator: " ")) + ","
                + Self.fragmentEncode(words.suffix(4).joined(separator: " "))
        }
        components.fragment = nil
        guard let base = components.url?.absoluteString else { return sourceURL }
        return URL(string: base + "#:~:text=" + directive) ?? sourceURL
    }

    private static let fragmentSafe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._~")

    private static func fragmentEncode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: fragmentSafe) ?? ""
    }

    private var where_: [String] {
        var parts: [String] = []
        if let section = section?.trimmed, !section.isEmpty,
           section.caseInsensitiveCompare(sourceTitle.trimmed) != .orderedSame { parts.append(section) }
        if let page { parts.append("p. " + (pageLabel?.trimmed.isEmpty == false ? pageLabel! : String(page))) }
        return parts
    }

    private var bodyLines: [String] {
        switch kind {
        case .code(let language):
            return ["```" + (language ?? "")] + text.components(separatedBy: "\n") + ["```"]
        case .prose:
            return text.components(separatedBy: "\n")
        }
    }

    /// An Obsidian callout: title, link and section/page in the heading, the passage inside.
    var noteBlock: String {
        var heading = "> [!quote] [" + Self.escapeLinkText(sourceTitle) + "](<" + link.absoluteString + ">)"
        if !where_.isEmpty { heading += " · " + where_.joined(separator: " · ") }
        let lines = bodyLines.map { $0.isEmpty ? ">" : "> " + $0 }
        return ([heading] + lines).joined(separator: "\n")
    }

    /// A question draft for a chat: the passage, where it came from, and room to ask.
    var prompt: String {
        var context = "I’m reading “\(sourceTitle.trimmed)” (\(sourceURL.absoluteString))"
        var place: [String] = []
        if let section = section?.trimmed, !section.isEmpty,
           section.caseInsensitiveCompare(sourceTitle.trimmed) != .orderedSame { place.append("in the section “\(section)”") }
        if let page { place.append("on page " + (pageLabel?.trimmed.isEmpty == false ? pageLabel! : String(page))) }
        if !place.isEmpty { context += ", " + place.joined(separator: ", ") }
        context += ". Here’s the passage I’m asking about:"
        let passage: String
        switch kind {
        case .code: passage = bodyLines.joined(separator: "\n")
        case .prose: passage = bodyLines.map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")
        }
        return context + "\n\n" + passage + "\n\n"
    }

    private static func escapeLinkText(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }

    /// Tidies text copied out of a page or PDF: no trailing spaces, at most one blank line in a row.
    static func tidy(_ text: String, fromPDF: Bool = false) -> String {
        var value = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\u{00A0}", with: " ")
        if fromPDF {
            // PDFs break every line. Re-join hyphenated words and wrapped lines, keep paragraph gaps.
            value = value.replacingOccurrences(of: #"(\p{Ll})-\n(\p{Ll})"#, with: "$1$2", options: .regularExpression)
            value = value.replacingOccurrences(of: #"\n{2,}"#, with: "\u{2029}", options: .regularExpression)
            value = value.replacingOccurrences(of: #"[ \t]*\n[ \t]*"#, with: " ", options: .regularExpression)
            value = value.replacingOccurrences(of: "\u{2029}", with: "\n\n")
        }
        let lines = value.components(separatedBy: "\n").map { line in
            String(line.reversed().drop(while: { $0 == " " || $0 == "\t" }).reversed())
        }
        value = lines.joined(separator: "\n")
        value = value.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Keys that identify "the same source" across URL spellings: arXiv abs/pdf/html
/// and versions, DOIs, OpenReview forum/pdf, and ordinary pages with or without
/// www, trailing slashes, fragments or tracking parameters.
enum SourceKey {
    static func key(for url: URL?) -> String? {
        guard let url else { return nil }
        if url.isFileURL { return "file:" + url.standardizedFileURL.path.lowercased() }
        guard var host = url.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        if let arxiv = arxivID(url) { return "arxiv:" + arxiv }
        if let doi = doi(in: url) { return "doi:" + doi.lowercased() }
        if host.hasSuffix("openreview.net"),
           let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value {
            return "openreview:" + id
        }
        var path = url.path
        while path.hasSuffix("/") { path.removeLast() }
        var key = host + path
        if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
            let kept = items.filter { item in
                let name = item.name.lowercased()
                return !(name.hasPrefix("utm_") || ["fbclid", "gclid", "ref", "ref_src", "source", "si", "mc_cid", "mc_eid"].contains(name))
            }
            .sorted { $0.name < $1.name }
            if !kept.isEmpty { key += "?" + kept.map { $0.name + "=" + ($0.value ?? "") }.joined(separator: "&") }
        }
        return key
    }

    static func key(for address: String) -> String? { key(for: URL(string: address)) }

    /// `1706.03762` for any arXiv abs/pdf/html URL, version stripped.
    static func arxivID(_ url: URL) -> String? {
        guard let host = url.host?.lowercased(), host == "arxiv.org" || host.hasSuffix(".arxiv.org") else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard let kind = parts.first, ["abs", "pdf", "html", "format"].contains(kind), parts.count >= 2 else { return nil }
        var id = parts.dropFirst().joined(separator: "/")
        if id.hasSuffix(".pdf") { id.removeLast(4) }
        id = id.replacingOccurrences(of: #"v\d+$"#, with: "", options: .regularExpression)
        return id.isEmpty ? nil : id
    }

    static func doi(in url: URL) -> String? {
        let text = (url.removingFragment.absoluteString.removingPercentEncoding ?? url.absoluteString)
        guard let range = text.range(of: #"10\.\d{4,9}/[^\s?#&]+"#, options: .regularExpression) else { return nil }
        var doi = String(text[range])
        for suffix in [".pdf", "/pdf", "/full", "/abstract"] where doi.lowercased().hasSuffix(suffix) { doi.removeLast(suffix.count) }
        return doi
    }
}

extension URL {
    var removingFragment: URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false), components.fragment != nil else { return self }
        components.fragment = nil
        return components.url ?? self
    }

    /// PDFs we can tell from the address alone, so they go straight to the paper reader.
    var looksLikePDF: Bool {
        let path = self.path.lowercased()
        if path.hasSuffix(".pdf") { return true }
        guard let host = host?.lowercased() else { return false }
        if (host == "arxiv.org" || host.hasSuffix(".arxiv.org")) && path.hasPrefix("/pdf/") { return true }
        if host.hasSuffix("openreview.net") && path.hasPrefix("/pdf") { return true }
        return false
    }
}

/// Injected into the reading pane. Reports the selection (with math turned back
/// into TeX and code kept verbatim), the section it sits under, and the scroll
/// position. Also answers "what are this page's headings" for the Contents menu.
enum CaptureScript {
    static let source = #"""
(() => {
  if (window.__deskCapture) return;
  window.__deskCapture = true;
  const post = (m) => { try { window.webkit.messageHandlers.deskCapture.postMessage(m); } catch (e) {} };
  const MATH = '.katex-display, .katex, math, mjx-container, .MathJax_Display, .MathJax, .mwe-math-element, img.mwe-math-fallback-image-inline, img.mwe-math-fallback-image-display, .ltx_equation, .ltx_Math';
  const displayish = (el) => el.matches('.katex-display, .MathJax_Display, .ltx_equation, .mwe-math-element-block, img.mwe-math-fallback-image-display') ||
    el.getAttribute('display') === 'block' || el.getAttribute('display') === 'true';

  function texOf(el, original) {
    const ann = el.querySelector && el.querySelector('annotation[encoding="application/x-tex"], annotation[encoding="TeX"]');
    if (ann) return ann.textContent.trim();
    for (const a of ['alttext', 'data-tex', 'data-latex', 'alt']) {
      const v = el.getAttribute && el.getAttribute(a);
      if (v && v.trim()) return v.trim().replace(/^\{\\displaystyle\s*(.*)\}$/s, '$1');
    }
    const script = el.querySelector && el.querySelector('script[type^="math/tex"]');
    if (script) return script.textContent.trim();
    // Wikipedia (Parsoid) keeps the source in data-mw.
    try {
      const mw = el.getAttribute && JSON.parse(el.getAttribute('data-mw') || 'null');
      if (mw && mw.body && mw.body.extsrc) return String(mw.body.extsrc).trim();
    } catch (e) {}
    try {
      const items = window.MathJax && MathJax.startup && MathJax.startup.document &&
        MathJax.startup.document.getMathItemsWithin && MathJax.startup.document.getMathItemsWithin(original || el);
      if (items && items.length) return String(items[0].math).trim();
    } catch (e) {}
    return null;
  }

  function outermost(node) {
    let el = node && (node.nodeType === 1 ? node : node.parentElement);
    let found = null;
    while (el) { if (el.matches && el.matches(MATH)) found = el; el = el.parentElement; }
    return found;
  }

  const headingText = (h) => h.innerText.replace(/[¶#§]\s*$/, '').replace(/\s+/g, ' ').trim()
    // "3.2Attention" or "A.1Proofs" (LaTeX section numbers set without a space). A lone capital is just a word.
    .replace(/^(\d+(?:\.\d+)*\.?|[A-Z]\.(?:\d+\.?)*)(?=\p{L})/u, '$1 ');

  function sectionFor(node) {
    const heads = document.querySelectorAll('h1, h2, h3, h4, h5, h6');
    let best = null;
    for (const h of heads) {
      if (h.offsetParent === null) continue;
      if (h.contains(node) || (h.compareDocumentPosition(node) & Node.DOCUMENT_POSITION_FOLLOWING)) best = h;
      else break;
    }
    if (!best) return null;
    return headingText(best).slice(0, 160) || null;
  }

  function codeLanguage(pre) {
    const names = [pre.className, (pre.querySelector('code') || {}).className || '', (pre.parentElement || {}).className || ''].join(' ');
    const m = /(?:language-|lang-|highlight-(?:source-)?|brush:\s*)([\w+#.-]+)/i.exec(names);
    return m ? m[1].toLowerCase() : null;
  }

  function capture() {
    const sel = window.getSelection();
    if (!sel || sel.rangeCount === 0 || sel.isCollapsed) return null;
    const plain = String(sel).trim();
    if (!plain) return null;
    const range = sel.getRangeAt(0).cloneRange();
    const startMath = outermost(range.startContainer), endMath = outermost(range.endContainer);
    if (startMath) range.setStartBefore(startMath);
    if (endMath) range.setEndAfter(endMath);
    const ancestor = range.commonAncestorContainer.nodeType === 1 ? range.commonAncestorContainer : range.commonAncestorContainer.parentElement;
    const pre = ancestor && ancestor.closest('pre');
    let text, kind = 'prose', language = null;
    if (pre) {
      kind = 'code';
      language = codeLanguage(pre);
      text = String(sel).replace(/\s+$/, '');
    } else {
      // Pair each math element in the clone with the live one, so MathJax can still be asked for its TeX.
      const live = [];
      document.querySelectorAll(MATH).forEach((el) => { if (range.intersectsNode(el) && !(el.parentElement && el.parentElement.closest(MATH))) live.push(el); });
      const box = document.createElement('div');
      box.appendChild(range.cloneContents());
      const clones = [...box.querySelectorAll(MATH)].filter((el) => !(el.parentElement && el.parentElement.closest(MATH)));
      clones.forEach((el, i) => {
        const tex = texOf(el, live[i]);
        // No TeX to be had: flatten the rendering instead of one symbol per line.
        if (!tex) { el.replaceWith(document.createTextNode(el.textContent.replace(/\s+/g, ' ').trim())); return; }
        const display = displayish(el) || (live[i] && displayish(live[i]));
        if (!display) { el.replaceWith(document.createTextNode('$' + tex + '$')); return; }
        // Block lines, so innerText keeps the $$ fences on lines of their own.
        const block = document.createElement('div');
        for (const line of ['$$', tex, '$$']) { const d = document.createElement('div'); d.textContent = line; block.appendChild(d); }
        el.replaceWith(block);
      });
      box.querySelectorAll('script, style, button, .MathJax_Preview, mjx-assistive-mml').forEach((el) => el.remove());
      box.style.cssText = 'position:fixed;left:-100000px;top:0;width:800px;white-space:normal;';
      document.body.appendChild(box);
      text = box.innerText;
      box.remove();
    }
    const rect = sel.getRangeAt(0).getBoundingClientRect();
    return {
      type: 'selection', text, plain, kind, language,
      section: sectionFor(range.startContainer.nodeType === 1 ? (range.startContainer.childNodes[range.startOffset] || range.startContainer) : range.startContainer),
      rect: { x: rect.left, y: rect.top, w: rect.width, h: rect.height },
      viewport: window.innerWidth,
    };
  }

  let shown = false;
  function report() {
    const found = capture();
    if (found) { shown = true; post(found); }
    else if (shown) { shown = false; post({ type: 'selection', empty: true }); }
  }
  document.addEventListener('mouseup', () => setTimeout(report, 0), true);
  document.addEventListener('keyup', (e) => { if (e.shiftKey || e.key === 'Shift' || (e.metaKey && e.key === 'a')) report(); }, true);
  document.addEventListener('selectionchange', () => {
    const sel = window.getSelection();
    if (shown && (!sel || sel.isCollapsed)) { shown = false; post({ type: 'selection', empty: true }); }
  });

  let moving = false, lastScroll = 0;
  window.addEventListener('scroll', () => {
    if (shown && !moving) {
      moving = true;
      requestAnimationFrame(() => {
        moving = false;
        const sel = window.getSelection();
        if (sel && sel.rangeCount && !sel.isCollapsed) {
          const r = sel.getRangeAt(0).getBoundingClientRect();
          post({ type: 'selectionRect', rect: { x: r.left, y: r.top, w: r.width, h: r.height }, viewport: window.innerWidth });
        }
      });
    }
    const now = Date.now();
    if (now - lastScroll > 400) {
      lastScroll = now;
      setTimeout(() => post({ type: 'scroll', y: window.scrollY, height: document.documentElement.scrollHeight }), 450);
    }
  }, { passive: true });

  window.__deskRestore = (y) => {
    let tries = 0;
    const attempt = () => {
      const room = document.documentElement.scrollHeight - window.innerHeight;
      if (room >= y - 4 || tries++ > 30) window.scrollTo(0, Math.min(y, Math.max(room, 0)));
      else setTimeout(attempt, 150);
    };
    attempt();
  };

  window.__deskOutline = () => {
    const heads = [...document.querySelectorAll('h1, h2, h3, h4')].filter((h) => h.offsetParent !== null && h.innerText.trim());
    window.__deskHeads = heads;
    return heads.slice(0, 250).map((h) => ({ level: Number(h.tagName[1]), text: headingText(h).slice(0, 120) }));
  };
  window.__deskJump = (i) => {
    const h = (window.__deskHeads || [])[i];
    if (h) h.scrollIntoView({ behavior: 'smooth', block: 'start' });
  };
})();
"""#
}

/// What a chat composer needs to receive a drafted question. Tries a paste first
/// (ProseMirror and Quill both handle it), then `insertText`, then a plain textarea.
enum ChatDraft {
    static let insert = #"""
const pick = () => {
  const selectors = ['#prompt-textarea', 'div.ProseMirror[contenteditable="true"]', 'rich-textarea .ql-editor',
    'div[contenteditable="true"][role="textbox"]', 'div[contenteditable="true"]', 'textarea'];
  for (const s of selectors) {
    for (const el of document.querySelectorAll(s)) {
      const r = el.getBoundingClientRect();
      if (r.width > 0 && r.height > 0 && !el.closest('[aria-hidden="true"]')) return el;
    }
  }
  return null;
};
const el = pick();
if (!el) return false;
el.focus();
if (el.tagName === 'TEXTAREA') {
  const setter = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value').set;
  setter.call(el, (el.value.trim() ? el.value.replace(/\s+$/, '') + '\n\n' : '') + text);
  el.dispatchEvent(new Event('input', { bubbles: true }));
  el.selectionStart = el.selectionEnd = el.value.length;
  return true;
}
const range = document.createRange();
// The end of the last paragraph, so a draft already in the box is kept and ours follows it.
range.selectNodeContents(el.lastElementChild || el);
range.collapse(false);
const selection = window.getSelection();
selection.removeAllRanges();
selection.addRange(range);
const before = el.innerText;
try {
  const data = new DataTransfer();
  data.setData('text/plain', text);
  el.dispatchEvent(new ClipboardEvent('paste', { clipboardData: data, bubbles: true, cancelable: true }));
} catch (e) {}
await new Promise((r) => setTimeout(r, 60));
if (el.innerText === before) document.execCommand('insertText', false, text);
return el.innerText !== before;
"""#
}

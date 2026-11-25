import AppKit
import SwiftUI

/// Native Markdown editor styled like Obsidian's source view: headings are
/// set large, syntax markers fade back, links, tags and math are tinted.
struct MarkdownEditor: NSViewRepresentable {
    let text: String
    let onChange: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        let textView = scroll.documentView as! NSTextView
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = NSSize(width: 30, height: 30)
        textView.insertionPointColor = NSColor(Theme.accent)
        textView.selectedTextAttributes = [.backgroundColor: NSColor(red: 0.65, green: 0.54, blue: 0.98, alpha: 0.3)]
        textView.typingAttributes = MarkdownStyle.base
        textView.string = text
        MarkdownStyle.apply(to: textView.textStorage!)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        let textView = scroll.documentView as! NSTextView
        if textView.string != text {
            let selection = textView.selectedRanges
            textView.string = text
            MarkdownStyle.apply(to: textView.textStorage!)
            textView.selectedRanges = selection.filter { $0.rangeValue.upperBound <= (text as NSString).length }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditor
        init(_ parent: MarkdownEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            MarkdownStyle.apply(to: textView.textStorage!)
            textView.typingAttributes = MarkdownStyle.base
            parent.onChange(textView.string)
        }
    }
}

enum MarkdownStyle {
    static let text = NSColor(red: 0.86, green: 0.84, blue: 0.80, alpha: 1)
    static let faint = NSColor(red: 0.43, green: 0.42, blue: 0.38, alpha: 1)
    static let muted = NSColor(red: 0.64, green: 0.62, blue: 0.58, alpha: 1)
    static let accent = NSColor(red: 0.65, green: 0.54, blue: 0.98, alpha: 1)
    static let code = NSColor(red: 0.90, green: 0.63, blue: 0.74, alpha: 1)
    static let math = NSColor(red: 0.88, green: 0.72, blue: 0.48, alpha: 1)

    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        let base = NSFont(name: "Geist", size: size) ?? .systemFont(ofSize: size)
        let descriptor = base.fontDescriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: weight]])
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    static let monoFont = NSFont(name: "JetBrainsMonoNLNFM-Regular", size: 13.5)
        ?? NSFont(name: "MonaspaceArgon-Regular", size: 13.5)
        ?? .monospacedSystemFont(ofSize: 13.5, weight: .regular)

    static let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 5
        style.paragraphSpacing = 2
        return style
    }()

    static let base: [NSAttributedString.Key: Any] = [.font: font(15.5), .foregroundColor: text, .paragraphStyle: paragraph]

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = [.anchorsMatchLines]) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let frontmatter = regex(#"\A---\n[\s\S]*?\n---(\n|\z)"#, [])
    private static let fence = regex(#"^```[^\n]*\n[\s\S]*?^```[ \t]*$"#)
    private static let heading = regex(#"^(#{1,6})[ \t]+.*$"#)
    private static let bold = regex(#"(\*\*|__)(?=\S)[^\n]+?(?<=\S)\1"#)
    private static let italic = regex(#"(?<![*\w])([*_])(?=\S)[^*_\n]+?(?<=\S)\1(?![*\w])"#)
    private static let strike = regex(#"~~[^\n]+?~~"#)
    private static let inlineCode = regex(#"`[^`\n]+`"#)
    private static let wikilink = regex(#"!?\[\[[^\]\n]+\]\]"#)
    private static let link = regex(#"!?\[([^\]\n]*)\]\(([^)\n]+)\)"#)
    private static let highlight = regex(#"==[^=\n]+=="#)
    private static let mathBlock = regex(#"\$\$[\s\S]+?\$\$"#, [])
    private static let mathInline = regex(#"(?<![\\$])\$(?=\S)[^$\n]+?(?<=\S)\$(?!\d)"#)
    private static let tag = regex(#"(?<=^|\s)#[\p{L}\p{N}_/-]*[\p{L}_/-][\p{L}\p{N}_/-]*"#)
    private static let quote = regex(#"^>.*$"#)
    private static let callout = regex(#"^>\s*\[![\w-]+\][+-]?"#)
    private static let listMarker = regex(#"^[ \t]*([-*+]|\d+[.)])[ \t]"#)
    private static let task = regex(#"^[ \t]*[-*+][ \t]\[[ xX/\-]\]"#)
    private static let rule = regex(#"^(\*{3,}|-{3,}|_{3,})[ \t]*$"#)

    static func apply(to storage: NSTextStorage) {
        let string = storage.string
        let whole = NSRange(location: 0, length: (string as NSString).length)
        guard whole.length < 400_000 else { return }
        storage.beginEditing()
        storage.setAttributes(base, range: whole)

        func each(_ expression: NSRegularExpression, _ body: (NSTextCheckingResult) -> Void) {
            expression.enumerateMatches(in: string, range: whole) { match, _, _ in if let match { body(match) } }
        }
        func color(_ range: NSRange, _ value: NSColor) { storage.addAttribute(.foregroundColor, value: value, range: range) }

        each(heading) { match in
            let level = match.range(at: 1).length
            let sizes: [CGFloat] = [27, 24, 21, 18.5, 17, 15.5]
            storage.addAttribute(.font, value: font(sizes[level - 1], level == 1 ? .bold : .semibold), range: match.range)
            color(NSRange(location: match.range.location, length: level), faint)
        }
        each(bold) { match in
            storage.addAttribute(.font, value: font(15.5, .semibold), range: match.range)
            color(NSRange(location: match.range.location, length: 2), faint)
            color(NSRange(location: NSMaxRange(match.range) - 2, length: 2), faint)
        }
        each(italic) { match in
            storage.addAttribute(.obliqueness, value: 0.16, range: match.range)
            color(NSRange(location: match.range.location, length: 1), faint)
            color(NSRange(location: NSMaxRange(match.range) - 1, length: 1), faint)
        }
        each(strike) { match in
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: match.range)
            color(match.range, muted)
        }
        each(highlight) { storage.addAttribute(.backgroundColor, value: NSColor(red: 1, green: 0.82, blue: 0, alpha: 0.22), range: $0.range) }
        each(quote) { color($0.range, muted) }
        each(callout) { match in
            storage.addAttribute(.font, value: font(15.5, .semibold), range: match.range)
            color(match.range, NSColor(red: 0.35, green: 0.6, blue: 0.95, alpha: 1))
        }
        each(listMarker) { color($0.range(at: 1), faint) }
        each(task) { color($0.range, accent) }
        each(rule) { color($0.range, faint) }
        each(tag) { color($0.range, accent) }
        each(link) { match in
            color(match.range, faint)
            color(match.range(at: 1), accent)
        }
        each(wikilink) { match in
            color(match.range, accent)
            color(NSRange(location: match.range.location, length: match.range.length > 4 && string[Range(match.range, in: string)!].hasPrefix("!") ? 3 : 2), faint)
            color(NSRange(location: NSMaxRange(match.range) - 2, length: 2), faint)
        }
        each(mathInline) { match in
            storage.addAttribute(.font, value: monoFont, range: match.range)
            color(match.range, math)
        }
        each(mathBlock) { match in
            storage.addAttribute(.font, value: monoFont, range: match.range)
            color(match.range, math)
        }
        each(inlineCode) { match in
            storage.addAttribute(.font, value: monoFont, range: match.range)
            storage.addAttribute(.backgroundColor, value: NSColor(white: 1, alpha: 0.05), range: match.range)
            color(match.range, code)
        }
        each(fence) { match in
            storage.addAttribute(.font, value: monoFont, range: match.range)
            color(match.range, muted)
            storage.removeAttribute(.obliqueness, range: match.range)
            storage.removeAttribute(.backgroundColor, range: match.range)
        }
        each(frontmatter) { match in
            storage.addAttribute(.font, value: monoFont, range: match.range)
            color(match.range, faint)
        }
        storage.endEditing()
    }
}

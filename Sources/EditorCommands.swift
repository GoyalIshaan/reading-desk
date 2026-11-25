import AppKit
import SwiftUI

/// One change to a note's text: swap `range` for `replacement`, then select `selection`.
/// Offsets are UTF-16, which is what both NSTextView and a web textarea count in.
struct TextEdit {
    let range: NSRange
    let replacement: String
    let selection: NSRange
}

/// Implemented by both note editors, so one Format menu drives whichever has focus.
@objc protocol FormattingEditor {
    func deskFormat(_ sender: Any?)
}

/// The Format menu's commands, written as Obsidian writes them.
enum TextFormat: String, CaseIterable, Identifiable {
    case bold, italic, underline, strikethrough, highlight, code, link

    var id: Self { self }

    var title: String {
        switch self {
        case .bold: "Bold"
        case .italic: "Italic"
        case .underline: "Underline"
        case .strikethrough: "Strikethrough"
        case .highlight: "Highlight"
        case .code: "Inline Code"
        case .link: "Add Link"
        }
    }

    var shortcut: KeyboardShortcut {
        switch self {
        case .bold: KeyboardShortcut("b")
        case .italic: KeyboardShortcut("i")
        case .underline: KeyboardShortcut("u")
        case .strikethrough: KeyboardShortcut("x", modifiers: [.command, .shift])
        case .highlight: KeyboardShortcut("h", modifiers: [.command, .shift])
        case .code: KeyboardShortcut("e", modifiers: [.command, .shift])
        case .link: KeyboardShortcut("k")
        }
    }

    /// Markdown has no underline, so it's the HTML tag, which the reading view renders.
    private var markers: (open: String, close: String) {
        switch self {
        case .bold: ("**", "**")
        case .italic: ("*", "*")
        case .underline: ("<u>", "</u>")
        case .strikethrough: ("~~", "~~")
        case .highlight: ("==", "==")
        case .code: ("`", "`")
        case .link: ("[", "]()")
        }
    }

    /// Ways this style may already be written; the first is the one we write.
    private var spellings: [(open: String, close: String)] {
        switch self {
        case .bold: [markers, ("__", "__")]
        case .italic: [markers, ("_", "_")]
        default: [markers]
        }
    }

    @MainActor func send() {
        let item = NSMenuItem()
        item.representedObject = rawValue
        NSApp.sendAction(#selector(FormattingEditor.deskFormat(_:)), to: nil, from: item)
    }

    static func from(_ sender: Any?) -> TextFormat? {
        ((sender as? NSMenuItem)?.representedObject as? String).flatMap(TextFormat.init(rawValue:))
    }

    func edit(_ text: String, selection: NSRange) -> TextEdit {
        let source = text as NSString
        if self == .link { return linkEdit(source, selection) }
        if selection.length > 0 { return toggle(source, selection) ?? TextEdit(range: selection, replacement: source.substring(with: selection), selection: selection) }

        // A bare caret styles the word it's in, and stays where it was in that word.
        let word = wordRange(source, at: selection.location)
        if word.length > 0, let edit = toggle(source, word) {
            let offset = selection.location - word.location
            return TextEdit(range: edit.range, replacement: edit.replacement,
                            selection: NSRange(location: edit.selection.location + min(offset, edit.selection.length), length: 0))
        }
        let (open, close) = markers
        let openLength = (open as NSString).length, closeLength = (close as NSString).length
        // Pressing the shortcut twice takes the empty pair back out.
        if selection.location >= openLength, selection.location + closeLength <= source.length,
           source.substring(with: NSRange(location: selection.location - openLength, length: openLength)) == open,
           source.substring(with: NSRange(location: selection.location, length: closeLength)) == close {
            let start = selection.location - openLength
            return TextEdit(range: NSRange(location: start, length: openLength + closeLength), replacement: "",
                            selection: NSRange(location: start, length: 0))
        }
        return TextEdit(range: selection, replacement: open + close,
                        selection: NSRange(location: selection.location + openLength, length: 0))
    }

    /// A stretch of one line to style: `outer` includes the markers if it already has them.
    private struct Segment {
        let outer: NSRange
        let inner: NSRange
        let marker: (open: String, close: String)?
    }

    private static let linePrefix = try! NSRegularExpression(
        pattern: #"^[ \t]*(?:(?:(?:[-*+]|\d+[.)])[ \t]+(?:\[.\][ \t]+)?)|#{1,6}[ \t]+|>[ \t]*)*"#)

    /// Inline Markdown doesn't span lines, so each selected line is styled on its own,
    /// leaving list bullets, checkboxes, heading hashes and quote marks outside.
    private func segments(_ source: NSString, _ selection: NSRange) -> [Segment] {
        var result: [Segment] = []
        var cursor = selection.location
        while cursor < NSMaxRange(selection) {
            let line = source.lineRange(for: NSRange(location: cursor, length: 0))
            var start = cursor
            var end = min(NSMaxRange(line), NSMaxRange(selection))
            cursor = NSMaxRange(line)
            let prefix = Self.linePrefix.rangeOfFirstMatch(in: source as String, range: NSRange(location: line.location, length: end - line.location))
            if prefix.location != NSNotFound { start = max(start, NSMaxRange(prefix)) }
            while start < end, isSpace(source.character(at: start)) { start += 1 }
            while end > start, isSpace(source.character(at: end - 1)) { end -= 1 }
            if start < end { result.append(segment(source, NSRange(location: start, length: end - start))) }
        }
        return result
    }

    private func segment(_ source: NSString, _ range: NSRange) -> Segment {
        for marker in spellings {
            let open = (marker.open as NSString).length, close = (marker.close as NSString).length
            // The selection may take in either marker, both or neither, so peel them off
            // its edges and then look around what's left.
            var start = range.location, end = NSMaxRange(range)
            if self == .bold || self == .italic {
                let character = (marker.open as NSString).character(at: 0)
                while start < end, source.character(at: start) == character { start += 1 }
                while end > start, source.character(at: end - 1) == character { end -= 1 }
            } else {
                if end - start >= open, source.substring(with: NSRange(location: start, length: open)) == marker.open { start += open }
                if end - start >= close, source.substring(with: NSRange(location: end - close, length: close)) == marker.close { end -= close }
            }
            let inner = NSRange(location: start, length: end - start)
            guard inner.length > 0, start >= open, end + close <= source.length else { continue }
            let outer = NSRange(location: start - open, length: inner.length + open + close)
            // "**a** and **b**" starts and ends with markers but isn't one bold run.
            if wraps(source, outer: outer, inner: inner, marker), self == .italic || !source.substring(with: inner).contains(marker.open) {
                return Segment(outer: outer, inner: inner, marker: marker)
            }
        }
        return Segment(outer: range, inner: range, marker: nil)
    }

    private func wraps(_ source: NSString, outer: NSRange, inner: NSRange, _ marker: (open: String, close: String)) -> Bool {
        let open = (marker.open as NSString).length, close = (marker.close as NSString).length
        guard source.substring(with: NSRange(location: outer.location, length: open)) == marker.open,
              source.substring(with: NSRange(location: NSMaxRange(outer) - close, length: close)) == marker.close else { return false }
        guard self == .bold || self == .italic else { return true }
        // `*` and `**` share a character: count the whole run to tell them apart.
        let character = (marker.open as NSString).character(at: 0)
        func run(from index: Int, step: Int) -> Int {
            var index = index, count = 0
            while index >= 0, index < source.length, source.character(at: index) == character { count += 1; index += step }
            return count
        }
        // Look both ways from each edge of the text, so either way of selecting counts the same.
        let before = run(from: inner.location - 1, step: -1) + run(from: inner.location, step: 1)
        let after = run(from: NSMaxRange(inner), step: 1) + run(from: NSMaxRange(inner) - 1, step: -1)
        let count = min(before, after)
        return self == .bold ? count >= 2 : count % 2 == 1
    }

    private func toggle(_ source: NSString, _ selection: NSRange) -> TextEdit? {
        let parts = segments(source, selection)
        guard !parts.isEmpty else { return nil }
        // All styled already: turn it off. Any unstyled: turn everything on.
        let removing = parts.allSatisfy { $0.marker != nil }
        let start = min(selection.location, parts[0].outer.location)
        let end = max(NSMaxRange(selection), NSMaxRange(parts[parts.count - 1].outer))
        let result = NSMutableString()
        var copied = start
        var first = 0, last = 0
        for (index, part) in parts.enumerated() {
            result.append(source.substring(with: NSRange(location: copied, length: max(0, part.outer.location - copied))))
            var body = source.substring(with: part.inner)
            let innerStart: Int
            if removing {
                innerStart = result.length
                result.append(body)
            } else if part.marker != nil {
                let whole = source.substring(with: part.outer) as NSString
                innerStart = result.length + part.inner.location - part.outer.location
                result.append(whole as String)
            } else {
                // Styled stretches inside the new one would only break it. (A lone `*` can't be told from bold.)
                if self != .italic { for marker in spellings { body = body.replacingOccurrences(of: marker.open, with: "").replacingOccurrences(of: marker.close, with: "") } }
                result.append(markers.open)
                innerStart = result.length
                result.append(body)
                result.append(markers.close)
            }
            if index == 0 { first = innerStart }
            last = innerStart + (body as NSString).length
            copied = NSMaxRange(part.outer)
        }
        if end > copied { result.append(source.substring(with: NSRange(location: copied, length: end - copied))) }
        return TextEdit(range: NSRange(location: start, length: end - start), replacement: result as String,
                        selection: NSRange(location: start + first, length: last - first))
    }

    private func linkEdit(_ source: NSString, _ selection: NSRange) -> TextEdit {
        let text = source.substring(with: selection)
        if text.range(of: #"^https?://\S+$"#, options: .regularExpression) != nil {
            return TextEdit(range: selection, replacement: "[](\(text))", selection: NSRange(location: selection.location + 1, length: 0))
        }
        // With text, the caret waits for the address; without, for the text.
        let caret = selection.length > 0 ? selection.location + selection.length + 3 : selection.location + 1
        return TextEdit(range: selection, replacement: "[\(text)]()", selection: NSRange(location: caret, length: 0))
    }

    private func wordRange(_ source: NSString, at caret: Int) -> NSRange {
        func isWord(_ index: Int) -> Bool {
            let range = source.rangeOfComposedCharacterSequence(at: index)
            return source.substring(with: range).unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "'" || $0 == "’" }
        }
        var start = caret, end = caret
        while start > 0, isWord(start - 1) { start = source.rangeOfComposedCharacterSequence(at: start - 1).location }
        while end < source.length, isWord(end) { end = NSMaxRange(source.rangeOfComposedCharacterSequence(at: end)) }
        return NSRange(location: start, length: end - start)
    }

    private func isSpace(_ character: unichar) -> Bool { character == 32 || character == 9 || character == 10 || character == 13 }
}

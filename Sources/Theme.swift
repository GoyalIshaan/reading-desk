import SwiftUI

/// Editorial dark: warm print-black, cream ink, one vermilion accent.
/// Type: EB Garamond for titles and navigation, Geist for interface text,
/// Monaspace Argon for small metadata. All three ship inside the app.
enum Theme {
    static let ground = Color(hex: 0x0E0D0B)
    static let surface = Color(hex: 0x151411)
    static let raised = Color(hex: 0x1D1C18)
    static let notes = Color(hex: 0x191816)
    static let rule = Color(hex: 0x2A2823)
    static let ink = Color(hex: 0xEDE7DB)
    static let ink2 = Color(hex: 0xB4AD9F)
    static let ink3 = Color(hex: 0x7D776C)
    static let ink4 = Color(hex: 0x524E47)
    static let accent = Color(hex: 0xEE5A3B)
    static let accentInk = Color(hex: 0x1A0B07)
    static let error = Color(hex: 0xF0806B)

    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular, italic: Bool = false) -> Font {
        let face: String
        switch weight {
        case .medium: face = italic ? "EBGaramond-MediumItalic" : "EBGaramond-Medium"
        case .semibold, .bold, .heavy, .black: face = italic ? "EBGaramond-SemiBoldItalic" : "EBGaramond-SemiBold"
        default: face = italic ? "EBGaramond-Italic" : "EBGaramond-Regular"
        }
        return .custom(face, size: size)
    }

    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Geist", size: size).weight(weight)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(weight == .regular ? "MonaspaceArgon-Regular" : "MonaspaceArgon-Medium", size: size)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

/// Solid vermilion for the one primary action on screen, hairline for the rest.
struct DeskButtonStyle: ButtonStyle {
    enum Kind { case primary, outline }
    var kind: Kind = .outline

    init(_ kind: Kind = .outline) { self.kind = kind }
    init(prominent: Bool) { kind = prominent ? .primary : .outline }

    func makeBody(configuration: Configuration) -> some View {
        Label(configuration: configuration, kind: kind)
    }

    private struct Label: View {
        let configuration: Configuration
        let kind: Kind
        @Environment(\.isEnabled) private var enabled
        @State private var hovered = false

        var body: some View {
            configuration.label
                .font(Theme.sans(12.5, .medium))
                .padding(.horizontal, 13)
                .frame(height: 30)
                .foregroundStyle(kind == .primary ? Theme.accentInk : (hovered ? Theme.ink : Theme.ink2))
                .background {
                    if kind == .primary {
                        Capsule().fill(hovered ? Theme.accent.opacity(0.92) : Theme.accent)
                    } else {
                        Capsule().strokeBorder(hovered ? Theme.ink3 : Theme.rule)
                    }
                }
                .contentShape(Capsule())
                .opacity(!enabled ? 0.35 : configuration.isPressed ? 0.7 : 1)
                .onHover { hovered = $0 }
                .animation(.easeOut(duration: 0.12), value: hovered)
        }
    }
}

/// A bare glyph button. No box, just ink that brightens on hover.
struct DeskIcon: View {
    let symbol: String
    let help: String
    var tint: Color? = nil
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled

    init(_ symbol: String, help: String, tint: Color? = nil, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .regular))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? (tint ?? (hovered ? Theme.ink : Theme.ink3)) : Theme.ink4)
        .onHover { hovered = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Plain text that acts as a link-style button.
struct TextAction: View {
    let title: String
    var systemImage: String?
    var trailing = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage, !trailing { Image(systemName: systemImage).font(.system(size: 10.5, weight: .medium)) }
                Text(title)
                if let systemImage, trailing { Image(systemName: systemImage).font(.system(size: 10.5, weight: .medium)) }
            }
            .font(Theme.sans(12.5, .medium))
            .foregroundStyle(hovered ? Theme.ink : Theme.ink2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// A round back arrow, used wherever there's somewhere to go back to.
struct BackButton: View {
    var help = "Back (⌘[)"
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.left")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(enabled ? (hovered ? Theme.ink : Theme.ink2) : Theme.ink4)
                .frame(width: 30, height: 30)
                .background(Circle().fill(hovered && enabled ? Theme.raised : .clear))
                .overlay(Circle().strokeBorder(hovered && enabled ? Theme.ink4 : Theme.rule))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
        .accessibilityLabel("Back")
    }
}

struct Hairline: View {
    var vertical = false
    var body: some View {
        Rectangle().fill(Theme.rule)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
            .accessibilityHidden(true)
    }
}

typealias SurfaceRule = Hairline

/// An invisible button that only exists to carry a keyboard shortcut.
struct ShortcutButton: View {
    let title: String
    let key: KeyEquivalent
    let modifiers: EventModifiers
    let action: () -> Void

    init(_ title: String, _ key: KeyEquivalent, _ modifiers: EventModifiers = .command, action: @escaping () -> Void) {
        self.title = title
        self.key = key
        self.modifiers = modifiers
        self.action = action
    }

    var body: some View {
        Button(title, action: action)
            .keyboardShortcut(key, modifiers: modifiers)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
    }
}

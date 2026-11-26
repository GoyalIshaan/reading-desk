import AppKit
import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor
final class AppearanceStore: ObservableObject {
    static let storageKey = "appearance"

    @Published var mode: AppAppearance {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.storageKey)
            apply()
        }
    }

    @Published private(set) var isDark: Bool
    private var observation: NSKeyValueObservation?

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.storageKey).flatMap(AppAppearance.init(rawValue:)) ?? .system
        self.mode = saved
        self.isDark = Self.resolveIsDark(mode: saved)
    }

    func start() {
        guard let app = NSApp else { return }
        apply()
        guard observation == nil else { return }
        observation = app.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.updateEffective() }
        }
    }

    func apply() {
        guard let app = NSApp else { return }
        let target = mode.nsAppearance
        app.appearance = target
        for window in app.windows {
            window.appearance = target
        }
        updateEffective()
    }

    func toggle() {
        mode = isDark ? .light : .dark
    }

    private func updateEffective() {
        let resolved = Self.resolveIsDark(mode: mode)
        if resolved != isDark { isDark = resolved }
    }

    private static func resolveIsDark(mode: AppAppearance) -> Bool {
        switch mode {
        case .light: false
        case .dark: true
        case .system:
            (NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()).bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }
}

/// Editorial light and dark palettes: warm paper or warm print-black,
/// deep charcoal or cream ink, and one vermilion accent.
/// Type: EB Garamond for titles and navigation, Geist for interface text,
/// Monaspace Argon for small metadata. All three ship inside the app.
enum Theme {
    private static func dynamicNS(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        }
    }

    private static func dynamic(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: dynamicNS(light: light, dark: dark, lightAlpha: lightAlpha, darkAlpha: darkAlpha))
    }

    static let nsGround = dynamicNS(light: 0xF6F3EC, dark: 0x0E0D0B)
    static let nsNotes = dynamicNS(light: 0xFAF8F4, dark: 0x191816)
    static let nsAccent = dynamicNS(light: 0xD44424, dark: 0xEE5A3B)

    static let ground = Color(nsColor: nsGround)
    static let surface = dynamic(light: 0xEEEAE0, dark: 0x151411)
    static let raised = dynamic(light: 0xE4DFD3, dark: 0x1D1C18)
    static let floating = dynamic(light: 0xFCFBF8, dark: 0x1D1C18)
    static let palette = dynamic(light: 0xFAF8F3, dark: 0x151411)
    static let notes = Color(nsColor: nsNotes)
    static let rule = dynamic(light: 0xDDD7CA, dark: 0x2A2823)
    static let ink = dynamic(light: 0x1D1B17, dark: 0xEDE7DB)
    static let inkStrong = dynamic(light: 0x0C0B09, dark: 0xFFFFFF)
    static let ink2 = dynamic(light: 0x4E4A42, dark: 0xB4AD9F)
    static let ink3 = dynamic(light: 0x756F64, dark: 0x7D776C)
    static let ink4 = dynamic(light: 0xA0998C, dark: 0x524E47)
    static let accent = Color(nsColor: nsAccent)
    static let accentInk = dynamic(light: 0xFFFDF9, dark: 0x1A0B07)
    static let error = dynamic(light: 0xC43822, dark: 0xF0806B)
    static let connected = dynamic(light: 0x2E8F53, dark: 0x6FCF8E)
    static let border = dynamic(light: 0x1D1B17, dark: 0xFFFFFF, lightAlpha: 0.09, darkAlpha: 0.06)
    static let borderHover = dynamic(light: 0x1D1B17, dark: 0xFFFFFF, lightAlpha: 0.20, darkAlpha: 0.14)
    static let borderFloating = dynamic(light: 0x1D1B17, dark: 0xFFFFFF, lightAlpha: 0.12, darkAlpha: 0.10)
    static let hoverWash = dynamic(light: 0x1D1B17, dark: 0xFFFFFF, lightAlpha: 0.06, darkAlpha: 0.06)
    static let paperLine = dynamic(light: 0x1D1B17, dark: 0xFFFFFF, lightAlpha: 0.045, darkAlpha: 0.025)
    static let scrim = dynamic(light: 0x181510, dark: 0x000000, lightAlpha: 0.24, darkAlpha: 0.50)
    static let shadow = dynamic(light: 0x1D1912, dark: 0x000000, lightAlpha: 0.15, darkAlpha: 0.48)
    static let imageVeil = dynamic(light: 0x1D1B17, dark: 0x0E0D0B, lightAlpha: 0.025, darkAlpha: 0.14)

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

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
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

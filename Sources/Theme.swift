import SwiftUI

enum Theme {
    static let paper = Color(red: 0.046, green: 0.052, blue: 0.066)
    static let panel = Color(red: 0.078, green: 0.086, blue: 0.108)
    static let raised = Color(red: 0.106, green: 0.118, blue: 0.145)
    static let line = Color(red: 0.171, green: 0.184, blue: 0.221)
    static let ink = Color(red: 0.927, green: 0.938, blue: 0.955)
    static let muted = Color(red: 0.634, green: 0.659, blue: 0.715)
    static let accent = Color(red: 0.771, green: 0.922, blue: 0.491)
    static let accentInk = Color(red: 0.080, green: 0.107, blue: 0.032)
    static let error = Color(red: 1.0, green: 0.66, blue: 0.60)

    static func display(_ size: CGFloat) -> Font {
        .custom("AvenirNext-DemiBold", size: size, relativeTo: .largeTitle)
    }
}

extension Shelf {
    var tint: Color {
        switch self {
        case .research: Theme.accent
        case .engineering: Color(red: 0.57, green: 0.77, blue: 1)
        case .learning: Color(red: 0.82, green: 0.70, blue: 1)
        case .ai: Color(red: 0.44, green: 0.86, blue: 0.77)
        case .writing: Color(red: 0.97, green: 0.74, blue: 0.56)
        case .media: Color(red: 0.99, green: 0.65, blue: 0.76)
        case .communication: Color(red: 0.91, green: 0.82, blue: 0.56)
        case .other: Color(red: 0.69, green: 0.72, blue: 0.79)
        }
    }
}

struct DeskButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        DeskButtonLabel(configuration: configuration, prominent: prominent)
    }

    private struct DeskButtonLabel: View {
        let configuration: Configuration
        let prominent: Bool
        @Environment(\.isEnabled) var enabled
        @State private var hovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 11)
                .frame(height: 30)
                .foregroundStyle(prominent ? Theme.accentInk : Theme.ink)
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(prominent ? Theme.accent : hovered ? Theme.raised : Theme.panel)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(prominent ? .clear : Theme.line)
                }
                .contentShape(Rectangle())
                .opacity(!enabled ? 0.45 : configuration.isPressed ? 0.72 : 1)
                .onHover { hovered = $0 }
        }
    }
}

struct DeskIcon: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled

    init(_ symbol: String, help: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(hovered && enabled ? Theme.raised : .clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Theme.ink : Theme.muted.opacity(0.55))
        .onHover { hovered = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

struct DeskMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9).fill(Theme.raised)
            RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.line)
            HStack(spacing: 2) {
                RoundedRectangle(cornerRadius: 1.5).fill(Theme.accent).frame(width: 8, height: 12)
                RoundedRectangle(cornerRadius: 1.5).strokeBorder(Theme.accent, lineWidth: 1.2).frame(width: 6, height: 12)
            }
        }
        .frame(width: 32, height: 32)
        .accessibilityHidden(true)
    }
}

struct SurfaceRule: View {
    var body: some View { Rectangle().fill(Theme.line).frame(height: 1).accessibilityHidden(true) }
}

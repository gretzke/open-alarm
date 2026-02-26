import SwiftUI

enum OAColor {
    static let background = Color.black
    static let textPrimary = Color(red: 245 / 255, green: 245 / 255, blue: 247 / 255)
    static let textSecondary = Color(red: 142 / 255, green: 142 / 255, blue: 147 / 255)

    static let brandCyan = Color(red: 133 / 255, green: 217 / 255, blue: 231 / 255)
    static let actionCyan = Color(red: 100 / 255, green: 210 / 255, blue: 255 / 255)
    static let actionCyanActive = Color(red: 50 / 255, green: 197 / 255, blue: 255 / 255)

    static let danger = Color(red: 255 / 255, green: 69 / 255, blue: 58 / 255)

    static let glassFill = Color.white.opacity(0.08)
    static let glassStroke = Color(red: 133 / 255, green: 217 / 255, blue: 231 / 255).opacity(0.22)
    static let glassGlow = Color(red: 100 / 255, green: 210 / 255, blue: 255 / 255).opacity(0.20)
}

enum OARadius {
    static let card: CGFloat = 24
    static let button: CGFloat = 20
    static let chip: CGFloat = 14
}

struct OAGlassCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: OARadius.card, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: OARadius.card, style: .continuous)
                    .stroke(OAColor.glassStroke, lineWidth: 1)
            )
            .shadow(color: OAColor.glassGlow.opacity(0.65), radius: 14, x: 0, y: 8)
    }
}

private struct OAGlassPanelModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(OAColor.glassStroke.opacity(0.75), lineWidth: 0.8)
            )
    }
}

private struct OAGlassButtonChromeModifier: ViewModifier {
    let tint: Color?
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        Group {
            if let tint {
                content.glassEffect(
                    .regular.tint(tint).interactive(),
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
            } else {
                content.glassEffect(
                    .regular.interactive(),
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(OAColor.glassStroke.opacity(0.75), lineWidth: 0.8)
        )
    }
}

extension View {
    func oaGlassCard() -> some View {
        modifier(OAGlassCardModifier())
    }

    func oaGlassPanel(cornerRadius: CGFloat = OARadius.button) -> some View {
        modifier(OAGlassPanelModifier(cornerRadius: cornerRadius))
    }

    func oaGlassButtonChrome(cornerRadius: CGFloat = OARadius.button) -> some View {
        modifier(OAGlassButtonChromeModifier(tint: nil, cornerRadius: cornerRadius))
    }

    func oaGlassProminentButtonChrome(_ tint: Color = OAColor.actionCyan, cornerRadius: CGFloat = OARadius.button) -> some View {
        modifier(OAGlassButtonChromeModifier(tint: tint.opacity(0.28), cornerRadius: cornerRadius))
    }
}

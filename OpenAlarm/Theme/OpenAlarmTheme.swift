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

enum OASpacing {
    /// Base scale — prefer these over raw literals for structural spacing.
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24

    /// Semantic values.
    static let cardPadding: CGFloat = 20     // inner padding of glass cards
    static let screenMargin: CGFloat = 20    // horizontal screen edge
    static let onboardingMargin: CGFloat = 24
}

enum OASize {
    static let controlHeight: CGFloat = 52   // primary action buttons
    static let rowHeight: CGFloat = 48       // tappable list/settings rows
    static let minTouchTarget: CGFloat = 44
}

enum OAType {
    /// Screen header ("Alarms"). Scales with Dynamic Type.
    static let screenTitle = Font.system(.largeTitle, design: .rounded, weight: .bold)
    /// Card/section heading.
    static let cardTitle = Font.headline.weight(.semibold)
    /// Section label inside editors (currently `.headline` on textSecondary).
    static let sectionLabel = Font.headline
    /// Primary button label.
    static let buttonLabel = Font.headline.weight(.semibold)
    /// Row value / trailing detail.
    static let rowValue = Font.body.weight(.medium)
    /// Caption metadata.
    static let meta = Font.caption
    static let metaEmphasis = Font.caption.weight(.semibold)
    /// Big numeric displays (time, countdown). Size comes from a @ScaledMetric in the view.
    static func display(_ size: CGFloat) -> Font {
        .system(size: size, weight: .bold, design: .rounded)
    }
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

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    func body(content: Content) -> some View {
        Group {
            if let tint {
                content.glassEffect(
                    .regular.tint(tint).interactive(),
                    in: shape
                )
            } else {
                content.glassEffect(
                    .regular.interactive(),
                    in: shape
                )
            }
        }
        .overlay(
            shape
                .stroke(OAColor.glassStroke.opacity(0.75), lineWidth: 0.8)
        )
        // Guardrail: any control that uses this chrome should remain tappable across the full rendered surface.
        .contentShape(shape)
    }
}

struct GlassButtonWithAccentBorderStyle: ButtonStyle {
    var accentColor: Color = OAColor.actionCyan
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .oaGlassButtonChrome()
            .opacity(configuration.isPressed ? 0.7 : 1.0)
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
extension ButtonStyle where Self == GlassButtonWithAccentBorderStyle {
    static var glassAccentBorder: GlassButtonWithAccentBorderStyle {
        GlassButtonWithAccentBorderStyle()
    }
}

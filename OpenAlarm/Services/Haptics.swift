import UIKit

@MainActor
enum Haptics {
    private static let selectionGenerator = preparedSelectionGenerator()
    private static let lightImpactGenerator = preparedImpactGenerator(.light)
    private static let mediumImpactGenerator = preparedImpactGenerator(.medium)
    private static let heavyImpactGenerator = preparedImpactGenerator(.heavy)
    private static let rigidImpactGenerator = preparedImpactGenerator(.rigid)
    private static let softImpactGenerator = preparedImpactGenerator(.soft)
    private static let notificationGenerator = preparedNotificationGenerator()

    static func selection() {
        selectionGenerator.selectionChanged()
        selectionGenerator.prepare()
    }

    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        let generator = impactGenerator(for: style)
        generator.impactOccurred()
        generator.prepare()
    }

    static func success() {
        notificationGenerator.notificationOccurred(.success)
        notificationGenerator.prepare()
    }

    static func error() {
        notificationGenerator.notificationOccurred(.error)
        notificationGenerator.prepare()
    }

    private static func impactGenerator(for style: UIImpactFeedbackGenerator.FeedbackStyle) -> UIImpactFeedbackGenerator {
        switch style {
        case .light:
            lightImpactGenerator
        case .medium:
            mediumImpactGenerator
        case .heavy:
            heavyImpactGenerator
        case .rigid:
            rigidImpactGenerator
        case .soft:
            softImpactGenerator
        @unknown default:
            lightImpactGenerator
        }
    }

    private static func preparedSelectionGenerator() -> UISelectionFeedbackGenerator {
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        return generator
    }

    private static func preparedImpactGenerator(_ style: UIImpactFeedbackGenerator.FeedbackStyle) -> UIImpactFeedbackGenerator {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        return generator
    }

    private static func preparedNotificationGenerator() -> UINotificationFeedbackGenerator {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        return generator
    }
}

import Foundation

/// The small, intentional catalog exposed by the scan-object task. These IDs
/// are Vision classification identifiers, not localized display strings.
struct ScanObjectCatalog {
    struct Entry: Equatable, Identifiable {
        let id: String
        let systemImage: String
    }

    /// Verified against `VNClassifyImageRequest` revision 2's taxonomy.
    static let entries: [Entry] = [
        .init(id: "mug", systemImage: "mug.fill"),
        .init(id: "backpack", systemImage: "backpack.fill"),
        .init(id: "laptop", systemImage: "laptopcomputer"),
        .init(id: "computer_keyboard", systemImage: "keyboard"),
        .init(id: "refrigerator", systemImage: "refrigerator.fill"),
        .init(id: "kitchen_sink", systemImage: "sink.fill"),
        .init(id: "toilet_seat", systemImage: "toilet.fill"),
        .init(id: "shoes", systemImage: "shoe.2.fill"),
    ]

    static func entry(for id: String) -> Entry? {
        entries.first { $0.id == id }
    }
}

/// Decides whether a single classification frame counts as seeing the target.
///
/// Absolute Vision confidences run low in real cluttered scenes — a clearly
/// visible object can score under 0.05 — so the target's rank among all
/// classes is the primary signal, with a small confidence floor to reject
/// frames where the classifier is guessing across the board.
enum ScanMatchPolicy {
    static let requiredConsecutiveMatches = 4

    static func isMatch(rank: Int?, confidence: Double) -> Bool {
        if confidence >= 0.15 {
            return true
        }
        guard let rank else {
            return false
        }
        return rank <= 3 && confidence >= 0.02
    }
}

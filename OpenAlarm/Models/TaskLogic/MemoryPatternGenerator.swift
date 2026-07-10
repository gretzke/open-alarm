import Foundation

/// Pure, seedable generator for the visual memory task.
struct MemoryPatternGenerator {
    struct Spec: Equatable {
        let gridSize: Int
        let patternCount: Int
        let flashSeconds: Double
    }

    static func spec(difficulty: Int) -> Spec {
        switch min(max(difficulty, 1), 5) {
        case 1:
            Spec(gridSize: 3, patternCount: 3, flashSeconds: 1.2)
        case 2:
            Spec(gridSize: 3, patternCount: 4, flashSeconds: 1.1)
        case 3:
            Spec(gridSize: 4, patternCount: 5, flashSeconds: 1.0)
        case 4:
            Spec(gridSize: 4, patternCount: 7, flashSeconds: 0.9)
        default:
            Spec(gridSize: 5, patternCount: 8, flashSeconds: 0.8)
        }
    }

    static func patternSet(
        spec: Spec,
        excluding previous: Set<Int> = [],
        using rng: inout some RandomNumberGenerator
    ) -> Set<Int> {
        let cellCount = spec.gridSize * spec.gridSize
        precondition(spec.gridSize >= 2, "Memory patterns require at least a 2×2 grid")
        precondition((1...cellCount).contains(spec.patternCount), "Pattern count must fit in the grid")

        var cells = Array(0..<cellCount)
        for index in 0..<spec.patternCount {
            let selectedIndex = Int.random(in: index..<cellCount, using: &rng)
            cells.swapAt(index, selectedIndex)
        }

        var result = Set(cells.prefix(spec.patternCount))
        guard result == previous, spec.patternCount < cellCount else {
            return result
        }

        let member = result.sorted()[Int.random(in: 0..<spec.patternCount, using: &rng)]
        let nonMembers = cells.filter { !result.contains($0) }
        let replacement = nonMembers[Int.random(in: 0..<nonMembers.count, using: &rng)]
        result.remove(member)
        result.insert(replacement)
        return result
    }
}

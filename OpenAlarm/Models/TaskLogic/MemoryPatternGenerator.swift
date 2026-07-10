import Foundation

/// Pure, seedable generator for the visual memory task.
struct MemoryPatternGenerator {
    struct Spec: Equatable {
        let gridSize: Int
        let patternLength: Int
        let flashSeconds: Double
    }

    static func spec(difficulty: Int) -> Spec {
        switch min(max(difficulty, 1), 5) {
        case 1:
            Spec(gridSize: 3, patternLength: 3, flashSeconds: 0.60)
        case 2:
            Spec(gridSize: 3, patternLength: 4, flashSeconds: 0.54)
        case 3:
            Spec(gridSize: 4, patternLength: 5, flashSeconds: 0.47)
        case 4:
            Spec(gridSize: 4, patternLength: 6, flashSeconds: 0.41)
        default:
            Spec(gridSize: 5, patternLength: 7, flashSeconds: 0.35)
        }
    }

    static func pattern(spec: Spec, using rng: inout some RandomNumberGenerator) -> [Int] {
        let cellCount = spec.gridSize * spec.gridSize
        precondition(cellCount > 1, "Memory patterns require at least two grid cells")
        precondition(spec.patternLength >= 0, "Memory patterns cannot have a negative length")

        var result: [Int] = []
        result.reserveCapacity(spec.patternLength)

        for _ in 0..<spec.patternLength {
            if let previous = result.last {
                // Draw from the remaining cells directly rather than retrying,
                // which keeps generation finite even for a degenerate RNG.
                let candidate = Int.random(in: 0..<(cellCount - 1), using: &rng)
                result.append(candidate >= previous ? candidate + 1 : candidate)
            } else {
                result.append(Int.random(in: 0..<cellCount, using: &rng))
            }
        }

        return result
    }
}

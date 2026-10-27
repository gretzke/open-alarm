import Foundation

/// A single readable pane for full-screen content. Backgrounds can span the fold.
enum FoldContentRegion {
    static func frame(in bounds: CGRect, divisions: [CGRect], occlusions: [CGRect]) -> CGRect {
        var candidates = [bounds]
        for region in divisions + occlusions {
            let cut = region.intersection(bounds)
            guard !cut.isNull, cut.width > 0, cut.height > 0 else { continue }
            candidates = candidates.flatMap { candidate -> [CGRect] in
                let overlap = candidate.intersection(cut)
                guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { return [candidate] }
                return [
                    CGRect(x: candidate.minX, y: candidate.minY, width: candidate.width, height: overlap.minY - candidate.minY),
                    CGRect(x: candidate.minX, y: overlap.maxY, width: candidate.width, height: candidate.maxY - overlap.maxY),
                    CGRect(x: candidate.minX, y: candidate.minY, width: overlap.minX - candidate.minX, height: candidate.height),
                    CGRect(x: overlap.maxX, y: candidate.minY, width: candidate.maxX - overlap.maxX, height: candidate.height)
                ].filter { $0.width > 0 && $0.height > 0 }
            }
        }

        // Prefer the upright, upper pane for a horizontal partial fold.
        if let fold = divisions.first(where: {
            $0.width >= bounds.width * 0.8 && $0.height > 0 && $0.minY > bounds.minY && $0.maxY < bounds.maxY
        }) {
            let upper = candidates.filter { $0.maxY <= fold.minY }
            if let largest = largest(in: upper) { return largest }
        }
        return largest(in: candidates) ?? .zero
    }

    private static func largest(in frames: [CGRect]) -> CGRect? {
        frames.max { $0.width * $0.height < $1.width * $1.height }
    }
}

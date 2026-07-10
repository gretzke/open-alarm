import Foundation

/// Deterministic, sensor-agnostic shake progress model.
///
/// Motion collection stays in the app target so this model remains available to
/// the Foundation-only scheduling core and can be tested without Core Motion.
struct ShakeEnergyModel {
    let intensity: Int
    let threshold: Double
    let goal: Double

    private var energy: Double = 0
    private(set) var isComplete = false

    init(intensity: Int) {
        let clampedIntensity = min(max(intensity, 1), 5)
        self.intensity = clampedIntensity
        threshold = 0.8 + 0.3 * Double(clampedIntensity - 1)
        goal = 1.2 + 0.9 * Double(clampedIntensity - 1)
    }

    mutating func ingest(magnitude: Double, dt: Double) {
        let duration = max(dt, 0)
        guard duration > 0 else {
            return
        }

        if magnitude > threshold {
            energy += (magnitude - threshold) * duration
        } else {
            energy -= goal * 0.04 * duration
        }

        energy = max(energy, 0)
        if energy >= goal {
            isComplete = true
        }
    }

    var progress: Double {
        min(max(energy / goal, 0), 1)
    }
}

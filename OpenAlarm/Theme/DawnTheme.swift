import SwiftUI

enum DawnPalette {
    static let stops: [Color] = stopComponents.map {
        Color(red: $0.red, green: $0.green, blue: $0.blue)
    }

    static let inkDark = Color(red: 0x20 / 255, green: 0x10 / 255, blue: 0x05 / 255)

    /// progress 0...1 → top/bottom gradient colors interpolated across stops.
    /// The top trails the horizon (0.55×) so the upper screen region — where the
    /// display text sits — stays dark enough for white ink until the 0.75 flip,
    /// matching the approved mockup where the sky brightens from the bottom up.
    static func sky(progress: Double) -> LinearGradient {
        let progress = clamped(progress)

        return LinearGradient(
            colors: [
                interpolatedColor(progress: progress * 0.55),
                interpolatedColor(progress: min(progress + 0.25, 1))
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// ink flips white → inkDark once progress passes 0.75 (the gold stop)
    static func ink(progress: Double) -> Color {
        progress > 0.75 ? inkDark : .white
    }

    private static let stopComponents: [(red: Double, green: Double, blue: Double)] = [
        (0x1c / 255, 0x0b / 255, 0x38 / 255),
        (0xb4 / 255, 0x1f / 255, 0x1f / 255),
        (0xff / 255, 0x9e / 255, 0x1f / 255),
        (0xff / 255, 0xd8 / 255, 0x4d / 255),
        (0xff / 255, 0xf3 / 255, 0xcf / 255)
    ]

    private static func interpolatedColor(progress: Double) -> Color {
        let segment = clamped(progress) * 4
        let lowerIndex = min(Int(segment), stopComponents.count - 2)
        let fraction = segment - Double(lowerIndex)
        let lower = stopComponents[lowerIndex]
        let upper = stopComponents[lowerIndex + 1]

        return Color(
            red: lerp(lower.red, upper.red, fraction),
            green: lerp(lower.green, upper.green, fraction),
            blue: lerp(lower.blue, upper.blue, fraction)
        )
    }

    private static func lerp(_ start: Double, _ end: Double, _ progress: Double) -> Double {
        start + (end - start) * progress
    }

    private static func clamped(_ progress: Double) -> Double {
        min(max(progress, 0), 1)
    }
}

enum OADawnType {
    static func display(_ size: CGFloat) -> Font {
        .system(size: size, weight: .black, design: .rounded)
    }

    static let button = Font.system(.headline, design: .rounded, weight: .heavy)
    static let chip = Font.system(.caption, design: .rounded, weight: .bold).uppercaseSmallCaps()
}

struct SunView: View {
    private let progress: Double

    init(progress: Double) {
        self.progress = min(max(progress, 0), 1)
    }

    var body: some View {
        GeometryReader { geometry in
            let size = 96 + 128 * progress
            let centerY = geometry.size.height * (1.15 - 0.82 * progress)
            let brightness = 0.45 + 0.55 * progress

            RadialGradient(
                colors: [
                    Color.white.opacity(brightness),
                    Color(red: 1, green: 0.84, blue: 0.30).opacity(0.9 * brightness),
                    Color(red: 1, green: 0.62, blue: 0.12).opacity(0.25 * brightness),
                    .clear
                ],
                center: .center,
                startRadius: 0,
                endRadius: size / 2
            )
            .frame(width: size, height: size)
            .position(x: geometry.size.width / 2, y: centerY)
        }
        .accessibilityHidden(true)
    }
}

struct DawnBackground: View {
    private let progress: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(progress: Double) {
        self.progress = min(max(progress, 0), 1)
    }

    var body: some View {
        ZStack {
            DawnPalette.sky(progress: progress)
            SunView(progress: progress)
        }
        .ignoresSafeArea()
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: progress)
    }
}

/// Progress mapping helper (spec section 4): dismiss 0.0, N tasks divide 0.1...0.85, wake check 1.0.
/// `within` is the current task's own 0...1 progress (from TaskEvent.progress) and
/// interpolates INSIDE that task's slice — this is how the sun visibly rises DURING a task.
enum DawnProgress {
    static func forTask(index: Int, of total: Int, within: Double) -> Double {
        guard total > 0 else {
            return dismiss
        }

        let taskIndex = min(max(index, 0), total - 1)
        let taskSlice = (0.85 - 0.1) / Double(total)
        let taskProgress = min(max(within, 0), 1)

        return 0.1 + Double(taskIndex) * taskSlice + taskProgress * taskSlice
    }

    static let dismiss: Double = 0.0
    static let wakeCheck: Double = 1.0
}

#Preview {
    @Previewable @State var progress = 0.0

    ZStack {
        DawnBackground(progress: progress)

        VStack(spacing: OASpacing.m) {
            Text("Dawn theme")
                .font(OADawnType.display(36))
                .foregroundStyle(DawnPalette.ink(progress: progress))

            Slider(value: $progress, in: 0...1)
                .tint(DawnPalette.ink(progress: progress))
                .padding(OASpacing.xl)
                .background(.black.opacity(0.16), in: Capsule())
        }
        .padding(OASpacing.xxl)
    }
}

import SwiftUI

enum TaskSuccessPresentation {
    static let duration: Duration = .milliseconds(1_200)
}

enum TaskRoundSuccessPresentation {
    static let duration: Duration = .milliseconds(850)
}

struct TaskSuccessOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ringProgress = 0.0
    @State private var checkmarkScale = 0.65

    var body: some View {
        ZStack {
            Color.black.opacity(0.22)

            VStack(spacing: OASpacing.m) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.18))

                    Circle()
                        .trim(from: 0, to: ringProgress)
                        .stroke(
                            Color.white,
                            style: StrokeStyle(lineWidth: 5, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))

                    Image(systemName: "checkmark")
                        .font(.system(size: 46, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .scaleEffect(checkmarkScale)
                }
                .frame(width: 112, height: 112)

                Text(L10n.taskSuccessTitle)
                    .font(OADawnType.button)
                    .foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .onAppear {
            if reduceMotion {
                ringProgress = 1
                checkmarkScale = 1
            } else {
                withAnimation(.easeOut(duration: 0.42)) {
                    ringProgress = 1
                }
                withAnimation(.spring(response: 0.38, dampingFraction: 0.62)) {
                    checkmarkScale = 1
                }
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.92)))
    }
}

struct TaskRoundSuccessEffect: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isBursting = false
    @State private var checkmarkScale = 0.55

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(Self.particles) { particle in
                    ConfettiPiece(style: particle.style)
                        .fill(Self.colors[particle.colorIndex])
                        .frame(width: particle.width, height: particle.height)
                        .rotationEffect(.degrees(isBursting ? particle.rotation : 0))
                        .scaleEffect(isBursting ? 1 : 0.25)
                        .offset(
                            x: isBursting ? particle.xOffset : 0,
                            y: isBursting ? particle.yOffset : 0
                        )
                        .opacity(isBursting ? 0 : 1)
                }

                Image(systemName: "checkmark")
                    .font(.system(size: 42, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 88, height: 88)
                    .glassEffect(.regular, in: Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.55), lineWidth: 2))
                    .scaleEffect(checkmarkScale)
            }
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            if reduceMotion {
                isBursting = true
                checkmarkScale = 1
            } else {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.58)) {
                    checkmarkScale = 1
                }
                withAnimation(.easeOut(duration: 0.78)) {
                    isBursting = true
                }
            }
        }
        .transition(.opacity)
    }

    private static let colors: [Color] = [
        .white,
        OAColor.actionCyan,
        Color(red: 1, green: 0.84, blue: 0.30),
        Color(red: 1, green: 0.45, blue: 0.35),
        Color(red: 0.94, green: 0.42, blue: 0.78)
    ]

    private static let particles: [ConfettiParticle] = (0..<24).map { index in
        let angle = Double(index) / 24 * Double.pi * 2 - Double.pi / 2
        let distance = Double(82 + (index % 5) * 14)

        return ConfettiParticle(
            id: index,
            style: ConfettiStyle.allCases[index % ConfettiStyle.allCases.count],
            colorIndex: index % colors.count,
            width: index.isMultiple(of: 3) ? 8 : 11,
            height: index.isMultiple(of: 3) ? 18 : 10,
            xOffset: cos(angle) * distance,
            yOffset: sin(angle) * distance + 28,
            rotation: Double(180 + (index * 47) % 300)
        )
    }
}

private struct ConfettiParticle: Identifiable {
    let id: Int
    let style: ConfettiStyle
    let colorIndex: Int
    let width: CGFloat
    let height: CGFloat
    let xOffset: CGFloat
    let yOffset: CGFloat
    let rotation: Double
}

private enum ConfettiStyle: CaseIterable {
    case capsule
    case circle
    case diamond
}

private struct ConfettiPiece: Shape {
    let style: ConfettiStyle

    func path(in rect: CGRect) -> Path {
        switch style {
        case .capsule:
            return Capsule().path(in: rect)
        case .circle:
            return Circle().path(in: rect)
        case .diamond:
            var path = Path()
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.closeSubpath()
            return path
        }
    }
}

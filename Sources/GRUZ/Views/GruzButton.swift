import SwiftUI

/// The main call to action: opens the review sheet for the selected items.
///
/// It only opens the review; nothing is removed before the user confirms there. While the
/// pointer is over the enabled button, and briefly when the first item gets selected, the
/// bulldozer rumbles and pushes a few pieces of rubble. Reduce Motion keeps it still.
struct GruzButton: View {
    var isEnabled: Bool
    var action: () -> Void

    @State private var isHovering = false
    @State private var isRevving = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                BulldozerIcon(isWorking: isEnabled && (isHovering || isRevving))
                    .frame(width: 30, height: 16)
                Text("GRUZ it!")
                    .fontWeight(.semibold)
            }
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
        .disabled(!isEnabled)
        .onHover { isHovering = $0 }
        .help("Review the selected items. Nothing is removed until you confirm.")
        .accessibilityHint("Opens the review of the selected items. Nothing is removed until you confirm.")
        .task(id: isEnabled) {
            guard isEnabled else { return }
            isRevving = true
            try? await Task.sleep(for: .seconds(1.6))
            isRevving = false
        }
    }
}

/// A bulldozer with rubble ahead of its blade, drawn from shapes so it scales and takes the button's color.
struct BulldozerIcon: View {
    var isWorking: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One push of the rubble, in seconds.
    private let cycle = 0.9

    var body: some View {
        TimelineView(.animation(paused: !isWorking || reduceMotion)) { context in
            let animate = isWorking && !reduceMotion
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = animate ? (t.truncatingRemainder(dividingBy: cycle)) / cycle : 0
            // Engine rumble: a fast, tiny vertical shake.
            let rumble = animate ? sin(t * 70) * 0.45 : 0
            // The machine creeps forward during a push and rolls back at the end of the cycle.
            let creep = animate ? 2.5 * sin(phase * .pi) : 0

            GeometryReader { geometry in
                let height = geometry.size.height
                let machineWidth = height * 1.3
                ZStack(alignment: .leading) {
                    Rubble(phase: phase, isMoving: animate)
                        .frame(width: geometry.size.width - machineWidth - 1, height: height)
                        .offset(x: machineWidth + 1 + creep)
                    BulldozerShape()
                        .fill(style: FillStyle(eoFill: true))
                        .frame(width: machineWidth, height: height)
                        .offset(x: creep, y: rumble)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Three pieces of rubble that slide away from the blade and fade out during a push.
private struct Rubble: View {
    var phase: Double
    var isMoving: Bool

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let pieces: [(start: Double, y: Double, scale: Double, delay: Double)] = [
                (0.22, 0.80, 0.30, 0.00),
                (0.50, 0.66, 0.22, 0.15),
                (0.62, 0.90, 0.18, 0.30),
            ]
            ForEach(pieces.indices, id: \.self) { index in
                let piece = pieces[index]
                let progress = isMoving ? max(0, min(1, (phase - piece.delay) / (1 - piece.delay))) : 0
                let side = size.height * piece.scale
                RoundedRectangle(cornerRadius: side * 0.25)
                    .frame(width: side, height: side)
                    .rotationEffect(.degrees(progress * 160))
                    .position(
                        x: size.width * (piece.start + progress * 0.9),
                        y: size.height * piece.y - sin(progress * .pi) * size.height * 0.18
                    )
                    .opacity(isMoving ? 1 - progress * progress : 1)
            }
        }
    }
}

/// Side view of a bulldozer, facing right. Holes (cab window, track wheels) need an even-odd fill.
struct BulldozerShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: rect.minX + x * w, y: rect.minY + y * h) }
        func box(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> CGRect {
            CGRect(origin: point(x0, y0), size: CGSize(width: (x1 - x0) * w, height: (y1 - y0) * h))
        }

        var path = Path()
        // Track with three wheel holes.
        let track = box(0.02, 0.64, 0.74, 0.98)
        path.addRoundedRect(in: track, cornerSize: CGSize(width: track.height / 2, height: track.height / 2))
        for x in [0.15, 0.38, 0.61] {
            let r = 0.075
            path.addEllipse(in: box(x - r, 0.81 - r * w / h, x + r, 0.81 + r * w / h))
        }
        // Body and cab with a window.
        path.addRect(box(0.08, 0.38, 0.66, 0.64))
        path.addRoundedRect(in: box(0.14, 0.06, 0.48, 0.38), cornerSize: CGSize(width: w * 0.04, height: w * 0.04))
        path.addRect(box(0.21, 0.13, 0.41, 0.31))
        // Exhaust pipe.
        path.addRect(box(0.55, 0.14, 0.60, 0.38))
        // Arm to the blade.
        path.addRect(box(0.66, 0.50, 0.82, 0.58))
        // Blade, curved like a real moldboard: thin at the top, flaring towards the ground.
        path.move(to: point(0.82, 0.26))
        path.addLine(to: point(0.90, 0.26))
        path.addQuadCurve(to: point(1.00, 1.00), control: point(0.88, 0.80))
        path.addLine(to: point(0.82, 1.00))
        path.closeSubpath()
        return path
    }
}

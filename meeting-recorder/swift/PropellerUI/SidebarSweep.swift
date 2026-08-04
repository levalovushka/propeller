import SwiftUI

extension EnvironmentValues {
    /// Park the processing sweep at the pose the comps drew instead of running it.
    ///
    /// Only the state gallery sets this. A screenshot of a moving gradient
    /// catches it wherever the pass happened to be, so the same board exported
    /// twice differs — which is exactly the "is this a real change?" question
    /// the gallery exists to answer, asked of the gallery itself.
    public var sidebarSweepFrozen: Bool {
        get { self[SidebarSweepFrozenKey.self] }
        set { self[SidebarSweepFrozenKey.self] = newValue }
    }
}

private struct SidebarSweepFrozenKey: EnvironmentKey {
    static let defaultValue = false
}

/// A band of light travelling across whatever it is masked to.
///
/// This is the processing state of a meeting row, and it is a *gradient*, not a
/// spinner, on purpose: the row already says what is happening in words
/// («Расшифровываем…»), so the motion only has to answer "is this alive". A
/// spinner in a 276 pt rail would be the loudest thing on screen for the whole
/// minute the work takes.
///
/// # The geometry is Figma's, exactly
///
/// The comps freeze the sweep mid-pass: a linear gradient at 113.913° with
/// stops at 29.643 % (clear), 43.876 % (white 75 %) and 58.108 % (clear). Those
/// numbers are `Tokens.Sidebar.shimmer*`, and at `travel == 0` this view draws
/// that frame pixel-for-pixel — which is what makes it checkable against the
/// design instead of "about right".
///
/// CSS states a gradient by angle; SwiftUI wants two `UnitPoint`s. Converting
/// between them needs the box's real aspect ratio, so the endpoints are computed
/// per size rather than guessed — a 45° gradient on a 276 × 16 row is not the
/// same line as a 45° gradient on a 276 × 48 one, and eyeballing `.topLeading`
/// to `.bottomTrailing` gets it wrong by 60°.
public struct SidebarSweep: View {
    private let angle: Double
    private let peak: Color
    private let period: Double
    private let halfWidth: Double
    private let center: Double

    /// How far the gradient line is pushed along its own direction, as a
    /// fraction of its length. 0 is the frame Figma drew.
    @State private var travel: Double
    @State private var pulse: Double = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.sidebarSweepFrozen) private var frozen

    public init(
        angle: Double = Tokens.Sidebar.shimmerAngle,
        peak: Color = Tokens.Sidebar.shimmerPeak,
        period: Double = Tokens.Sidebar.shimmerPeriod,
        halfWidth: Double = Tokens.Sidebar.shimmerHalfWidth,
        center: Double = Tokens.Sidebar.shimmerCenter
    ) {
        self.angle = angle
        self.peak = peak
        self.period = period
        self.halfWidth = halfWidth
        self.center = center
        _travel = State(initialValue: -halfWidth - center)
    }

    /// Band centre enters at the leading edge and leaves past the trailing one.
    private var travelStart: Double { -halfWidth - center }
    private var travelEnd: Double { 1 + halfWidth - center }

    /// Still at the pose Figma drew, rather than wherever the pass happened to
    /// be when the shutter opened.
    private var isStill: Bool { frozen || reduceMotion }

    public var body: some View {
        GeometryReader { geo in
            let line = Self.gradientLine(angle: angle, size: geo.size, travel: isStill ? 0 : travel)
            LinearGradient(
                stops: [
                    .init(color: peak.opacity(0), location: center - halfWidth),
                    .init(color: peak, location: center),
                    .init(color: peak.opacity(0), location: center + halfWidth),
                ],
                startPoint: line.start,
                endPoint: line.end
            )
        }
        .opacity(reduceMotion && !frozen ? pulse : 1)
        .onAppear(perform: start)
    }

    /// With Reduce Motion on there is no sweep at all — the band parks where the
    /// comps drew it and breathes. Motion is the accommodation; the signal isn't.
    /// Frozen, it does not even breathe: a still frame of a fade is a coin toss.
    private func start() {
        guard !frozen else { return }
        if reduceMotion {
            withAnimation(.easeInOut(duration: period).repeatForever(autoreverses: true)) {
                pulse = 0.35
            }
        } else {
            travel = travelStart
            withAnimation(.linear(duration: period).repeatForever(autoreverses: false)) {
                travel = travelEnd
            }
        }
    }

    // MARK: - CSS angle → two UnitPoints

    /// The gradient line for `size`, in unit space, pushed along itself by `travel`.
    ///
    /// CSS measures from straight up, clockwise; screen y grows downward, so the
    /// direction is `(sin θ, −cos θ)`. The line's length is the box's extent
    /// along that direction (`|w·dx| + |h·dy|`, the CSS rule), which is what
    /// makes stop percentages mean the same thing here as they do in Figma.
    public static func gradientLine(
        angle: Double, size: CGSize, travel: Double
    ) -> (start: UnitPoint, end: UnitPoint) {
        guard size.width > 0, size.height > 0 else {
            return (.leading, .trailing)
        }
        let radians = angle * .pi / 180
        let dx = sin(radians)
        let dy = -cos(radians)
        let length = abs(size.width * dx) + abs(size.height * dy)
        let push = length * travel
        let midX = size.width / 2, midY = size.height / 2
        let startX = midX - dx * length / 2 + dx * push
        let startY = midY - dy * length / 2 + dy * push
        let endX = midX + dx * length / 2 + dx * push
        let endY = midY + dy * length / 2 + dy * push
        return (
            UnitPoint(x: startX / size.width, y: startY / size.height),
            UnitPoint(x: endX / size.width, y: endY / size.height)
        )
    }
}

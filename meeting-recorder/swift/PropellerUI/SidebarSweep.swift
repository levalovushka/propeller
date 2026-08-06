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

extension EnvironmentValues {
    /// Show the summary already arrived instead of playing its reveal.
    ///
    /// Same reason as the sweep above, and it has to be its own flag because the
    /// two are photographed on different boards: a half-faded column differs
    /// from the next shot of the same column, and the gallery exists to answer
    /// «что изменилось», not «когда нажали».
    public var summaryRevealFrozen: Bool {
        get { self[SummaryRevealFrozenKey.self] }
        set { self[SummaryRevealFrozenKey.self] = newValue }
    }
}

private struct SummaryRevealFrozenKey: EnvironmentKey {
    static let defaultValue = false
}

/// How the processing band paints.
public enum SidebarSweepMode: Sendable {
    /// Brighten the view's own pixels toward `peak` — for `Text` in the rail.
    case brighten
    /// Draw only the band, shaped by the view's alpha — for a glyph overlay
    /// above the summary editor (the base letters stay underneath).
    case band
}

/// Processing light travelling across text — the row that is in the pipeline,
/// or the summary fragment the model is rewriting.
///
/// # Two paints, one geometry
///
/// Summary glyph `Image` → Metal `textShimmerBand`. Rail `Text` → SwiftUI
/// gradient masked to the letters: `colorEffect` on `Text` does not light up,
/// so the rail keeps the path that always worked. Same angle / stops / travel.
///
/// # The geometry is Figma's, exactly
///
/// The comps freeze the sweep mid-pass: a linear gradient at 113.913° with
/// stops at 29.643 % (clear), 43.876 % (white 75 %) and 58.108 % (clear). Those
/// numbers are `Tokens.Sidebar.shimmer*`, and at `travel == 0` this draws that
/// frame — which is what makes it checkable against the design.
public struct SidebarSweep: ViewModifier {
    private let mode: SidebarSweepMode
    private let angle: Double
    private let peak: Color
    private let period: Double
    private let halfWidth: Double
    private let center: Double

    /// How far the peak is pushed along the gradient line. 0 is the Figma frame.
    @State private var travel: Double
    @State private var pulse: Double = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.sidebarSweepFrozen) private var frozen

    public init(
        mode: SidebarSweepMode = .brighten,
        angle: Double = Tokens.Sidebar.shimmerAngle,
        peak: Color = Tokens.Sidebar.shimmerPeak,
        period: Double = Tokens.Sidebar.shimmerPeriod,
        halfWidth: Double = Tokens.Sidebar.shimmerHalfWidth,
        center: Double = Tokens.Sidebar.shimmerCenter
    ) {
        self.mode = mode
        self.angle = angle
        self.peak = peak
        self.period = period
        self.halfWidth = halfWidth
        self.center = center
        _travel = State(initialValue: -halfWidth - center)
    }

    private var travelStart: Double { -halfWidth - center }
    private var travelEnd: Double { 1 + halfWidth - center }
    private var isStill: Bool { frozen || reduceMotion }
    private var pose: Double { isStill ? 0 : travel }

    public func body(content: Content) -> some View {
        Group {
            // Metal `colorEffect` is reliable on a raster `Image` (summary glyph
            // mask). On SwiftUI `Text` — the rail — it is a silent no-op: the
            // band never lights up, and a working row looks finished. Keep the
            // gradient-over-glyphs path for `.brighten`; use Metal only for
            // `.band` when the library is there.
            if mode == .band, let library = SummaryShader.library {
                content.colorEffect(library.textShimmerBand(
                    .boundingRect,
                    .float(Float(pose)),
                    .float(Float(angle)),
                    .float(Float(halfWidth)),
                    .float(Float(center)),
                    .color(peak)
                ))
            } else {
                fallback(content)
            }
        }
        .opacity(reduceMotion && !frozen ? pulse : 1)
        .onAppear(perform: start)
    }

    /// Gradient band masked to glyph alpha — the pre-Metal path.
    @ViewBuilder
    private func fallback(_ content: Content) -> some View {
        switch mode {
        case .brighten:
            content.overlay { gradient.mask(content) }
        case .band:
            gradient.mask(content)
        }
    }

    private var gradient: some View {
        GeometryReader { geo in
            let line = Self.gradientLine(angle: angle, size: geo.size, travel: pose)
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
    }

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

extension View {
    /// Brighten this view's pixels with the processing shimmer (rail titles).
    public func sidebarSweep() -> some View {
        modifier(SidebarSweep(mode: .brighten))
    }

    /// Overlay-only band shaped by this view's alpha (summary glyph mask).
    public func sidebarSweepBand() -> some View {
        modifier(SidebarSweep(mode: .band))
    }
}

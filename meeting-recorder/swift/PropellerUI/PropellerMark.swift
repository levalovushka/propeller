import SwiftUI

/// Propeller mark from Figma End (642:2477) — square viewBox, six petals.
///
/// Fills with the ambient foreground style, so a parent can tint it for light /
/// dark (or for a selected nav row) the same way an SF Symbol would.
public struct PropellerMark: View {
    public var size: CGFloat = 48

    public init(size: CGFloat = 48) {
        self.size = size
    }

    public var body: some View {
        PropellerMarkShape()
            .fill()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The brand glyph in a nav-sized slot. Spins counter-clockwise while the row
/// is hovered, and coasts to the next pose that looks like the resting one when
/// the pointer leaves — never snaps back mid-petal, and never has to unwind a
/// whole turn after a pointer that only brushed past.
struct PropellerNavMark: View {
    var spinning: Bool

    /// One full turn every two seconds — slow enough to read as a mark, not a fan.
    private let degreesPerSecond: Double = 180

    /// Six petals, one every 60°, so a sixth of a turn is already the mark again.
    /// The exact symmetry is 180° (the petals sit in three 180°-opposed pairs,
    /// spaced 58.9 / 62.4 / 58.7 rather than a clean 60), but at
    /// `Tokens.Sidebar.navIconSize` a petal tip lives ~5 pt out, so the worst
    /// 1.7° of error is 0.15 pt — under a retina pixel, and worth trading for a
    /// coast a third as long.
    private static let symmetryPeriod: Double = 60

    /// The coast runs at two thirds of the spin, so the stop reads as the blade
    /// running out of momentum rather than the animation ending.
    private let settleDegreesPerSecond: Double = 120

    @State private var parkedAngle: Double = 0
    @State private var spinStartedAt: Date?
    @State private var settleFrom: Double = 0
    @State private var settleTo: Double?
    @State private var settleStartedAt: Date?
    @State private var settleDuration: TimeInterval = 0

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: 1.0 / 60.0,
                paused: spinStartedAt == nil && settleTo == nil
            )
        ) { context in
            PropellerMark(size: Tokens.Sidebar.navIconSize)
                .rotationEffect(.degrees(angle(at: context.date)))
        }
        .frame(width: Tokens.Sidebar.navIconSide, height: Tokens.Sidebar.navIconSide)
        .onChange(of: spinning) { _, now in
            let t = Date()
            if now {
                parkedAngle = angle(at: t)
                settleTo = nil
                settleStartedAt = nil
                spinStartedAt = t
            } else {
                let current = angle(at: t)
                spinStartedAt = nil
                let target = Self.settleTarget(from: current)
                settleFrom = current
                settleTo = target
                settleStartedAt = t
                settleDuration = abs(target - current) / settleDegreesPerSecond
                parkedAngle = current
            }
        }
        .task(id: settleTo) {
            guard settleTo != nil else { return }
            let ns = UInt64(max(settleDuration, 0.05) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: ns)
            guard let target = settleTo else { return }
            parkedAngle = target
            settleTo = nil
            settleStartedAt = nil
        }
    }

    private func angle(at date: Date) -> Double {
        if let start = spinStartedAt {
            return parkedAngle - date.timeIntervalSince(start) * degreesPerSecond
        }
        if let target = settleTo, let start = settleStartedAt {
            let u = min(1, date.timeIntervalSince(start) / max(settleDuration, 0.05))
            return settleFrom + (target - settleFrom) * Self.easeOutBack(u)
        }
        return parkedAngle
    }

    /// Overshoots the resting pose by an eighth of the way it had left to travel,
    /// then eases back onto it — one soft bounce, no oscillation. Proportional
    /// rather than a fixed number of degrees, so a coast that had little left to
    /// unwind doesn't gain a kick it never earned.
    private static func easeOutBack(_ u: Double) -> Double {
        let c1 = 2.0
        let t = u - 1
        return 1 + (c1 + 1) * pow(t, 3) + c1 * pow(t, 2)
    }

    /// Where the coast lands: the next pose that matches the resting mark, unless
    /// it is so close that stopping there would be a twitch rather than a coast —
    /// then the blade borrows one more petal and travels 60–75° instead.
    private static func settleTarget(from current: Double) -> Double {
        let next = nextRestingPoseCCW(from: current)
        guard abs(next - current) < twitchThreshold else { return next }
        return next - symmetryPeriod
    }

    /// A quarter of a petal. Under this the settle has no room to ease in or out,
    /// and the bounce lands inside it — the eye reads a snap, not a stop.
    private static let twitchThreshold: Double = 15

    /// Continues counter-clockwise to the next pose that matches the resting mark
    /// — a petal step away at most, not a whole turn away.
    private static func nextRestingPoseCCW(from current: Double) -> Double {
        -symmetryPeriod * ceil((-current) / symmetryPeriod)
    }
}

private struct PropellerMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var combined = Path()
        for petal in Self.petals { combined.addPath(petal) }
        let t = CGAffineTransform(a: rect.width / 48, b: 0, c: 0, d: rect.height / 48,
                                  tx: rect.minX, ty: rect.minY)
        return combined.applying(t)
    }

    private static let petals: [Path] = {
        var all: [Path] = []
        func petal(_ build: (inout Path) -> Void) {
            var p = Path()
            build(&p)
            p.closeSubpath()
            all.append(p)
        }
        petal { p in
            p.move(to: CGPoint(x: 14.3159, y: 7.34584))
            p.addCurve(to: CGPoint(x: 16.2902, y: 25.4193),
                       control1: CGPoint(x: 12.4047, y: 15.515),
                       control2: CGPoint(x: 14.4907, y: 22.4541))
            p.addCurve(to: CGPoint(x: 25.4964, y: 6.4449),
                       control1: CGPoint(x: 14.0962, y: 15.3481),
                       control2: CGPoint(x: 24.2379, y: 11.8242))
            p.addCurve(to: CGPoint(x: 22.0909, y: 0.108196),
                       control1: CGPoint(x: 26.2378, y: 3.27595),
                       control2: CGPoint(x: 24.8179, y: 0.627215))
            p.addCurve(to: CGPoint(x: 14.3159, y: 7.34584),
                       control1: CGPoint(x: 19.2049, y: -0.441063),
                       control2: CGPoint(x: 15.8072, y: 0.971545))
        }
        petal { p in
            p.move(to: CGPoint(x: 4.03346, y: 23.6707))
            p.addCurve(to: CGPoint(x: 21.4341, y: 31.077),
                       control1: CGPoint(x: 10.4967, y: 29.3336),
                       control2: CGPoint(x: 17.8414, y: 31.0805))
            p.addCurve(to: CGPoint(x: 8.80553, y: 13.9868),
                       control1: CGPoint(x: 11.1909, y: 27.8533),
                       control2: CGPoint(x: 13.0615, y: 17.7158))
            p.addCurve(to: CGPoint(x: 1.34805, y: 13.631),
                       control1: CGPoint(x: 6.29833, y: 11.79),
                       control2: CGPoint(x: 3.18292, y: 11.6383))
            p.addCurve(to: CGPoint(x: 4.03346, y: 23.6707),
                       control1: CGPoint(x: -0.593732, y: 15.7397),
                       control2: CGPoint(x: -1.00973, y: 19.252))
        }
        petal { p in
            p.move(to: CGPoint(x: 13.7178, y: 40.3249))
            p.addCurve(to: CGPoint(x: 29.1441, y: 29.6577),
                       control1: CGPoint(x: 22.0922, y: 37.8187),
                       control2: CGPoint(x: 27.351, y: 32.6265))
            p.addCurve(to: CGPoint(x: 7.30936, y: 31.5419),
                       control1: CGPoint(x: 21.095, y: 36.5053),
                       control2: CGPoint(x: 12.8238, y: 29.8916))
            p.addCurve(to: CGPoint(x: 3.25747, y: 37.5228),
                       control1: CGPoint(x: 4.06079, y: 32.5141),
                       control2: CGPoint(x: 2.36529, y: 35.0111))
            p.addCurve(to: CGPoint(x: 13.7178, y: 40.3249),
                       control1: CGPoint(x: 4.20163, y: 40.1808),
                       control2: CGPoint(x: 7.18334, y: 42.2805))
        }
        petal { p in
            p.move(to: CGPoint(x: 33.6843, y: 40.6542))
            p.addCurve(to: CGPoint(x: 31.71, y: 22.5807),
                       control1: CGPoint(x: 35.5955, y: 32.485),
                       control2: CGPoint(x: 33.5096, y: 25.5459))
            p.addCurve(to: CGPoint(x: 22.5038, y: 41.5551),
                       control1: CGPoint(x: 33.9041, y: 32.6519),
                       control2: CGPoint(x: 23.7623, y: 36.1758))
            p.addCurve(to: CGPoint(x: 25.9094, y: 47.8918),
                       control1: CGPoint(x: 21.7624, y: 44.724),
                       control2: CGPoint(x: 23.1823, y: 47.3728))
            p.addCurve(to: CGPoint(x: 33.6843, y: 40.6542),
                       control1: CGPoint(x: 28.7953, y: 48.4411),
                       control2: CGPoint(x: 32.193, y: 47.0285))
        }
        petal { p in
            p.move(to: CGPoint(x: 43.9665, y: 24.3292))
            p.addCurve(to: CGPoint(x: 26.5659, y: 16.9229),
                       control1: CGPoint(x: 37.5033, y: 18.6662),
                       control2: CGPoint(x: 30.1586, y: 16.9194))
            p.addCurve(to: CGPoint(x: 39.1945, y: 34.0131),
                       control1: CGPoint(x: 36.8091, y: 20.1465),
                       control2: CGPoint(x: 34.9385, y: 30.2841))
            p.addCurve(to: CGPoint(x: 46.652, y: 34.3689),
                       control1: CGPoint(x: 41.7017, y: 36.2098),
                       control2: CGPoint(x: 44.8171, y: 36.3616))
            p.addCurve(to: CGPoint(x: 43.9665, y: 24.3292),
                       control1: CGPoint(x: 48.5937, y: 32.2602),
                       control2: CGPoint(x: 49.0097, y: 28.7479))
        }
        petal { p in
            p.move(to: CGPoint(x: 34.2824, y: 7.67513))
            p.addCurve(to: CGPoint(x: 18.8561, y: 18.3424),
                       control1: CGPoint(x: 25.908, y: 10.1813),
                       control2: CGPoint(x: 20.6492, y: 15.3736))
            p.addCurve(to: CGPoint(x: 40.6908, y: 16.4581),
                       control1: CGPoint(x: 26.9052, y: 11.4948),
                       control2: CGPoint(x: 35.1764, y: 18.1084))
            p.addCurve(to: CGPoint(x: 44.7427, y: 10.4773),
                       control1: CGPoint(x: 43.9394, y: 15.4859),
                       control2: CGPoint(x: 45.6349, y: 12.9889))
            p.addCurve(to: CGPoint(x: 34.2824, y: 7.67513),
                       control1: CGPoint(x: 43.7986, y: 7.81927),
                       control2: CGPoint(x: 40.8168, y: 5.71956))
        }
        return all
    }()
}

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

/// The brand glyph in a nav-sized slot, driven as a blade with mass rather than
/// as an animation with a duration.
///
/// Hover feeds it power: the speed climbs towards `topSpeed` instead of arriving
/// there, so a pointer crossing the row hands over less energy than one that
/// rests on it. Taking the pointer away cuts the power — nothing steers the blade
/// home after that, it spends the speed it had against friction and stops at the
/// last pose its momentum reached.
///
/// Every phase is a closed-form curve of the clock, so a frame is a pure function
/// of `context.date` and there is nothing to integrate between frames — and the
/// hand-off from power to coast carries the speed across exactly, which is the
/// whole reason the stop reads as physics and not as an ease.
struct PropellerNavMark: View {
    var spinning: Bool

    /// Top speed under power — one turn every two seconds, slow enough to read as
    /// a mark rather than a fan. Negative: the blade turns counter-clockwise.
    private static let topSpeed: Double = -180

    /// How fast the power arrives: 63 % of top speed in this long, 95 % in three
    /// times it. Long enough that a brush past the row spins the blade a little
    /// and a deliberate hover spins it fully.
    private static let spinUpTime: Double = 0.18

    /// Friction, as the time the blade would take to stop if it kept decaying at
    /// its initial rate — so `speed × spinDownTime` is the travel its momentum is
    /// worth. At top speed that is 81°, a petal and a third.
    private static let spinDownTime: Double = 0.45

    /// How thoroughly the coast decays before we call it stopped: the curve ends at
    /// `e^-4` of the speed it began with, 1.8 %, which at these speeds is under
    /// 4°/s — slower than a frame can show.
    private static let spinDownDecay: Double = 4

    /// Six petals, one every 60°, so a sixth of a turn is already the mark again.
    /// The exact symmetry is 180° (the petals sit in three 180°-opposed pairs,
    /// spaced 58.9 / 62.4 / 58.7 rather than a clean 60), but at
    /// `Tokens.Sidebar.navIconSize` a petal tip lives ~5 pt out, so the worst
    /// 1.7° of error is 0.15 pt — under a retina pixel, and worth trading for a
    /// coast a third as long.
    private static let symmetryPeriod: Double = 60

    /// A blade that never got going has nothing to coast on: rather than drift for
    /// three seconds to reach the pose ahead, it settles onto the one it just left.
    /// Only allowed while that is 6° away or less — 0.5 pt of petal tip, and only
    /// reachable by a pointer that crossed the row in under 130 ms.
    private static let settleBackLimit: Double = 6

    @State private var motion: Motion = .parked(0)
    /// Bumped on every hand-off, so the task that parks a finished coast is
    /// cancelled by the next one instead of landing in the middle of it.
    @State private var handOff = 0

    var body: some View {
        TimelineView(
            .animation(minimumInterval: 1.0 / 60.0, paused: motion.isParked)
        ) { context in
            PropellerMark(size: Tokens.Sidebar.navIconSize)
                .rotationEffect(.degrees(motion.angle(at: context.date)))
        }
        .frame(width: Tokens.Sidebar.navIconSide, height: Tokens.Sidebar.navIconSide)
        .onChange(of: spinning) { _, now in
            let t = Date()
            let angle = motion.angle(at: t)
            let speed = motion.speed(at: t)
            motion = now
                ? .powered(from: angle, speed: speed, since: t)
                : Self.coast(from: angle, speed: speed, at: t)
            handOff += 1
        }
        .task(id: handOff) {
            guard case .coasting(let from, let travel, let duration, _) = motion else { return }
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            motion = .parked(from + travel)
        }
    }

    /// Power off. The blade keeps the speed it had, spends it against friction, and
    /// stops at the last pose inside that budget — which is why a long hover ends
    /// with a long coast and a brush ends with a short one, without either being
    /// asked for.
    private static func coast(from angle: Double, speed: Double, at t: Date) -> Motion {
        let past = degreesPastPose(angle)
        let toNextPose = (symmetryPeriod - past).truncatingRemainder(dividingBy: symmetryPeriod)
        let budget = abs(speed) * spinDownTime

        // Not enough left to reach the pose ahead — and near enough behind that
        // giving up on it costs half a point of movement.
        if past > 0, past <= settleBackLimit, budget < toNextPose {
            return .parked(angle + past)
        }
        let wholePetals = max(0, (budget - toNextPose) / symmetryPeriod).rounded(.down)
        let travel = -(toNextPose + wholePetals * symmetryPeriod)
        guard travel < 0, abs(speed) > 1 else { return .parked(angle + past) }

        // The curve below starts at exactly `speed`, so its length fixes how long
        // it runs. Time is the derived quantity here, never the designed one.
        let duration = abs(travel) * spinDownDecay
            / (abs(speed) * (1 - exp(-spinDownDecay)))
        return .coasting(from: angle, travel: travel, duration: duration, since: t)
    }

    /// How far the blade sits past the last pose that matches the resting mark,
    /// measured in the direction it turns.
    private static func degreesPastPose(_ angle: Double) -> Double {
        let travelled = -angle
        return travelled - symmetryPeriod * (travelled / symmetryPeriod).rounded(.down)
    }

    /// The three things the blade can be doing, each as a curve rather than a
    /// per-frame state — see the note on `PropellerNavMark`.
    private enum Motion {
        case parked(Double)
        /// Speed approaching `topSpeed` from whatever it was when the power came on.
        case powered(from: Double, speed: Double, since: Date)
        /// Speed decaying from `travel × decay / duration` to almost nothing, laid
        /// out so the blade covers exactly `travel` by the time it runs out.
        case coasting(from: Double, travel: Double, duration: TimeInterval, since: Date)

        var isParked: Bool {
            if case .parked = self { return true }
            return false
        }

        func angle(at date: Date) -> Double {
            switch self {
            case .parked(let angle):
                return angle
            case .powered(let from, let speed, let since):
                let t = date.timeIntervalSince(since)
                let tau = PropellerNavMark.spinUpTime
                let top = PropellerNavMark.topSpeed
                return from + top * t + (speed - top) * tau * (1 - exp(-t / tau))
            case .coasting(let from, let travel, let duration, let since):
                let u = min(1, date.timeIntervalSince(since) / duration)
                let k = PropellerNavMark.spinDownDecay
                return from + travel * (1 - exp(-k * u)) / (1 - exp(-k))
            }
        }

        func speed(at date: Date) -> Double {
            switch self {
            case .parked:
                return 0
            case .powered(_, let speed, let since):
                let t = date.timeIntervalSince(since)
                let tau = PropellerNavMark.spinUpTime
                let top = PropellerNavMark.topSpeed
                return top + (speed - top) * exp(-t / tau)
            case .coasting(_, let travel, let duration, let since):
                let u = min(1, date.timeIntervalSince(since) / duration)
                let k = PropellerNavMark.spinDownDecay
                return travel * k / (duration * (1 - exp(-k))) * exp(-k * u)
            }
        }
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

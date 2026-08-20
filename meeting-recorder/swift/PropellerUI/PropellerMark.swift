import SwiftUI

/// Propeller mark, six petals — the same drawing the app icon is cut from
/// (`propellericon.icon/Assets/propeller.svg`, a 794 square).
///
/// The petals below are that file scaled *uniformly* to fill the height of the
/// 48-unit box `PropellerMarkShape` authors in, and centred across it. Uniform
/// is the whole point: the drawing is 623.6 × 695.4, and squaring it up would
/// cost the exact rotational symmetry the blade animation leans on. The 2.5 of
/// slack left either side is the drawing's own proportion, not padding — the
/// icon's padding lives in the icon, where the platform grid asks for it.
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

    /// Top speed under power — one full turn a second. Negative: the blade turns
    /// counter-clockwise.
    ///
    /// Twice what it was, and the point is not the speed itself but the *range*:
    /// the ramp below climbs to it with the same time constant, so doubling the top
    /// doubles how hard the blade accelerates while the pointer sits on the row.
    /// At 180 the climb was over before the eye had anything to compare it against.
    private static let topSpeed: Double = -360

    /// How fast the power arrives: 63 % of top speed in this long, 95 % in three
    /// times it. Long enough that a brush past the row spins the blade a little
    /// and a deliberate hover spins it fully.
    private static let spinUpTime: Double = 0.18

    /// Friction, as the time the blade would take to stop if it kept decaying at
    /// its initial rate — so `speed × spinDownTime` is the travel its momentum is
    /// worth. At top speed that is 162°, two petals and a bit.
    ///
    /// Unchanged with the faster top: friction is a property of the blade, not of
    /// how hard it was driven. A faster blade therefore coasts *further*, which is
    /// the whole reason it reads as heavier.
    private static let spinDownTime: Double = 0.45

    /// How thoroughly the coast decays before we call it stopped: the curve ends at
    /// `e^-4` of the speed it began with, 1.8 %, which at these speeds is under
    /// 4°/s — slower than a frame can show.
    private static let spinDownDecay: Double = 4

    /// Six petals, one every 60°, so a sixth of a turn is already the mark again.
    /// This is now exact, and it was not before: rotating any petal of the current
    /// drawing onto the next leaves 0.001 of a unit on the 794 canvas it comes
    /// from — 0.0001 in the 48-unit box, far under a retina pixel at any size the
    /// mark is drawn. The previous drawing sat at 58.9 / 62.4 / 58.7, and the 1.7°
    /// of error was a deliberate trade for a coast a third as long; there is
    /// nothing left to trade, the pose the blade parks on *is* the resting mark.
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
            p.move(to: CGPoint(x: 22.7809, y: 0.171))
            p.addCurve(to: CGPoint(x: 16.5739, y: 18.9259),
                       control1: CGPoint(x: 18.8923, y: 1.1238),
                       control2: CGPoint(x: 13.8141, y: 7.6627))
            p.addCurve(to: CGPoint(x: 17.3972, y: 21.8512),
                       control1: CGPoint(x: 16.7545, y: 19.6634),
                       control2: CGPoint(x: 17.2315, y: 21.4653))
            p.addCurve(to: CGPoint(x: 18.2736, y: 22.3827),
                       control1: CGPoint(x: 17.5879, y: 22.2957),
                       control2: CGPoint(x: 17.9049, y: 22.4731))
            p.addCurve(to: CGPoint(x: 18.697, y: 21.355),
                       control1: CGPoint(x: 18.6424, y: 22.2924),
                       control2: CGPoint(x: 18.8613, y: 22.0255))
            p.addCurve(to: CGPoint(x: 28.426, y: 3.0519),
                       control1: CGPoint(x: 16.504, y: 12.4048),
                       control2: CGPoint(x: 30.3644, y: 10.963))
            p.addCurve(to: CGPoint(x: 22.7809, y: 0.171),
                       control1: CGPoint(x: 27.925, y: 1.0071),
                       control2: CGPoint(x: 25.6302, y: -0.5271))
        }
        petal { p in
            p.move(to: CGPoint(x: 2.7539, y: 13.1413))
            p.addCurve(to: CGPoint(x: 15.8926, y: 27.8943),
                       control1: CGPoint(x: 1.6348, y: 16.9852),
                       control2: CGPoint(x: 4.7584, y: 24.6526))
            p.addCurve(to: CGPoint(x: 18.8377, y: 28.6438),
                       control1: CGPoint(x: 16.6216, y: 28.1065),
                       control2: CGPoint(x: 18.4207, y: 28.5943))
            p.addCurve(to: CGPoint(x: 19.7362, y: 28.1506),
                       control1: CGPoint(x: 19.318, y: 28.7008),
                       control2: CGPoint(x: 19.63, y: 28.5151))
            p.addCurve(to: CGPoint(x: 19.0579, y: 27.2701),
                       control1: CGPoint(x: 19.8423, y: 27.786),
                       control2: CGPoint(x: 19.7206, y: 27.4631))
            p.addCurve(to: CGPoint(x: 8.0714, y: 9.6929),
                       control1: CGPoint(x: 10.2102, y: 24.6941),
                       control2: CGPoint(x: 15.8919, y: 11.9698))
            p.addCurve(to: CGPoint(x: 2.7539, y: 13.1413),
                       control1: CGPoint(x: 6.0501, y: 9.1044),
                       control2: CGPoint(x: 3.574, y: 10.3247))
        }
        petal { p in
            p.move(to: CGPoint(x: 3.9731, y: 36.9703))
            p.addCurve(to: CGPoint(x: 23.3188, y: 32.9683),
                       control1: CGPoint(x: 6.7424, y: 39.8615),
                       control2: CGPoint(x: 14.9443, y: 40.99))
            p.addCurve(to: CGPoint(x: 25.4405, y: 30.7926),
                       control1: CGPoint(x: 23.8671, y: 32.443),
                       control2: CGPoint(x: 25.1891, y: 31.1289))
            p.addCurve(to: CGPoint(x: 25.4625, y: 29.7679),
                       control1: CGPoint(x: 25.73, y: 30.4052),
                       control2: CGPoint(x: 25.7251, y: 30.042))
            p.addCurve(to: CGPoint(x: 24.3609, y: 29.915),
                       control1: CGPoint(x: 25.1999, y: 29.4937),
                       control2: CGPoint(x: 24.8594, y: 29.4376))
            p.addCurve(to: CGPoint(x: 3.6454, y: 30.641),
                       control1: CGPoint(x: 17.7062, y: 36.2894),
                       control2: CGPoint(x: 9.5274, y: 25.0068))
            p.addCurve(to: CGPoint(x: 3.9731, y: 36.9703),
                       control1: CGPoint(x: 2.1251, y: 32.0974),
                       control2: CGPoint(x: 1.9438, y: 34.8518))
        }
        petal { p in
            p.move(to: CGPoint(x: 25.2192, y: 47.829))
            p.addCurve(to: CGPoint(x: 31.4262, y: 29.0741),
                       control1: CGPoint(x: 29.1076, y: 46.8762),
                       control2: CGPoint(x: 34.1859, y: 40.3373))
            p.addCurve(to: CGPoint(x: 30.6028, y: 26.1488),
                       control1: CGPoint(x: 31.2454, y: 28.3366),
                       control2: CGPoint(x: 30.7684, y: 26.5346))
            p.addCurve(to: CGPoint(x: 29.7264, y: 25.6173),
                       control1: CGPoint(x: 30.412, y: 25.7043),
                       control2: CGPoint(x: 30.0951, y: 25.5269))
            p.addCurve(to: CGPoint(x: 29.303, y: 26.645),
                       control1: CGPoint(x: 29.3576, y: 25.7076),
                       control2: CGPoint(x: 29.1388, y: 25.9745))
            p.addCurve(to: CGPoint(x: 19.574, y: 44.948),
                       control1: CGPoint(x: 31.496, y: 35.5952),
                       control2: CGPoint(x: 17.6356, y: 37.037))
            p.addCurve(to: CGPoint(x: 25.2192, y: 47.829),
                       control1: CGPoint(x: 20.075, y: 46.9929),
                       control2: CGPoint(x: 22.3698, y: 48.5271))
        }
        petal { p in
            p.move(to: CGPoint(x: 45.2461, y: 34.8586))
            p.addCurve(to: CGPoint(x: 32.1074, y: 20.1057),
                       control1: CGPoint(x: 46.3652, y: 31.0148),
                       control2: CGPoint(x: 43.2415, y: 23.3474))
            p.addCurve(to: CGPoint(x: 29.1624, y: 19.3562),
                       control1: CGPoint(x: 31.3783, y: 19.8935),
                       control2: CGPoint(x: 29.5793, y: 19.4057))
            p.addCurve(to: CGPoint(x: 28.2638, y: 19.8494),
                       control1: CGPoint(x: 28.682, y: 19.2992),
                       control2: CGPoint(x: 28.3699, y: 19.4849))
            p.addCurve(to: CGPoint(x: 28.9421, y: 20.7299),
                       control1: CGPoint(x: 28.1577, y: 20.214),
                       control2: CGPoint(x: 28.2794, y: 20.5369))
            p.addCurve(to: CGPoint(x: 39.9286, y: 38.3071),
                       control1: CGPoint(x: 37.7898, y: 23.3059),
                       control2: CGPoint(x: 32.1081, y: 36.0302))
            p.addCurve(to: CGPoint(x: 45.2461, y: 34.8586),
                       control1: CGPoint(x: 41.9499, y: 38.8956),
                       control2: CGPoint(x: 44.4261, y: 37.6753))
        }
        petal { p in
            p.move(to: CGPoint(x: 44.027, y: 11.0297))
            p.addCurve(to: CGPoint(x: 24.6812, y: 15.0317),
                       control1: CGPoint(x: 41.2576, y: 8.1385),
                       control2: CGPoint(x: 33.0556, y: 7.01))
            p.addCurve(to: CGPoint(x: 22.5595, y: 17.2074),
                       control1: CGPoint(x: 24.1329, y: 15.5569),
                       control2: CGPoint(x: 22.8108, y: 16.871))
            p.addCurve(to: CGPoint(x: 22.5375, y: 18.2321),
                       control1: CGPoint(x: 22.27, y: 17.5948),
                       control2: CGPoint(x: 22.2748, y: 17.958))
            p.addCurve(to: CGPoint(x: 23.6391, y: 18.085),
                       control1: CGPoint(x: 22.8001, y: 18.5063),
                       control2: CGPoint(x: 23.1406, y: 18.5624))
            p.addCurve(to: CGPoint(x: 44.3546, y: 17.359),
                       control1: CGPoint(x: 30.2938, y: 11.7106),
                       control2: CGPoint(x: 38.4725, y: 22.9932))
            p.addCurve(to: CGPoint(x: 44.027, y: 11.0297),
                       control1: CGPoint(x: 45.8749, y: 15.9026),
                       control2: CGPoint(x: 46.0563, y: 13.1482))
        }

        return all
    }()
}

extension PropellerMark {
    /// Тот же силуэт, но как `CGPath` — для слоя, который крутится сам.
    ///
    /// SwiftUI-путь пересобирается и растеризуется на каждый кадр главным
    /// потоком; слою он отдаётся один раз, а поворот дальше считает
    /// рендер-сервер. Для лопасти, которая обязана идти ровно как раз тогда,
    /// когда главный поток занят расшифровкой, это и есть вся разница.
    public static func cgPath(in rect: CGRect) -> CGPath {
        PropellerMarkShape().path(in: rect).cgPath
    }
}

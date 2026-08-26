import Foundation
import CoreGraphics

/// Что встреча делает прямо сейчас — одной фигурой.
///
/// Пять состояний одной решётки: шесть лучей, два кольца, сдвиг 30°. Различаются
/// они не формой и не цветом, а движением — какие узлы заняты и с какой фазой.
/// Цвет здесь не участвует намеренно: у рельса одна краска на всё, и статус,
/// сказанный цветом, был бы вторым словарём поверх первого
/// (`design/propeller-ui.md`, «Цвет — только смысл»).
public enum PropellerStatus: String, CaseIterable, Equatable, Sendable {
    /// Ничего не происходит. В строке встречи не используется — у готовой
    /// встречи иконки нет вовсе, строка начинается с текста; состояние живёт
    /// ради демо и галереи.
    case idle
    case recording
    case queued
    case processing
    /// Стоим и ждём чего-то снаружи: модель качается, сервис молчит. **Не
    /// ошибка и не просьба** — ветви «нужен человек» в проекте нет вообще
    /// (`MeetingRest`, `design/no-dead-ends.md`).
    case problem

    public var accessibilityLabel: String {
        switch self {
        case .idle: return "Покой"
        case .recording: return "Идёт запись"
        case .queued: return "В очереди"
        case .processing: return "Обработка"
        case .problem: return "Ждём"
        }
    }
}

/// Решётка статусной иконки: где в момент `time` стоит каждая точка.
///
/// Чистая, потому что это единственный способ её проверить — глазами на 16 pt
/// анимации не проверяется ничего, а тест спрашивает у функции. И потому, что
/// от неё, возможно, будет питаться не `Canvas`, а слой: если покадровая
/// отрисовка на главном потоке начнёт дёргаться под расшифровкой (ровно то, что
/// случилось с лопастью в чёлке — `PropellerUI/NotchSurface.swift`), кадры
/// сэмплируются отсюда же в `CAKeyframeAnimation`, и математика не меняется.
///
/// Порт веб-демо v2 (`~/Desktop/Propeller Status Icons`), один в один.
public enum PropellerLattice {

    public struct Dot: Equatable, Sendable {
        public var x: CGFloat
        public var y: CGFloat
        public var radius: CGFloat
        public var alpha: CGFloat

        public init(x: CGFloat, y: CGFloat, radius: CGFloat, alpha: CGFloat) {
            self.x = x
            self.y = y
            self.radius = radius
            self.alpha = alpha
        }
    }

    /// Лучей в кольце. Шесть — потому что столько лопастей у марки.
    public static let count = 6
    private static let fib: [CGFloat] = [1, 1, 2, 3, 5, 8]

    /// Двенадцать точек: внутреннее кольцо и внешнее.
    public static let dotCount = count * 2

    public static func dots(status: PropellerStatus, size: CGFloat, time: TimeInterval) -> [Dot] {
        switch status {
        case .idle: return idle(size)
        case .recording: return recording(size, time)
        case .queued: return queued(size, time)
        case .processing: return processing(size, time)
        case .problem: return problem(size, time)
        }
    }

    /// Есть ли у состояния движение. `idle` — единственное неподвижное, и это
    /// решает, надо ли вообще будить таймер.
    public static func isAnimated(_ status: PropellerStatus) -> Bool { status != .idle }

    // MARK: - Метрики

    private struct Metrics {
        var r: CGFloat
        var reach: CGFloat
        var outer: CGFloat
        var rOut: CGFloat
    }

    /// На 16 pt точки крупнее и разлетаются дальше, чем того требует
    /// пропорция: на этом кегле пропорциональная точка занимает меньше пикселя
    /// и исчезает в сглаживании.
    private static func metrics(_ size: CGFloat) -> Metrics {
        let small = size <= 16
        return Metrics(
            r: size * (small ? 0.066 : 0.052),
            reach: size * (small ? 0.248 : 0.215),
            outer: size * (small ? 0.42 : 0.43),
            rOut: size * (small ? 0.028 : 0.026)
        )
    }

    private static func angle(_ i: Int, _ rot: CGFloat) -> CGFloat {
        -.pi / 2 + CGFloat(i) * .pi / 3 + rot
    }

    private static func hexRadii(_ radius: CGFloat) -> [CGFloat] {
        Array(repeating: radius, count: count)
    }

    private static func spiralRadii(_ radius: CGFloat) -> [CGFloat] {
        (0..<count).map { radius * (0.82 + 0.18 * (fib[$0] / 8)) }
    }

    private static func mixRadii(_ a: [CGFloat], _ b: [CGFloat], _ u: CGFloat) -> [CGFloat] {
        let e = u * u * (3 - 2 * u)
        return zip(a, b).map { $0 + ($1 - $0) * e }
    }

    private static func ring(
        _ size: CGFloat,
        rot: CGFloat,
        radii: [CGFloat],
        sizes: [CGFloat],
        alphas: [CGFloat]? = nil
    ) -> [Dot] {
        (0..<count).map { i in
            let a = angle(i, rot)
            return Dot(
                x: size / 2 + cos(a) * radii[i],
                y: size / 2 + sin(a) * radii[i],
                radius: sizes[i],
                alpha: alphas?[i] ?? 1
            )
        }
    }

    /// Трапеция: постоять — доехать — постоять — вернуться. Нужна там, где
    /// движение должно быть жестом, а не колебанием.
    private static func wind(_ t: CGFloat, holdA: CGFloat, travel: CGFloat, holdB: CGFloat) -> CGFloat {
        let period = holdA + travel + holdB + travel
        var x = t.truncatingRemainder(dividingBy: period)
        if x < 0 { x += period }
        if x < holdA { return 0 }
        x -= holdA
        if x < travel { return x / travel }
        x -= travel
        if x < holdB { return 1 }
        x -= holdB
        return 1 - x / travel
    }

    // MARK: - Состояния

    private static func idle(_ size: CGFloat) -> [Dot] {
        let m = metrics(size)
        return ring(size, rot: 0, radii: hexRadii(m.reach), sizes: Array(repeating: m.r * 0.9, count: count))
            + ring(
                size,
                rot: .pi / 6,
                radii: hexRadii(m.outer),
                sizes: Array(repeating: m.rOut, count: count),
                alphas: Array(repeating: 0.45, count: count)
            )
    }

    /// Дыхание: кольца меняются местами и возвращаются. Ничего не крутится —
    /// запись не «идёт куда-то», она длится.
    private static func recording(_ size: CGFloat, _ time: TimeInterval) -> [Dot] {
        let m = metrics(size)
        let t = CGFloat(time)
        let swap = 0.5 + 0.5 * sin(t * .pi * 2 / 1.55)
        let e = swap * swap * (3 - 2 * swap)
        let innerR = m.reach + (m.outer - m.reach) * e
        let outerR = m.outer + (m.reach - m.outer) * e
        return ring(size, rot: 0, radii: hexRadii(innerR), sizes: Array(repeating: m.r * (1.08 - 0.28 * e), count: count))
            + ring(
                size,
                rot: .pi / 6,
                radii: hexRadii(outerR),
                sizes: Array(repeating: m.rOut + (m.r - m.rOut) * e, count: count),
                alphas: Array(repeating: 0.45 + 0.4 * e, count: count)
            )
    }

    /// Огонёк перебегает по узлам очень медленно вращающейся решётки: работа
    /// назначена, но её ещё не начали.
    private static func queued(_ size: CGFloat, _ time: TimeInterval) -> [Dot] {
        let m = metrics(size)
        let t = CGFloat(time)
        let rot = t * .pi * 2 / 14
        let token = (t / 1.05).truncatingRemainder(dividingBy: CGFloat(count))
        let from = Int(floor(token))
        let next = (from + 1) % count
        let frac = token - CGFloat(from)
        let eased = frac * frac * (3 - 2 * frac)
        var radii = hexRadii(m.reach)
        var sizes = [CGFloat]()
        var outSizes = [CGFloat]()
        var outAlpha = [CGFloat]()
        for i in 0..<count {
            var boost: CGFloat = 0
            var shrink: CGFloat = 0
            if i == from { boost = 1 - eased }
            if i == next { boost = eased }
            if i == (from + 3) % count { shrink = 1 - eased }
            if i == (next + 3) % count { shrink = eased }
            sizes.append(m.r * (0.52 + 1.05 * boost - 0.28 * shrink))
            radii[i] = m.reach * (1 + 0.05 * boost - 0.04 * shrink)
            outSizes.append(m.rOut * (0.85 + 0.7 * boost))
            outAlpha.append(0.22 + 0.55 * boost + 0.12 * (1 - shrink))
        }
        return ring(size, rot: rot, radii: radii, sizes: sizes)
            + ring(size, rot: rot + .pi / 6, radii: hexRadii(m.outer), sizes: outSizes, alphas: outAlpha)
    }

    /// Два кольца крутятся с разной скоростью, внутреннее то сворачивается в
    /// спираль, то расходится обратно. Единственное состояние, которое явно
    /// работает.
    private static func processing(_ size: CGFloat, _ time: TimeInterval) -> [Dot] {
        let m = metrics(size)
        let t = CGFloat(time)
        let rotIn = t * .pi * 2 / 3.6
        let rotOut = t * .pi * 2 / 7.2
        let w = wind(t, holdA: 1.05, travel: 0.6, holdB: 0.55)
        let radii = mixRadii(hexRadii(m.reach), spiralRadii(m.reach), w)
        var sizes = [CGFloat]()
        var outSizes = [CGFloat]()
        var outAlpha = [CGFloat]()
        for i in 0..<count {
            let wave = 0.5 + 0.5 * sin(t * .pi * 2 / 1.7 + CGFloat(i) * .pi / 3)
            sizes.append(m.r * (0.82 + 0.2 * wave))
            outSizes.append(m.rOut * (0.9 + 0.14 * wave))
            outAlpha.append(0.5 + 0.25 * wave)
        }
        return ring(size, rot: rotIn, radii: radii, sizes: sizes)
            + ring(size, rot: rotOut + .pi / 6, radii: hexRadii(m.outer), sizes: outSizes, alphas: outAlpha)
    }

    /// Пытается провернуться и не может: дёрнулось, дрожит, откатилось. Не
    /// тревога — заминка.
    private static func problem(_ size: CGFloat, _ time: TimeInterval) -> [Dot] {
        let m = metrics(size)
        let t = CGFloat(time)
        let hitch = sin(t * .pi * 2 / 1.85)
        let stutter: CGFloat = hitch > 0.6 ? (hitch - 0.6) * 0.7 : hitch < -0.4 ? hitch * 0.07 : 0
        let tryWind = max(0, sin(t * .pi * 2 / 2.3))
        let w = tryWind > 0.55 ? (tryWind - 0.55) * 1.15 : 0
        let pulse = 1 + 0.1 * hitch
        var radii = mixRadii(hexRadii(m.reach * pulse), spiralRadii(m.reach * pulse), min(0.7, w))
        for i in 0..<count {
            radii[i] += 0.045 * sin(t * 11 + CGFloat(i) * 1.7) * m.reach
        }
        return ring(size, rot: stutter, radii: radii, sizes: Array(repeating: m.r * 0.88, count: count))
            + ring(
                size,
                rot: stutter * 0.4 + .pi / 6,
                radii: hexRadii(m.outer * (1 - 0.07 * hitch)),
                sizes: Array(repeating: m.rOut, count: count),
                alphas: Array(repeating: 0.4, count: count)
            )
    }
}

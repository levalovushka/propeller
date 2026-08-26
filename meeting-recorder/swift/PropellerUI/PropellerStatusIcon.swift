import SwiftUI
import PropellerPure

/// Статус встречи одной анимированной фигурой — Figma `meeting-item` (307:7135).
///
/// Заменила собой шиммер по заголовку и бегущую строку фазы под ним. Довод —
/// место: строка встречи стала однострочной, и словам там больше негде жить.
/// Довод получше — то, что различалось словами, теперь различается движением, а
/// движение читается боковым зрением: три очереди конвейера в галерее
/// экспортировались пиксель в пиксель (`design/state-gallery.md`) именно потому,
/// что показывать их было нечем.
///
/// Рисуется кружками в `Canvas`, как SF Symbol: цвет берётся из
/// `foregroundStyle`, размер — из `pointSize`. Ни одного собственного оттенка —
/// иконка живёт в той же краске, что и строка, на которой стоит.
///
/// **Кадры считает главный поток.** Это ровно тот привод, который для лопасти в
/// чёлке оказался негодным (`NotchSurface.swift`, «Не возвращать вращение в
/// SwiftUI»): там покадровый `TimelineView` дёргался, когда главный поток занят
/// расшифровкой. Иконка крутится в те же секунды, но рисует двенадцать кружков
/// вместо кривой Безье, и разница может оказаться решающей — а может и нет.
/// Проверяется замером под нагрузкой, а не рассуждением; решётка вынесена в
/// `PropellerPure`, чтобы порт на слой не трогал математику.
public struct PropellerStatusIcon: View {

    public var status: PropellerStatus
    public var pointSize: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.railMotionFrozen) private var frozen

    public init(status: PropellerStatus, pointSize: CGFloat = Tokens.StatusIcon.side) {
        self.status = status
        self.pointSize = pointSize
    }

    /// Стоит ли фигура. Замирает по трём причинам, и все три — чужие решения:
    /// состояние без движения, снижение анимации в системе, и заморозка для
    /// съёмки галереи.
    private var isParked: Bool {
        reduceMotion || frozen || !PropellerLattice.isAnimated(status)
    }

    public var body: some View {
        TimelineView(
            .animation(minimumInterval: Tokens.StatusIcon.frameInterval, paused: isParked)
        ) { context in
            let time = isParked ? 0 : context.date.timeIntervalSinceReferenceDate
            Canvas { canvas, canvasSize in
                let box = min(canvasSize.width, canvasSize.height)
                for dot in PropellerLattice.dots(status: status, size: box, time: time)
                where dot.alpha > Tokens.StatusIcon.alphaFloor {
                    let rect = CGRect(
                        x: dot.x - dot.radius,
                        y: dot.y - dot.radius,
                        width: dot.radius * 2,
                        height: dot.radius * 2
                    )
                    canvas.opacity = dot.alpha
                    canvas.fill(Path(ellipseIn: rect), with: .foreground)
                }
            }
        }
        .frame(width: pointSize, height: pointSize)
        .opacity(status == .idle ? Tokens.StatusIcon.idleOpacity : 1)
        .accessibilityLabel(status.accessibilityLabel)
    }
}

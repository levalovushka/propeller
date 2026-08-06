import Foundation
import CoreGraphics

/// Где встаёт панель действий над выделением.
///
/// Арифметика на четыре строки, вынесенная из вьюхи по общей причине: во вьюхе
/// её никто не проверит, а ошибается она ровно там, где её не видно — на
/// последних словах строки, у правого края окна. Панель тогда рисуется целиком
/// и наполовину лежит за пределами окна: кнопки есть, нажать нельзя.
public enum SummaryBarPlacement {

    /// Смещение левого края панели от левого края колонки.
    ///
    /// Панель начинается под началом выделения — так она оказывается под
    /// курсором, а не в углу, — но не заезжает за края колонки. Если панель
    /// шире колонки, она прижимается к левому краю: обрезать справа лучше, чем
    /// с обеих сторон.
    public static func x(
        anchor: CGFloat, barWidth: CGFloat, columnWidth: CGFloat
    ) -> CGFloat {
        let room = max(0, columnWidth - barWidth)
        return min(max(0, anchor), room)
    }

    /// Смещение верхнего края панели от верха колонки.
    ///
    /// Сначала — под выделением. Если снизу места нет (последнее слово в
    /// саммари), панель встаёт над ним. Если не помещается и там, — прижимается
    /// к низу колонки: обрезать сверху лучше, чем висеть за краем окна, где
    /// кнопки есть, а нажать нельзя.
    public static func y(
        selectionTop: CGFloat,
        selectionBottom: CGFloat,
        barHeight: CGFloat,
        columnHeight: CGFloat,
        gap: CGFloat
    ) -> CGFloat {
        let below = selectionBottom + gap
        guard columnHeight > 0 else { return below }
        if below + barHeight <= columnHeight {
            return below
        }
        let above = selectionTop - gap - barHeight
        if above >= 0 {
            return above
        }
        return max(0, columnHeight - barHeight)
    }
}

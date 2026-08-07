import Foundation
import CoreGraphics

/// Сколько места занимает выросшая чёлка и где она стоит.
///
/// Арифметика вынесена из вьюхи по той же причине, что и `SummaryBarPlacement`:
/// проверить её на глазах можно только на машине с чёлкой, а ошибается она на
/// тех, у кого её нет, и на 16-дюймовом, которого у автора нет вовсе. Здесь она
/// проверяется на всех четырёх геометриях сразу.
///
/// Иллюзия «чёлка расширилась» держится на одном: наша фигура чёрная, стоит
/// вплотную к вырезу и вырастает **из** него. Поэтому ширина отсчитывается не
/// от центра экрана, а от ширины выреза, и любой зазор здесь виден как
/// сломанная чёлка, а не как криво стоящая плашка.
public enum NotchGeometry {

    /// Ухо — то, на что чёлка отрастает в каждую сторону: знак слева, заметка
    /// справа. 36 pt — это 16 pt значка и по 10 pt воздуха; уже нельзя, потому
    /// что мишень заметки перестанет быть мишенью.
    public static let earWidth: CGFloat = 36

    /// Насколько чёлка расходится вширь, когда в ней печатают. По 8 pt в
    /// каждую сторону: поле должно стать полем, а не разъехаться в панель.
    public static let composeWidening: CGFloat = 16

    /// Насколько она при этом опускается. Строка ввода и её воздух.
    public static let composeDrop: CGFloat = 80

    /// Машина без чёлки: та же фигура, но вырезу неоткуда взяться, поэтому она
    /// становится пилюлей под меню-баром той же высоты. Заметка не может
    /// исчезнуть оттого, что у человека Air M1 или закрытая крышка.
    public static let pillBodyWidth: CGFloat = 96

    /// Высота пилюли, когда система не сказала своей: меню-бар macOS.
    public static let fallbackHeight: CGFloat = 24

    /// Вогнутая галтель там, где фигура встречает верхнюю кромку экрана. У
    /// самого выреза она ≈4 pt; наша шире, поэтому и переход длиннее — иначе
    /// плита выглядит приклеенной, а не выросшей.
    public static let topCornerRadius: CGFloat = 8

    /// Выпуклые нижние углы. Совпадают с нижними углами выреза (≈8 pt), с
    /// поправкой на то, что фигура ниже него не свисает.
    public static let bottomCornerRadius: CGFloat = 10

    /// Что нарисовано и где.
    public struct Frame: Equatable {
        /// Габарит панели целиком.
        public let width: CGFloat
        public let height: CGFloat
        /// Левый нижний угол в координатах экрана (у macOS начало внизу).
        public let originX: CGFloat
        public let originY: CGFloat
        /// Ширина самого выреза — по ней рисуются вогнутые верхние углы. Ноль,
        /// если чёлки нет: тогда верх фигуры прямой.
        public let notchWidth: CGFloat
        /// Высота выреза, она же высота фигуры в покое.
        public let notchHeight: CGFloat
        /// Середина фигуры: вырез, а на машине без него — пилюля той же роли.
        /// Уши отсчитываются от неё, а не от `notchWidth`, иначе на экране без
        /// чёлки знак и заметка разъезжаются к краям.
        public let bodyWidth: CGFloat

        public var hasNotch: Bool { notchWidth > 0 }

        /// Поля, которые нельзя занимать: у самой кромки фигура шире, чем ниже,
        /// на ширину вогнутой галтели. Значок, поставленный в этот клин,
        /// обрезается — замерено на первом же снимке.
        public var contentInset: CGFloat { NotchGeometry.topCornerRadius }

        /// Ширина уха слева и справа от тела — в ней живут знак и заметка.
        public var earWidth: CGFloat { (width - bodyWidth) / 2 - contentInset }
    }

    /// Во что развёрнута чёлка.
    public enum Stage: Equatable {
        /// Идёт запись: знак и заметка, больше ничего.
        case resting
        /// В ней печатают заметку.
        case composing
    }

    /// Экран, каким его видит чёлка. `notchWidth == 0` — чёлки нет.
    public struct Screen: Equatable {
        public let width: CGFloat
        public let top: CGFloat
        public let notchWidth: CGFloat
        public let notchHeight: CGFloat

        public init(width: CGFloat, top: CGFloat, notchWidth: CGFloat, notchHeight: CGFloat) {
            self.width = width
            self.top = top
            self.notchWidth = notchWidth
            self.notchHeight = notchHeight
        }
    }

    /// Габарит и положение панели.
    ///
    /// В покое фигура ровно на высоту выреза: она не свисает под чёлку, а
    /// продолжает её вбок. Вниз она уходит только когда в ней печатают.
    public static func frame(on screen: Screen, stage: Stage) -> Frame {
        let hasNotch = screen.notchWidth > 0
        let body = hasNotch ? screen.notchWidth : pillBodyWidth
        let height = max(screen.notchHeight, fallbackHeight)

        // Тело, два уха и по галтели с каждой стороны: клин у кромки — не место
        // для содержимого, поэтому фигура на него шире, а не уши уже.
        let restingWidth = body + 2 * earWidth + 2 * topCornerRadius
        let width = restingWidth + (stage == .composing ? composeWidening : 0)
        let fullHeight = height + (stage == .composing ? composeDrop : 0)

        return Frame(
            width: width,
            height: fullHeight,
            // Вырез стоит по центру экрана, значит и фигура тоже: любое смещение
            // здесь читается как незакреплённая накладка.
            originX: (screen.width - width) / 2,
            originY: screen.top - fullHeight,
            notchWidth: hasNotch ? screen.notchWidth : 0,
            notchHeight: height,
            bodyWidth: body
        )
    }

    /// Ширина выреза по тому, что отдаёт `NSScreen`: экран минус два угла,
    /// оставшихся свободными. Ноль (чёлки нет) — когда углы сходятся.
    public static func notchWidth(
        screenWidth: CGFloat,
        auxiliaryLeftWidth: CGFloat,
        auxiliaryRightWidth: CGFloat
    ) -> CGFloat {
        let cut = screenWidth - auxiliaryLeftWidth - auxiliaryRightWidth
        // Меньше пилюли — это не вырез, а погрешность округления на
        // масштабированном разрешении.
        return cut > pillBodyWidth ? cut : 0
    }
}

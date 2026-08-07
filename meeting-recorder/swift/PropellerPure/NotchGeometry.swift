import Foundation
import CoreGraphics

/// Сколько места занимает выросшая чёлка и где она стоит.
///
/// Арифметика вынесена из вьюхи по той же причине, что и `SummaryBarPlacement`:
/// проверить её на глазах можно только на машине с чёлкой, а ошибается она на
/// тех, у кого её нет, на 16-дюймовом, которого у автора нет вовсе, и на
/// масштабированном разрешении, куда никто не заглядывает. Здесь она проверяется
/// на всех этих геометриях сразу.
///
/// Иллюзия «чёлка расширилась» держится на одном: наша фигура чёрная, стоит
/// вплотную к вырезу и вырастает **из** него. Поэтому ширина отсчитывается не
/// от центра экрана, а от ширины выреза, и любой зазор здесь виден как
/// сломанная чёлка, а не как криво стоящая плашка.
///
/// **Ни один размер тут не константа железа.** Вырез 14″ — 185×32 pt, 16″ —
/// 220×38, у Air — своё, а на масштабированном разрешении («Больше места») те
/// же вырезы приходят другими числами. Всё считается из того, что отдал
/// `NSScreen`; наши константы — только про то, что мы к вырезу пририсовываем.
public enum NotchGeometry {

    /// Ухо — то, на что чёлка отрастает в каждую сторону: знак слева, заметка
    /// справа. 36 pt — это 16 pt значка и по 10 pt воздуха; уже нельзя, потому
    /// что мишень заметки перестанет быть мишенью.
    public static let earWidth: CGFloat = 36

    /// Насколько чёлка опускается, когда в ней печатают. Строка ввода и её
    /// воздух, и ни пикселем больше: вширь она при этом не расходится вовсе —
    /// движение в одну сторону читается как «опустилась», в две читалось как
    /// «выросла панель».
    public static let composeDrop: CGFloat = 40

    /// Вогнутая галтель там, где фигура встречает верхнюю кромку экрана. У
    /// самого выреза она ≈4 pt; наша шире, поэтому и переход длиннее — иначе
    /// плита выглядит приклеенной, а не выросшей.
    public static let topCornerRadius: CGFloat = 8

    /// Выпуклые нижние углы. Совпадают с нижними углами выреза (≈8 pt), с
    /// поправкой на то, что фигура ниже него не свисает.
    public static let bottomCornerRadius: CGFloat = 10

    /// Ниже этого вырезов не бывает: самый узкий из существующих — 185 pt, а на
    /// масштабированном разрешении он ужимается примерно до 165. Всё, что уже,
    /// — это арифметика на экране, у которого выреза нет вовсе.
    public static let minimumNotchWidth: CGFloat = 120

    /// Экран, на котором чёлке есть за что держаться.
    ///
    /// Создаётся только через `screen(...)`, и только когда вырез действительно
    /// есть. Дальше по коду «а вдруг чёлки нет» уже не спрашивают — этот вопрос
    /// заканчивается здесь, одним `nil`.
    public struct Screen: Equatable {
        public let width: CGFloat
        public let top: CGFloat
        public let notchWidth: CGFloat
        public let notchHeight: CGFloat
    }

    /// Что нарисовано и где.
    public struct Frame: Equatable {
        /// Габарит панели целиком.
        public let width: CGFloat
        public let height: CGFloat
        /// Левый нижний угол в координатах экрана (у macOS начало внизу).
        public let originX: CGFloat
        public let originY: CGFloat
        /// Ширина самого выреза — середина фигуры.
        public let notchWidth: CGFloat
        /// Высота выреза, она же высота фигуры в покое.
        public let notchHeight: CGFloat

        /// Поля, которые нельзя занимать: у самой кромки фигура шире, чем ниже,
        /// на ширину вогнутой галтели. Значок, поставленный в этот клин,
        /// обрезается — замерено на первом же снимке.
        public var contentInset: CGFloat { NotchGeometry.topCornerRadius }

        /// Ширина уха слева и справа от выреза — в ней живут знак и заметка.
        public var earWidth: CGFloat { (width - notchWidth) / 2 - contentInset }
    }

    /// Во что развёрнута чёлка.
    public enum Stage: Equatable {
        /// Ровно вырез: ушей нет, содержимого нет. Состояние, из которого плита
        /// вырастает при старте записи и в которое уходит на стопе, — а не
        /// «скрытая панель»: скрытой панели тут не бывает, есть только чёлка.
        case sealed
        /// Идёт запись: знак и заметка, больше ничего.
        case resting
        /// В ней печатают заметку.
        case composing
    }

    /// Есть ли на этом экране вырез, с которым можно работать.
    ///
    /// `nil` — это не ошибка и не деградация: у Air M1, у любого внешнего
    /// монитора и у ноутбука с закрытой крышкой чёлки нет, и вся фича там просто
    /// не существует. Заметки в таком случае живут в окне, где они и так есть.
    ///
    /// Оба признака обязательны. `safeAreaInsets.top` бывает ненулевым и без
    /// выреза, а разность свободных углов на экране без чёлки складывается в
    /// доли пикселя — по отдельности каждый из них однажды соврёт.
    public static func screen(
        width: CGFloat,
        top: CGFloat,
        safeAreaTop: CGFloat,
        auxiliaryLeftWidth: CGFloat?,
        auxiliaryRightWidth: CGFloat?
    ) -> Screen? {
        guard safeAreaTop > 0, width > 0 else { return nil }
        guard let left = auxiliaryLeftWidth, let right = auxiliaryRightWidth else { return nil }
        let cut = width - left - right
        guard cut >= minimumNotchWidth, cut < width else { return nil }
        return Screen(width: width, top: top, notchWidth: cut, notchHeight: safeAreaTop)
    }

    /// Габарит и положение панели.
    ///
    /// В покое фигура ровно на высоту выреза: она не свисает под чёлку, а
    /// продолжает её вбок. Вниз она уходит только когда в ней печатают.
    public static func frame(on screen: Screen, stage: Stage) -> Frame {
        // Тело, два уха и по галтели с каждой стороны: клин у кромки — не место
        // для содержимого, поэтому фигура на него шире, а не уши уже.
        let restingWidth = screen.notchWidth + 2 * earWidth + 2 * topCornerRadius
        let width: CGFloat
        switch stage {
        // Свёрнутая плита — это и есть вырез: ниже галтелей от неё остаётся
        // ровно он, поэтому рост начинается из железа, а не из точки.
        case .sealed: width = screen.notchWidth + 2 * topCornerRadius
        case .resting, .composing: width = restingWidth
        }
        let height = screen.notchHeight + (stage == .composing ? composeDrop : 0)

        return Frame(
            width: width,
            height: height,
            // Вырез стоит по центру экрана, значит и фигура тоже: любое смещение
            // здесь читается как незакреплённая накладка.
            originX: (screen.width - width) / 2,
            originY: screen.top - height,
            notchWidth: screen.notchWidth,
            notchHeight: screen.notchHeight
        )
    }
}

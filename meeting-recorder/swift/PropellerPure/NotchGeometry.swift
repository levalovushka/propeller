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
/// **Ни один размер выреза тут не константа железа.** 14″ — 185×32 pt, 16″ —
/// 220×38, у Air своё, а на масштабированном разрешении те же вырезы приходят
/// другими числами. Всё считается из того, что отдал `NSScreen`; наши константы
/// — только про то, что мы к вырезу пририсовываем (Figma 299:26711).
public enum NotchGeometry {

    /// Высота, под которую нарисован макет, и ширина скоса на ней.
    ///
    /// Скос — внешний край крыла, S-образная кривая. Он масштабируется **вместе
    /// с высотой по обеим осям**: растянутый только по горизонтали, он ложится
    /// почти плашмя, и чёлка становится вдвое шире, чем ей нужно.
    public static let designHeight: CGFloat = 47
    public static let designSlopeWidth: CGFloat = 47.8414

    /// Зазор между скосом и первой кнопкой.
    public static let edgeGap: CGFloat = 2
    /// Зазор между парой кнопок и вырезом: под ним камера, и подходить к ней
    /// вплотную нельзя.
    public static let notchGap: CGFloat = 4

    /// Плита **не свисает под вырез**: её высота — высота самого выреза, и
    /// растёт чёлка только вширь. Свисающая на 47 pt плита (как нарисована в
    /// макете) читается как выехавшая панель, а не как раздавшаяся чёлка, и в
    /// этом всё различие между «прибор в железе» и «окно поверх экрана».

    /// Кнопка: 28×28, знак 15. В макете 32, но там и плита свисала на 47 —
    /// в высоту выреза пара 32-х не помещается, не забрав всю ширину крыла.
    public static let buttonSide: CGFloat = 28
    /// Зазор внутри пары.
    public static let buttonGap: CGFloat = 2
    /// Ширина скоса при этой высоте плиты.
    public static func slopeWidth(height: CGFloat) -> CGFloat {
        designSlopeWidth * height / designHeight
    }

    /// Крыло целиком: скос, воздух, пара кнопок и зазор до выреза. Считается, а
    /// не задаётся: поменяется кнопка или высота выреза — крыло поедет за ними,
    /// и кнопки не окажутся ни на скосе, ни под камерой.
    public static func wingWidth(height: CGFloat) -> CGFloat {
        slopeWidth(height: height) + edgeGap + groupWidth + notchGap
    }

    /// Ширина пары кнопок.
    public static var groupWidth: CGFloat { 2 * buttonSide + buttonGap }

    /// Ниже этого вырезов не бывает: самый узкий из существующих — 185 pt, а на
    /// масштабированном разрешении он ужимается примерно до 165. Всё, что уже,
    /// — это арифметика на экране, у которого выреза нет вовсе.
    public static let minimumNotchWidth: CGFloat = 120

    /// Экран, на котором чёлке есть за что держаться.
    ///
    /// Создаётся только через `screen(...)`, и только когда вырез действительно
    /// есть. Дальше по коду «а вдруг чёлки нет» уже не спрашивают — этот вопрос
    /// заканчивается здесь, одним `nil`.
    /// `left` и `top` — края этого экрана в общих координатах рабочего стола, а
    /// не размеры: рамка панели живёт там же, и экран, у которого не забрали
    /// левый край, неотличим от главного. Ровно поэтому чёлка однажды выросла на
    /// внешнем мониторе у того, кто сделал главным его, а не ноутбук.
    public struct Screen: Equatable {
        public let left: CGFloat
        public let width: CGFloat
        public let top: CGFloat
        /// Левый край самого выреза в тех же координатах.
        public let notchLeft: CGFloat
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
        /// Высота выреза, она же высота плиты.
        public let notchHeight: CGFloat

        /// Ширина крыла слева и справа от выреза — в нём живёт пара кнопок.
        public var wingWidth: CGFloat { (width - notchWidth) / 2 }
        /// Ширина пары кнопок.
        public var groupWidth: CGFloat { NotchGeometry.groupWidth }
        /// Ширина скоса при этой высоте.
        public var slopeWidth: CGFloat { NotchGeometry.slopeWidth(height: height) }
        /// Сколько в крыле остаётся под кнопки после скоса и зазора до выреза.
        /// Меньше пары означало бы, что кнопки лезут на скос или под камеру.
        public var roomForButtons: CGFloat {
            wingWidth - slopeWidth - NotchGeometry.edgeGap - NotchGeometry.notchGap
        }

        /// Плита целиком лежит на своём экране.
        public func fits(on screen: Screen) -> Bool {
            originX >= screen.left && originX + width <= screen.left + screen.width
        }
    }

    /// Во что развёрнута чёлка.
    public enum Stage: Equatable {
        /// Ровно вырез: крыльев нет, кнопок нет. Состояние, из которого плита
        /// вырастает при старте записи и в которое уходит на стопе, — а не
        /// «скрытая панель»: скрытой панели тут не бывает, есть только чёлка.
        case sealed
        /// Идёт запись: крылья с кнопками.
        case open
    }

    /// Есть ли на этом экране вырез, с которым можно работать.
    ///
    /// `nil` — это не ошибка и не деградация: у Air M1, у любого внешнего
    /// монитора и у ноутбука с закрытой крышкой чёлки нет, и вся фича там просто
    /// не существует.
    ///
    /// Оба признака обязательны. `safeAreaInsets.top` бывает ненулевым и без
    /// выреза, а разность свободных углов на экране без чёлки складывается в
    /// доли пикселя — по отдельности каждый из них однажды соврёт.
    public static func screen(
        left: CGFloat,
        width: CGFloat,
        top: CGFloat,
        safeAreaTop: CGFloat,
        auxiliaryLeftWidth: CGFloat?,
        auxiliaryRightWidth: CGFloat?
    ) -> Screen? {
        guard safeAreaTop > 0, width > 0 else { return nil }
        guard let leftCorner = auxiliaryLeftWidth, let right = auxiliaryRightWidth else { return nil }
        let cut = width - leftCorner - right
        guard cut >= minimumNotchWidth, cut < width else { return nil }
        return Screen(left: left, width: width, top: top,
                      notchLeft: left + leftCorner, notchWidth: cut,
                      notchHeight: safeAreaTop)
    }

    /// Габарит и положение панели.
    public static func frame(on screen: Screen, stage: Stage) -> Frame {
        var width: CGFloat
        var height: CGFloat
        switch stage {
        // Свёрнутая плита — это и есть вырез: рост начинается из железа, а не
        // из точки посреди кромки.
        case .sealed:
            width = screen.notchWidth
            height = screen.notchHeight
        case .open:
            height = screen.notchHeight
            width = screen.notchWidth + 2 * wingWidth(height: height)
        }

        return Frame(
            width: width,
            height: height,
            // От выреза, а не от центра экрана: центр — это то же самое только
            // на главном мониторе, и только пока он один.
            originX: screen.notchLeft + (screen.notchWidth - width) / 2,
            originY: screen.top - height,
            notchWidth: screen.notchWidth,
            notchHeight: screen.notchHeight
        )
    }
}

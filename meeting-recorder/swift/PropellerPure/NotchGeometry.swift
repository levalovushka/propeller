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

    /// Крыло — то, на что чёлка отрастает в каждую сторону. Внутри живёт пара
    /// кнопок, а внешний край уходит книзу S-образной кривой (`NotchShape`).
    public static let wingWidth: CGFloat = 107.5

    /// Плита **не свисает под вырез**: её высота — высота самого выреза, и
    /// растёт чёлка только вширь. Свисающая на 47 pt плита (как нарисована в
    /// макете) читается как выехавшая панель, а не как раздавшаяся чёлка, и в
    /// этом всё различие между «прибор в железе» и «окно поверх экрана».

    /// Кнопка: 32×32 с полем 8, то есть знак 16.
    public static let buttonSide: CGFloat = 32
    /// Зазор внутри пары.
    public static let buttonGap: CGFloat = 2
    /// Отступ пары от внешнего края плиты. Не от края экрана: у плиты этот край
    /// наклонный, и пара стоит там, где под ней уже есть чернота.
    public static let groupInset: CGFloat = 37.5

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
        public var groupWidth: CGFloat {
            2 * NotchGeometry.buttonSide + NotchGeometry.buttonGap
        }
        /// Зазор между парой и вырезом. Отрицательный означал бы, что кнопки
        /// лезут под камеру, — этого не должно случаться ни на одной геометрии.
        public var groupClearance: CGFloat {
            wingWidth - NotchGeometry.groupInset - groupWidth
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
        let width: CGFloat
        let height: CGFloat
        switch stage {
        // Свёрнутая плита — это и есть вырез: рост начинается из железа, а не
        // из точки посреди кромки.
        case .sealed:
            width = screen.notchWidth
            height = screen.notchHeight
        case .open:
            width = screen.notchWidth + 2 * wingWidth
            height = screen.notchHeight
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

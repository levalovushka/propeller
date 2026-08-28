import Foundation

/// История переходов панели — «Назад» и «Вперёд» в навбаре.
///
/// Механика браузерная и потому целиком решаемая: стек мест, палец на текущем,
/// и правило про ветку — шаг назад плюс новый переход отрезают всё, что было
/// впереди. Ровно это здесь и лежит, без единого знания о том, что такое место.
///
/// Тип заведён, когда история перестала быть историей **встреч**. Пока в стек
/// клались только их id, выйти «назад» из настроек было нечем, и рельс держал
/// для этого свою вторую кнопку — то есть в приложении было два «назад» в
/// разных местах и с разным смыслом. Место теперь любое: встреча, раздел,
/// проект.
public struct NavHistory<Place: Equatable> {

    /// Пройденные места, от старого к новому.
    public private(set) var places: [Place] = []
    /// Палец на текущем. `-1` — истории ещё нет вовсе, и это не то же самое,
    /// что «стоим на первом»: до первого перехода назад идти некуда.
    public private(set) var index: Int = -1

    public init() {}

    public var current: Place? {
        places.indices.contains(index) ? places[index] : nil
    }

    public var canGoBack: Bool { index > 0 }
    public var canGoForward: Bool { index + 1 < places.count }

    /// Запомнить переход.
    ///
    /// Повтор текущего места не пишется: панель сообщает о себе на каждое
    /// изменение состояния, и без этого «Назад» уводил бы на ту же встречу
    /// столько раз, сколько раз в ней что-нибудь дрогнуло.
    public mutating func record(_ place: Place) {
        if current == place { return }
        // Ушли назад и свернули в сторону — то, что было впереди, больше не
        // было. Хранить его значит обещать «Вперёд», ведущее в чужую ветку.
        if canGoForward {
            places = Array(places.prefix(index + 1))
        }
        places.append(place)
        index = places.count - 1
    }

    /// Шаг назад. Возвращает место, которое надо открыть, или nil, если идти
    /// некуда — тогда и палец не двигается.
    public mutating func back() -> Place? {
        guard canGoBack else { return nil }
        index -= 1
        return places[index]
    }

    public mutating func forward() -> Place? {
        guard canGoForward else { return nil }
        index += 1
        return places[index]
    }

    /// Забыть место целиком — со всеми его повторами в стеке.
    ///
    /// Нужно ровно на удалении встречи: без этого «Назад» открывал бы то, чего
    /// больше нет. Палец переставляется на то место, где стоял, — с поправкой
    /// на выброшенное слева от него.
    public mutating func forget(where isGone: (Place) -> Bool) {
        var kept: [Place] = []
        var moved = index
        for (position, place) in places.enumerated() {
            if isGone(place) {
                if position <= index { moved -= 1 }
            } else {
                kept.append(place)
            }
        }
        places = kept
        index = min(max(moved, kept.isEmpty ? -1 : 0), kept.count - 1)
    }
}

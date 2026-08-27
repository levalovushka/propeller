import SwiftUI

/// # Где живут выпадающие плиты
///
/// Плита, поднятая **из** чипа, не может висеть в его оверлее. Проверено
/// владельцем 2026-08-27: список участников рисовался и не реагировал на клики
/// вовсе. Причина — не в самой плите: строка атрибутов ограничивает своё
/// попадание формой в 24 pt (`contentShape(Rectangle())` там стоит ради
/// невидимого «плюса»), а плита свисает **ниже** этой формы. Попадание идёт по
/// цепочке предков, и предок точку не признаёт: кнопки внутри плиты о щелчке не
/// узнают. Тот же оверлей потребовал и `zIndex` у головы, потому что соседи по
/// стеку рисуются после неё.
///
/// Поэтому плиту рисует **хозяин** — вид, накрывающий всю панель:
///
/// - попадание работает, потому что плита лежит в его площади, а не свисает из
///   чужой;
/// - порядок рисования не надо подпирать `zIndex` — хозяин и так поверх всего,
///   что накрывает;
/// - **клик мимо плиты её закрывает**, потому что под ней есть чем этот клик
///   поймать. В оверлее чипа ловить было нечем.
///
/// Якорь передаётся преференцией: чип говорит, где он встал, хозяин ставит
/// плиту под него. Иначе плита вставала бы под строку целиком, а ширина чипа
/// даты у каждой встречи своя.
///
/// Одна поверхность на все плиты панели, а не своя у каждой: «щёлкнул мимо —
/// закрылось» должно быть решено один раз.
public struct PlateAnchorKey: PreferenceKey {
    public static var defaultValue: [String: CGRect] { [:] }
    public static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Какая плита поднята. Одна на панель: две открытые выпадашки — это два
/// разговора сразу, и закрывать их пришлось бы по одной.
public final class PlateStack: ObservableObject {
    @Published public private(set) var open: String?

    public init(open: String? = nil) { self.open = open }

    public func toggle(_ id: String) { open = (open == id) ? nil : id }
    public func close() { open = nil }
    public func isOpen(_ id: String) -> Bool { open == id }
}

private struct PlateStackKey: EnvironmentKey {
    /// Своя пустая полка по умолчанию: строку атрибутов рисует ещё и галерея, у
    /// которой хозяина нет. Без значения по умолчанию она падала бы на чтении
    /// окружения, а нарисовать её без плит — законно.
    static let defaultValue = PlateStack()
}

extension EnvironmentValues {
    public var plateStack: PlateStack {
        get { self[PlateStackKey.self] }
        set { self[PlateStackKey.self] = newValue }
    }
}

extension View {
    /// «Я здесь» — координаты предмета, из которого поднимается плита.
    public func plateAnchor(_ id: String, in space: String) -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: PlateAnchorKey.self, value: [id: geo.frame(in: .named(space))]
                )
            }
        )
    }

    /// Хозяин плит. Ставится на тот же вид, что несёт систему координат `space`.
    ///
    /// `plate` вызывается для поднятого id; вернуть для незнакомого — `EmptyView`.
    public func plateHost<Content: View>(
        _ stack: PlateStack,
        space: String,
        gap: CGFloat,
        @ViewBuilder plate: @escaping (String) -> Content
    ) -> some View {
        coordinateSpace(name: space)
            .overlayPreferenceValue(PlateAnchorKey.self) { anchors in
                if let id = stack.open, let anchor = anchors[id] {
                    ZStack(alignment: .topLeading) {
                        // Ловушка клика мимо. Прозрачная, но с формой — иначе
                        // `Color.clear` не попадает под курсор вовсе.
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { stack.close() }
                        plate(id)
                            .offset(x: anchor.minX, y: anchor.maxY + gap)
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: Tokens.Motion.hover), value: stack.open)
    }
}

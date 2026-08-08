import SwiftUI
import PropellerPure

/// # Переключатель встреч — то, что видно, пока держат ⌥
///
/// Это не отдельный экран и не второй список, а **ещё один вид рельса**: те же
/// строки, той же ширины, той же типографикой, с тем же правилом двух чернил
/// (`SidebarMeetingParagraph`). Поэтому здесь нет ни одного своего цвета и почти
/// нет своих чисел — иначе список в рельсе и список в панели начали бы расходиться
/// по мелочам, а это один и тот же список.
///
/// Плита под ним — `SummonedPlate`, общая с панелью действий над выделением:
/// оба вызваны жестом и оба живут, только пока жест держат. Угол у плиты свой,
/// концентричный строке (`Tokens.Pane.Switcher.radius`).
///
/// # Что двигается
///
/// Выделение стоит на месте — **второй строкой** — а список едет под ним. Так
/// видно и то, откуда уходишь, и то, куда идёшь, и глазу не приходится каждый шаг
/// заново искать подсветку. У краёв списка ехать больше некуда, и тогда двигается
/// уже подсветка: это ровно то, что делает любой список, доехавший до конца.
///
/// **Всё это — один такт.** Подсветка не заливка строки, а одна плашка, которая
/// едет вместе со списком; чернила переключаются перекрёстным затуханием той же
/// длительности. Пока это было двумя анимациями — заливка гасла в одной строке и
/// зажигалась в другой, пока список ехал, — шаг читался как мигание.
///
/// Панель ничего не принимает мышью (`allowsHitTesting(false)` ставит хозяин): её
/// позвала клавиша, ей и распоряжаться.
public struct MeetingSwitcherPanel: View {

    /// Строки рельса, в порядке рельса — панель их не сортирует и не фильтрует.
    private let rows: [SidebarMeetingRowModel]
    /// Куда попадёшь, если отпустить ⌥.
    private let currentID: String
    /// Какая строка должна стоять сверху — решение `MeetingSwitch.anchorID`.
    private let anchorID: String

    /// Измеренные высоты строк: строка встречи — от одной до трёх строк текста,
    /// сложить их можно только после раскладки.
    @State private var rowHeights: [String: CGFloat] = [:]

    public init(rows: [SidebarMeetingRowModel], currentID: String, anchorID: String) {
        self.rows = rows
        self.currentID = currentID
        self.anchorID = anchorID
    }

    /// Ширина строки в рельсе: полоса минус её боковые отступы. Совпадение не
    /// декоративное — от него зависит, где переносится заголовок, а значит и
    /// высота строки.
    public static var rowWidth: CGFloat {
        Tokens.Sidebar.width - Tokens.Sidebar.bodyHPadding * 2
    }

    public var body: some View {
        SummonedPlate(
            cornerRadius: Tokens.Pane.Switcher.radius,
            padding: Tokens.Pane.Switcher.padding
        ) {
            list
        }
        // Первый кадр уходит на замер, и показывать его нельзя: высоты строк ещё
        // неизвестны. Открывается панель сразу в своём размере — вторым кадром,
        // и в нём же начинает проявляться.
        .opacity(isMeasured ? 1 : 0)
        .animation(.easeOut(duration: Tokens.Pane.Switcher.fade), value: isMeasured)
    }

    private var list: some View {
        ZStack(alignment: .topLeading) {
            highlight
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    MeetingSwitcherRow(row: row, isCurrent: row.id == currentID)
                        .background {
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: RowHeights.self,
                                    value: [row.id: geo.size.height]
                                )
                            }
                        }
                }
            }
        }
        .frame(width: Self.rowWidth, alignment: .top)
        .offset(y: -offset)
        .frame(width: Self.rowWidth, height: viewport, alignment: .top)
        // Высота — не движение, а факт: она становится известна на замере и
        // больше не меняется. Анимированная, она читалась бы как «панель
        // открылась огромной и сжалась».
        .animation(nil, value: viewport)
        // Тот же приём, что у списка в рельсе: у обрезанного края список не
        // обрывается на полуслове, а гаснет.
        .mask { edgeFades }
        // Один такт на всё, что двигает шаг: список, плашка, чернила.
        .animation(.easeOut(duration: Tokens.Pane.Switcher.step), value: currentID)
        .onPreferenceChange(RowHeights.self) { heights in
            rowHeights.merge(heights, uniquingKeysWith: { $1 })
        }
    }

    /// Одна плашка на всю панель, а не заливка у каждой строки: она **едет**, а не
    /// зажигается на новом месте. Вместе со сдвигом списка на тот же вектор это и
    /// даёт ощущение, что подсветка стоит, а список идёт под ней.
    private var highlight: some View {
        RoundedRectangle(cornerRadius: Tokens.Sidebar.meetingRadius, style: .continuous)
            .fill(Tokens.Pane.Bar.itemOnFill)
            .frame(width: Self.rowWidth, height: rowHeights[currentID] ?? 0)
            .offset(y: top(of: currentID))
    }

    /// Гаснет ровно тот край, где строку правда режет.
    ///
    /// Обычно не режет ни одного: список стоит целыми строками — смещение это
    /// сумма высот тех, что уехали, — и вуаль над целой строкой была бы ложью,
    /// она бы говорила «здесь обрыв» там, где обрыва нет. Режет только у конца
    /// списка, где смещению приходится упереться в упор посреди строки.
    private var edgeFades: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: cutsAtTop ? Tokens.Sidebar.listTopFade : 0)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: cutsAtBottom ? Tokens.Sidebar.listTopFade : 0)
        }
    }

    private var cutsAtTop: Bool { isMeasured && !sitsOnRowEdge(offset) }

    private var cutsAtBottom: Bool { isMeasured && !sitsOnRowEdge(offset + viewport) }

    /// Совпадает ли эта высота с границей между строками (или с концом списка).
    private func sitsOnRowEdge(_ y: CGFloat) -> Bool {
        if abs(contentHeight - y) < 0.5 { return true }
        var edge: CGFloat = 0
        for row in rows {
            if abs(edge - y) < 0.5 { return true }
            edge += rowHeights[row.id] ?? 0
        }
        return false
    }

    private var isMeasured: Bool { contentHeight > 0 }

    private var contentHeight: CGFloat {
        rows.reduce(0) { $0 + (rowHeights[$1.id] ?? 0) }
    }

    /// Высота панели за время одной прогулки не меняется: список тот же. До замера
    /// — предел, а не натуральная высота: тогда единственный неизмеренный кадр
    /// заведомо не выше итогового, и промахнуться можно только в невидимую сторону.
    private var viewport: CGFloat {
        isMeasured ? min(contentHeight, Tokens.Pane.Switcher.maxHeight)
                   : Tokens.Pane.Switcher.maxHeight
    }

    /// Насколько список уехал вверх. Зажат с двух сторон: выше первой строки и
    /// ниже последней ехать некуда.
    private var offset: CGFloat {
        guard isMeasured else { return 0 }
        return max(0, min(top(of: anchorID), contentHeight - viewport))
    }

    /// Где начинается эта строка, в координатах списка.
    private func top(of id: String) -> CGFloat {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return 0 }
        return rows.prefix(index).reduce(0) { $0 + (rowHeights[$1.id] ?? 0) }
    }
}

/// Строка рельса без всего, что нужно только рельсу: ни ховера, ни меню по правой
/// кнопке, ни пепла удаления, ни бегущего блика — панель живёт секунду под
/// нажатой клавишей, и всё это в ней было бы шумом. Остаётся абзац; выбранность
/// рисует общая плашка сверху.
private struct MeetingSwitcherRow: View {
    let row: SidebarMeetingRowModel
    let isCurrent: Bool

    var body: some View {
        // Два одинаковых по раскладке абзаца, разные только чернилами: цвет внутри
        // `AttributedString` не анимируется, а перекрёстное затухание — да. Иначе
        // чернила щёлкали бы в первом кадре шага, пока плашка едет ещё 0,18 с.
        ZStack(alignment: .topLeading) {
            SidebarMeetingParagraph(row: row, isSelected: false)
            SidebarMeetingParagraph(row: row, isSelected: true)
                .opacity(isCurrent ? 1 : 0)
        }
        .padding(.horizontal, Tokens.Sidebar.meetingHPadding)
        .padding(.vertical, Tokens.Sidebar.meetingVPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RowHeights: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

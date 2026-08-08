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
/// оба вызваны жестом и оба живут, только пока жест держат.
///
/// # Что двигается
///
/// Выделение стоит на месте — **второй строкой** — а список едет под ним. Так
/// видно и то, откуда уходишь, и то, куда идёшь, и глазу не приходится каждый шаг
/// заново искать подсветку. У краёв списка ехать больше некуда, и тогда двигается
/// уже подсветка: это ровно то, что делает любой список, доехавший до конца, и
/// поэтому не требует объяснения.
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

    /// Измеренные высоты строк. Строка встречи — от одной до трёх строк текста,
    /// так что сложить их можно только после раскладки; до этого панель прозрачна
    /// (см. `isMeasured`), а не мигает не той высотой.
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
        SummonedPlate {
            list
        }
        .opacity(isMeasured ? 1 : 0)
        .animation(.easeOut(duration: Tokens.Pane.Switcher.fade), value: isMeasured)
    }

    private var list: some View {
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
        .frame(width: Self.rowWidth, alignment: .top)
        .offset(y: -offset)
        .frame(width: Self.rowWidth, height: viewport, alignment: .top)
        // Тот же приём, что у списка в рельсе, и по той же причине: у края список
        // не обрывается на полуслове, а гаснет — и сам этим говорит, что за краем
        // ещё есть строки. Маска, а не `clipped`: обрез по букве читается как
        // сломанная вёрстка, а не как продолжение.
        .mask { edgeFades }
        // Keyed on the top row rather than on the offset: the offset also moves
        // once, from nothing to its first value, when the heights land — and that
        // one is not a step, it is the panel finding out how tall its rows are.
        .animation(.easeOut(duration: Tokens.Pane.Switcher.step), value: anchorID)
        .onPreferenceChange(RowHeights.self) { heights in
            rowHeights.merge(heights, uniquingKeysWith: { $1 })
        }
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

    private var cutsAtTop: Bool { !sitsOnRowEdge(offset) }

    private var cutsAtBottom: Bool {
        guard let viewport else { return false }
        return !sitsOnRowEdge(offset + viewport)
    }

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

    /// Высота панели за время одной прогулки не меняется: список тот же, и плита,
    /// которая дышит на каждый шаг, — это уже не переключатель, а анимация про себя.
    private var viewport: CGFloat? {
        guard isMeasured else { return nil }
        return min(contentHeight, Tokens.Pane.Switcher.maxHeight)
    }

    /// Насколько список уехал вверх. Зажат с двух сторон: выше первой строки и
    /// ниже последней ехать некуда.
    private var offset: CGFloat {
        guard isMeasured, let viewport else { return 0 }
        guard let index = rows.firstIndex(where: { $0.id == anchorID }) else { return 0 }
        let above = rows.prefix(index).reduce(0) { $0 + (rowHeights[$1.id] ?? 0) }
        return max(0, min(above, contentHeight - viewport))
    }
}

/// Строка рельса без всего, что нужно только рельсу: ни ховера, ни меню по правой
/// кнопке, ни пепла удаления, ни бегущего блика — панель живёт секунду под
/// нажатой клавишей, и всё это в ней было бы шумом. Остаётся то, что отличает
/// одну встречу от другой: её абзац и то, выбрана ли она.
private struct MeetingSwitcherRow: View {
    let row: SidebarMeetingRowModel
    let isCurrent: Bool

    var body: some View {
        SidebarMeetingParagraph(row: row, isSelected: isCurrent)
            .padding(.horizontal, Tokens.Sidebar.meetingHPadding)
            .padding(.vertical, Tokens.Sidebar.meetingVPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                // Заливка кнопки бара в состоянии «включено» — панель стоит на
                // стекле, и заливка строки рельса под ним другой плотности.
                isCurrent ? Tokens.Pane.Bar.itemOnFill : .clear,
                in: RoundedRectangle(cornerRadius: Tokens.Sidebar.meetingRadius, style: .continuous)
            )
            // Two rows swap the pill on a step where the list itself does not move
            // (walking off the first meeting). Cross-fading it there is what keeps
            // that step from being the only silent one.
            .animation(.easeOut(duration: Tokens.Pane.Switcher.step), value: isCurrent)
    }
}

private struct RowHeights: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

import PropellerPure
import SwiftUI

/// # Состав встречи под чипом — Figma `summary/participants` (285:19438)
///
/// Список, который открывается щелчком по «6 человек». До 2026-08-27 чип был
/// таким же фактом, как дата, — нажимать было не на что, потому что состава как
/// объекта не существовало.
///
/// Плита — `SummonedPlate`, общая с панелью действий, переключателем встреч и
/// полем заметки: это ровно тот предмет, который приложение не поднимало само и
/// который держится, пока держат позвавший его жест. Своих решений про стекло,
/// угол и тень здесь нет.
///
/// Первый заход дал ей отдельную заливку: сквозь стекло имя встречи 22/24
/// читалось поверх имён участников — «Левон» и «Разбираюсь с кейсами» в одной
/// строке пикселей. Решение владельца 2026-08-27 — не заводить второй материал
/// для читаемых плит, а сделать стекло менее прозрачным **везде**
/// (`Tokens.Glass.summonedBase`).
///
/// **Ряд — участник, а не имя.** У кластера (`Speaker 2`) ряд такой же: за ним
/// живой человек, чьего имени мы не знаем, и без ряда его нечем назвать. Ряд
/// владельца крестика не имеет — `Row.isRemovable` говорит это одним полем, и
/// решает его `MeetingRoster`, а не вид.
///
/// Модалки «Добавить спикера» из макета (285:21090) здесь нет: список уже
/// открыт, и второй поверх него — второе окно под ту же задачу. «Добавить»
/// раскрывает поле **на своём месте**, в ряду, и предложения падают под ним.
struct ParticipantsPlate: View {
    let model: MeetingPane.Meta.People
    /// Закрыть плиту. Зовётся после добавления и по Esc.
    let dismiss: () -> Void

    /// Что сейчас печатают в ряду «Добавить». nil — ряд ещё кнопка.
    @State private var typing: String?
    @FocusState private var fieldFocused: Bool

    private typealias T = Tokens.Pane.Meta.People

    var body: some View {
        SummonedPlate(cornerRadius: T.plateRadius, padding: T.padding) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.rows) { row in
                    PersonRow(row: row, remove: { model.remove(row) })
                }
                divider
                addRow
            }
            .frame(width: T.rowWidth)
        }
        // Esc закрывает список, а не окно: пока плита поднята, она и есть то,
        // на что смотрит человек.
        .onExitCommand(perform: dismiss)
    }

    private var divider: some View {
        Rectangle()
            .fill(T.divider)
            .frame(height: 1)
            .padding(.horizontal, T.rowInset)
            .frame(height: T.dividerBlock)
    }

    @ViewBuilder
    private var addRow: some View {
        if let text = typing {
            // Поле на месте ряда: геометрия та же, меняется только содержимое.
            // Так «Добавить» не двигает список под собой.
            VStack(alignment: .leading, spacing: 0) {
                RowShell(symbol: "plus") {
                    TextField("Имя", text: Binding(
                        get: { text }, set: { typing = $0 }
                    ))
                    .textFieldStyle(.plain)
                    .typo(Tokens.Pane.Typo.metaWide)
                    .foregroundStyle(Tokens.Pane.Meta.label)
                    .focused($fieldFocused)
                    .onSubmit { commit(text) }
                }
                ForEach(matches(for: text), id: \.self) { name in
                    Button { commit(name) } label: {
                        RowShell(symbol: "person") {
                            Text(name)
                                .typo(Tokens.Pane.Typo.metaWide)
                                .foregroundStyle(Tokens.Pane.Meta.label)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .onAppear { fieldFocused = true }
        } else {
            Button { typing = "" } label: {
                RowShell(symbol: "plus") {
                    Text("Добавить")
                        .typo(Tokens.Pane.Typo.metaWide)
                        .foregroundStyle(Tokens.Pane.Meta.label)
                }
            }
            .buttonStyle(.plain)
        }
    }

    /// Предложения под полем: те кандидаты, что начинаются с набранного.
    ///
    /// Пустой ввод показывает **всех** — открывший «Добавить» ещё ничего не
    /// сказал, а список тех, с кем созванивались, это и есть ответ на «кого?».
    /// Сравнение — свёрткой `MeetingRoster.key`, той же, что склеивает ряды:
    /// «полина» найдёт «Polina Kremenets».
    private func matches(for text: String) -> [String] {
        let needle = MeetingRoster.key(text)
        guard !needle.isEmpty else { return model.candidates }
        return model.candidates.filter { MeetingRoster.key($0).hasPrefix(needle) }
    }

    private func commit(_ raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        typing = nil
        guard !name.isEmpty else { return }
        model.add(name)
        dismiss()
    }
}

/// Ряд участника: значок, имя, и крестик под курсором.
private struct PersonRow: View {
    let row: MeetingRoster.Row
    let remove: () -> Void

    @State private var hovering = false

    private typealias T = Tokens.Pane.Meta.People

    var body: some View {
        RowShell(symbol: "person", hovering: hovering) {
            Text(row.name)
                .typo(Tokens.Pane.Typo.metaWide)
                .foregroundStyle(Tokens.Pane.Meta.label)
                .lineLimit(1)
                .truncationMode(.tail)
        } trailing: {
            // Крестик держит место всегда, а видим только под курсором: иначе
            // имя дёргалось бы на каждое наведение.
            if row.isRemovable {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: T.crossSize, weight: .regular))
                        .foregroundStyle(Tokens.Pane.Meta.quiet)
                        .frame(width: T.iconSide, height: T.iconSide)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(hovering ? 1 : 0)
                .accessibilityLabel("Убрать из состава")
            }
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.Motion.hover), value: hovering)
    }
}

/// Форма ряда: одна на всех, чтобы поле ввода и кнопка стояли там же, где имя.
private struct RowShell<Content: View, Trailing: View>: View {
    let symbol: String
    var hovering: Bool = false
    @ViewBuilder var content: () -> Content
    @ViewBuilder var trailing: () -> Trailing

    private typealias T = Tokens.Pane.Meta.People

    var body: some View {
        HStack(spacing: T.iconGap) {
            Image(systemName: symbol)
                .font(.system(size: Tokens.Pane.Meta.iconSize, weight: .regular))
                .foregroundStyle(Tokens.Pane.Meta.quiet)
                .frame(width: T.iconSide, height: T.iconSide)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .padding(.horizontal, T.rowInset)
        .frame(width: T.rowWidth, height: T.rowHeight, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: T.rowRadius, style: .continuous)
                .fill(hovering ? T.rowHover : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: T.rowRadius, style: .continuous))
    }
}

extension RowShell where Trailing == EmptyView {
    init(symbol: String, hovering: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.init(symbol: symbol, hovering: hovering, content: content, trailing: { EmptyView() })
    }
}

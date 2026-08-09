import SwiftUI

/// # Куда пишут заметку, пока встреча идёт
///
/// Внизу колонки, поперёк неё, а не сбоку от неё. Колонка с заметками сбоку
/// заставляла сводить глазами две ленты и занимала треть окна ради поля ввода,
/// которым пользуются раз в десять минут. Здесь поле лежит **поверх** разговора,
/// разговор уходит под него в растворение, и ничего от этого не сдвигается:
/// строка, которую читают, остаётся там, где её читали.
///
/// В покое это строка, а не элемент управления: серый плейсхолдер на своей
/// вертикали и ничего больше. Плита появляется по фокусу и берётся у того же
/// `SummonedPlate`, на котором стоят панель действий и переключатель встреч, —
/// вызванный инструмент в этом приложении выглядит одинаково, чем бы он ни был.
/// Геометрия у поднятого и опущенного состояния общая, поэтому в момент фокуса
/// текст не прыгает: под ним просто появляется стекло.
///
/// Живёт только пока идёт запись. У готовой встречи заметка — часть саммари, и
/// пишется там же, где всё остальное.
public struct NoteBar: View {
    private let placeholder: String
    private let text: Binding<String>
    private let onCommit: () -> Void

    @FocusState private var focused: Bool
    @State private var hintHovering = false

    public init(
        placeholder: String = "Начните писать заметку",
        text: Binding<String>,
        onCommit: @escaping () -> Void
    ) {
        self.placeholder = placeholder
        self.text = text
        self.onCommit = onCommit
    }

    public var body: some View {
        SummonedPlate(
            cornerRadius: Tokens.Pane.noteBarRadius,
            padding: Tokens.Pane.noteBarFieldPadding,
            minHeight: Tokens.Pane.noteBarMinHeight,
            raised: focused
        ) {
            row
        }
        .animation(.easeOut(duration: Tokens.Motion.hover), value: focused)
        .padding(.horizontal, Tokens.Pane.noteBarHPadding)
        .padding(.vertical, Tokens.Pane.noteBarVPadding)
        // Та же мерка, что у колонки под ним: на широком окне поле не
        // растягивается во всю панель, а стоит ровно под текстом, к которому
        // относится.
        .frame(maxWidth: Tokens.Pane.summaryMaxWidth + Tokens.Pane.summaryHPadding * 2)
        .frame(maxWidth: .infinity)
    }

    /// Поле и подсказка. По нижнему краю: поле растёт вниз, и подсказка
    /// относится к последней строке, а не к первой.
    private var row: some View {
        HStack(alignment: .bottom, spacing: Tokens.Pane.noteBarHintGap) {
            field
            if !trimmed.isEmpty {
                hint
            }
        }
    }

    private var field: some View {
        // Плейсхолдер рисуется свой, а не отдаётся `TextField`: системный берёт
        // цвет самого поля, то есть выходит той же яркости, что и текст встречи,
        // и приглашение читается как чья-то реплика без имени.
        TextField("", text: text, axis: .vertical)
            .overlay(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(placeholder)
                        .typoBlock(Tokens.Pane.Typo.transcriptBody)
                        .foregroundStyle(Tokens.Pane.placeholder)
                        .allowsHitTesting(false)
                }
            }
            .textFieldStyle(.plain)
            .focused($focused)
            .typoBlock(Tokens.Pane.Typo.transcriptBody)
            .foregroundStyle(Tokens.Pane.body)
            .lineLimit(1...Tokens.Pane.noteBarMaxLines)
            // Enter отправляет, ⇧Enter переносит строку — как в чёлке и как в
            // любом поле, из которого что-то уходит по Enter. Порядок важен:
            // `onKeyPress` перехватывает только сочетание с шифтом и отдаёт
            // голый Enter дальше, в `onSubmit`.
            .onKeyPress(.return, phases: .down) { press in
                guard press.modifiers.contains(.shift) else { return .ignored }
                text.wrappedValue.append("\n")
                return .handled
            }
            .onSubmit(commit)
            // Esc убирает и черновик, и каретку. Не «сохранить и выйти»: то,
            // что человек не дописал и передумал, дописывать за него нельзя.
            .onExitCommand {
                text.wrappedValue = ""
                focused = false
            }
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Подсказка, которая работает.
    ///
    /// Читается как «нажми Enter», но нажимается и сама: заметку, написанную
    /// мышью, надо чем-то отправить, а тупик здесь стоил бы человеку всей
    /// заметки (`design/no-dead-ends.md`).
    private var hint: some View {
        Button(action: commit) {
            Image(systemName: "return")
                .font(.system(size: Tokens.Pane.noteBarHintIconSize, weight: .regular))
                .foregroundStyle(hintHovering ? Tokens.Paint.Text.primary : Tokens.Pane.meta)
                .frame(width: Tokens.Pane.noteBarHintSide, height: Tokens.Pane.noteBarHintSide)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hintHovering = $0 }
        .animation(.easeOut(duration: Tokens.Motion.hover), value: hintHovering)
        .help("Сохранить заметку — Enter")
        .accessibilityLabel("Сохранить заметку")
    }

    private var trimmed: String {
        text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Пустое — не заметка. Enter в пустом поле не создаёт запись и не отнимает
    /// каретку: человек промахнулся, а не передумал.
    private func commit() {
        guard !trimmed.isEmpty else { return }
        onCommit()
    }
}

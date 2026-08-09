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
/// Что печатают в поле и куда это уходит.
///
/// Жил внутри панели готовой встречи, пока заметки были её колонкой. Колонки
/// нет — и композер переехал к единственному полю, которое осталось: к тому,
/// что стоит внизу экрана записи.
public struct NoteComposer {
    public let placeholder: String
    public let text: Binding<String>
    public let onCommit: () -> Void

    public init(
        placeholder: String = "Начните писать заметку",
        text: Binding<String>,
        onCommit: @escaping () -> Void
    ) {
        self.placeholder = placeholder
        self.text = text
        self.onCommit = onCommit
    }
}

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
        // Сколько места поле занимает прямо сейчас. Колонке под ним это нужно
        // знать: за её прозрачной зоной, не поспевшей за ростом поля, под верх
        // плиты заезжает текст — и просвечивает сквозь стекло, отчего плита на
        // третьей строке кажется светлее, чем на первой.
        .background {
            GeometryReader { geo in
                Color.clear.preference(key: NoteBarHeight.self, value: geo.size.height)
            }
        }
        // Та же мерка, что у колонки под ним: на широком окне поле не
        // растягивается во всю панель, а стоит ровно под текстом, к которому
        // относится.
        .frame(maxWidth: Tokens.Pane.summaryMaxWidth + Tokens.Pane.summaryHPadding * 2)
        .frame(maxWidth: .infinity)
    }

    /// Поле и подсказка. По нижнему краю: поле растёт вниз, и подсказка
    /// относится к последней строке, а не к первой.
    ///
    /// «Последняя строка» — это её **строчный блок**, а не высота глифов. Поэтому
    /// у подсказки та же высота, что у одной строки текста: прижатые низом, они
    /// оказываются отцентрованы друг относительно друга — и на одной строке, и
    /// на четырёх. Прижатая своими 20 pt к 17 pt глифов, стрелка расходилась с
    /// текстом на пару точек: текст казался опущенным, а она задранной.
    private var row: some View {
        HStack(alignment: .bottom, spacing: Tokens.Pane.noteBarHintGap) {
            field
            // Столбец под подсказку занят всегда, даже когда её не видно.
            // Иначе первый набранный символ отнимает у текста 36 pt, и вся
            // строка перебирает переносы в момент, когда на неё смотрят.
            hint
                .opacity(trimmed.isEmpty ? 0 : 1)
                .allowsHitTesting(!trimmed.isEmpty)
        }
    }

    /// Поле, которое растёт до четырёх строк, а дальше прокручивается внутри
    /// себя.
    ///
    /// `TextEditor`, а не `TextField`: у поля с `lineLimit` пятая строка не
    /// уезжает под край, а вытесняет первую совсем — написанное исчезает на
    /// глазах у того, кто его пишет. Высоту задаёт невидимая мерка тем же
    /// кеглем: она упирается в четыре строки, и с ней вместе упирается поле.
    /// Рамку задаёт мерка, а редактор ложится в неё поверх.
    ///
    /// Не `ZStack`: `TextEditor` жаден по высоте и в стопке растягивал плашку
    /// на всё, что ему предложат, — поле в одну строку выходило в двести точек.
    /// Наложением он получает ровно ту рамку, которую намерил текст, и
    /// прокручивается внутри неё.
    private var field: some View {
        sizer
            // Плейсхолдер рисуется свой, а не отдаётся полю: системный берёт
            // цвет самого поля, то есть выходит яркостью в реплику, и
            // приглашение читается как чья-то фраза без имени. `typo`, а не
            // `typoBlock`: половинный интерлиньяж уже отдан мерке, и второй раз
            // он опускает приглашение ниже строки, которая появится на его месте.
            .overlay(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(placeholder)
                        .typo(Tokens.Pane.Typo.transcriptBody)
                        .foregroundStyle(Tokens.Pane.placeholder)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topLeading) { editor }
            // Половинный интерлиньяж — снаружи всех троих сразу, а не внутри
            // каждого. Так строчный блок поля равен строчному блоку реплики над
            // ним и подсказки рядом, а мерка, приглашение и редактор остаются
            // выровненными между собой до пикселя.
            .padding(.vertical, max(0, Tokens.Pane.Typo.transcriptBody.lineSpacingExtra) / 2)
    }

    /// Невидимая копия текста — она и есть высота поля.
    private var sizer: some View {
        Text(text.wrappedValue.isEmpty ? " " : text.wrappedValue)
            .typo(Tokens.Pane.Typo.transcriptBody)
            .lineLimit(Tokens.Pane.noteBarMaxLines)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hidden()
            .accessibilityHidden(true)
    }

    private var editor: some View {
        TextEditor(text: text)
            .focused($focused)
            .typo(Tokens.Pane.Typo.transcriptBody)
            .foregroundStyle(Tokens.Pane.body)
            .scrollContentBackground(.hidden)
            // `NSTextView` держит свой отступ во фрагменте строки, и без этого
            // текст стоит правее и мерки, и приглашения, и реплик над ним.
            .padding(.horizontal, -Tokens.Pane.noteBarEditorInset)
            // Enter отправляет, ⇧Enter переносит строку. В редакторе нет
            // `onSubmit` — Return для него обычный символ, — поэтому обе ветки
            // решаются здесь: отданный дальше Return редактор впишет сам.
            .onKeyPress(.return, phases: .down) { press in
                guard !press.modifiers.contains(.shift) else { return .ignored }
                commit()
                return .handled
            }
            // Esc убирает и черновик, и каретку. Не «сохранить и выйти»: то,
            // что человек не дописал и передумал, дописывать за него нельзя.
            .onExitCommand {
                text.wrappedValue = ""
                focused = false
            }
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
                .frame(
                    width: Tokens.Pane.noteBarHintSide,
                    height: Tokens.Pane.Typo.transcriptBody.lineHeight
                )
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


/// Высота поля заметки — вверх по дереву, колонке, которая под ним.
struct NoteBarHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

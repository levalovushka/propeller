import SwiftUI
import PropellerPure

/// # Экран идущей записи
///
/// В колонке — то, что человек записал сам, на своих секундах. В полосе над
/// панелью — имя встречи (переименовывается так же, как у готовой), справа
/// таймер и две кнопки: пауза и стоп. Внизу, поперёк колонки, — поле заметки;
/// оно живёт только пока идёт запись.
///
/// Живого транскрипта здесь нет (снят 2026-10-29, `product-ideas.md`, решения
/// 2026-08-21): текст встречи появляется после стопа, из офлайн-прохода. Пока
/// нового дизайна панели нет, она честно показывает только своё — заметки — и
/// не обещает расшифровку строкой-заглушкой.
///
/// Запись перестала быть отдельным режимом приложения. Встреча создаётся в
/// рельсе в первую же секунду, и пока она пишется, можно уйти читать любую
/// другую — эта панель просто одна из тех, между которыми переключаются.

// MARK: - Действия идущей записи

/// Таймер, пауза и стоп — правый слот навбара.
///
/// Раньше это была своя шапка панели (`RecordingPaneHeader`): имя слева,
/// управление справа. Полоса теперь одна на все маршруты (`PaneNavBar`), имя
/// стоит в её левом слоте, а здесь осталось ровно то, что делают **с записью**.
public struct RecordingControls: View {
    private let elapsed: String
    private let isPaused: Bool
    private let onPause: () -> Void
    private let onStop: () -> Void

    public init(
        elapsed: String,
        isPaused: Bool,
        onPause: @escaping () -> Void,
        onStop: @escaping () -> Void
    ) {
        self.elapsed = elapsed
        self.isPaused = isPaused
        self.onPause = onPause
        self.onStop = onStop
    }

    public var body: some View {
        HStack(spacing: Tokens.Pane.headerActionsGap) {
            timer
            PaneIconButton(
                symbol: isPaused ? "play.fill" : "pause.fill",
                help: isPaused ? "Продолжить" : "Пауза",
                action: onPause
            )
            PaneIconButton(symbol: "stop.fill", help: "Остановить запись (⌘.)", action: onStop)
        }
        .fixedSize()
    }

    /// Моноширинные цифры: без них секунды дёргают всю строку, а с ними время
    /// стоит на месте и меняется только само.
    private var timer: some View {
        Text(elapsed)
            .typoBlock(Tokens.Pane.Typo.headerTitle, monospacedDigit: true)
            .foregroundStyle(isPaused ? Tokens.Pane.meta : Tokens.Pane.title)
            .contentTransition(.numericText())
            .padding(.trailing, Tokens.Space.s4)
            .animation(.easeOut(duration: Tokens.Motion.hover), value: isPaused)
            .accessibilityLabel("Идёт \(elapsed)")
    }
}

// MARK: - Колонка заметок

/// Заметки идущей встречи в порядке их секунд.
///
/// Пусто — значит пусто: ни «Слушаю…», ни обещания расшифровки. Подсказка,
/// что сюда пишут, уже стоит в поле внизу.
struct RecordingNotesColumn: View {
    let notes: [TranscriptNote]
    /// Запись на паузе — тише весь столбец, потому что он весь про «сейчас», а
    /// «сейчас» приостановлено.
    let isPaused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Pane.transcriptTurnGap) {
            ForEach(notes.indices, id: \.self) { index in
                // Заметка не влетает откуда-то, а проступает там, где стоит.
                TranscriptNoteRow(note: notes[index])
                    .transition(.opacity)
            }
        }
        .multilineTextAlignment(.leading)
        .opacity(isPaused ? 0.55 : 1)
        .animation(.easeOut(duration: Tokens.Motion.hover), value: isPaused)
        .animation(.easeOut(duration: Tokens.Motion.hover), value: notes.count)
        .padding(.horizontal, Tokens.Pane.summaryHPadding)
        .padding(.vertical, Tokens.Pane.summaryVPadding)
        .frame(maxWidth: Tokens.Pane.recordingMeasure, alignment: .leading)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Панель целиком

/// Одна колонка — заметки, — и поле заметки поперёк её низа.
public struct RecordingPaneBody: View {
    private let isPaused: Bool
    /// Заметки на своих секундах.
    private let transcriptNotes: [TranscriptNote]
    /// Что печатают прямо сейчас. Nil у панели, которую рисуют без записи —
    /// в галерее: писать там некуда и незачем.
    private let composer: NoteComposer?

    public init(
        isPaused: Bool = false,
        transcriptNotes: [TranscriptNote] = [],
        composer: NoteComposer? = nil
    ) {
        self.isPaused = isPaused
        self.transcriptNotes = transcriptNotes
        self.composer = composer
    }

    /// Пустышка в конце колонки — то, к чему доезжают.
    private static var bottomAnchor: String { "recording-column-bottom" }

    /// Добавили заметку — колонка доезжает до низа.
    private var follow: Int { transcriptNotes.count }

    public var body: some View {
        ZStack(alignment: .bottom) {
            column
            if let composer {
                NoteBar(
                    placeholder: composer.placeholder,
                    text: composer.text,
                    onCommit: composer.onCommit
                )
            }
        }
        // Поле само сообщает, сколько занимает: оно растёт с текстом, и колонка
        // обязана освобождать под ним ровно столько же. Считать эту высоту здесь
        // значило бы держать в двух местах одно число, которое меняется на
        // каждый перенос строки.
        .onPreferenceChange(NoteBarHeight.self) { height in
            barHeight = height
        }
    }

    /// Сколько сейчас занимает поле. Ноль, пока оно о себе не сообщило, и у
    /// панели без композера — писать там нечем и освобождать нечего.
    @State private var barHeight: CGFloat = 0

    private var column: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    RecordingNotesColumn(notes: transcriptNotes, isPaused: isPaused)
                    // Столько, чтобы последняя заметка доезжала из-под поля и
                    // из-под растворения над ним.
                    Color.clear
                        .frame(height: bottomClear)
                        .id(Self.bottomAnchor)
                }
            }
            .scrollIndicators(.hidden)
            .onChange(of: follow) { _, _ in
                withAnimation(.easeOut(duration: Tokens.Pane.followScroll)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
        }
        // Растворение, а не обрез: строка, уходящая под поле, должна гаснуть.
        // Маска, а не крашеный градиент, — под колонкой стекло окна, и любой
        // непрозрачный градиент поверх него был бы заплаткой другого цвета.
        .mask {
            VStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: Tokens.Pane.transcriptBottomFade)
                Color.clear.frame(height: barHeight)
            }
        }
    }

    private var bottomClear: CGFloat {
        barHeight + Tokens.Pane.transcriptBottomFade
    }
}

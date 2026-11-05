import SwiftUI
import PropellerPure

/// # Экран идущей записи
///
/// Лист той же вёрстки, что у готовой встречи: строка атрибутов, имя в теле,
/// под ним решения прошлой встречи серии и заметки на своих секундах. После
/// стопа этот лист не сменяется, а дозаполняется саммари (`plan-projects.md`
/// §4.5). В полосе справа — прибор и управление записью: вейвформа, таймер,
/// микрофон, пауза и красная «Остановить» на месте «Поделиться». Внизу,
/// поперёк листа, — поле заметки; оно живёт только пока идёт запись.
///
/// Живого транскрипта здесь нет (снят 2026-10-29): текст встречи появляется
/// после стопа, из офлайн-прохода. Дизайн панели без него — решения владельца
/// 2026-11-05 (прототипы ВГ-2).
///
/// Запись перестала быть отдельным режимом приложения. Встреча создаётся в
/// рельсе в первую же секунду, и пока она пишется, можно уйти читать любую
/// другую — эта панель просто одна из тех, между которыми переключаются.

// MARK: - Действия идущей записи

/// Вейвформа, таймер, микрофон, пауза и стоп — правый слот навбара.
///
/// Полоса одна на все маршруты (`PaneNavBar`), и справа в ней — действия того,
/// что открыто ниже. У готовой встречи там «Поделиться», у идущей записи на том
/// же месте и в той же пилюле — красное «Остановить»: это и есть «идёт запись»
/// с одного взгляда, без отдельной надписи. Имя встречи живёт в теле, как у
/// саммари (решения владельца 2026-11-05).
///
/// Всё здесь — существующие кнопки полосы: `PaneIconButton` и `SharePill`.
public struct RecordingControls: View {
    public typealias Levels = () -> (mic: [Float], system: [Float])

    private let elapsed: String
    private let isPaused: Bool
    private let isMicMuted: Bool
    /// На микрофонном пути глушить нечего (`AudioRecorder.canMuteMic`) —
    /// кнопка честно недоступна, а не пропадает.
    private let canMuteMic: Bool
    /// Последние уровни обеих сторон. Берутся замыканием, когда вейвформа сама
    /// спросит: публикация уровней будила бы всё, что подписано на
    /// запись, десять раз в секунду (`AudioRecorder.micLevelHistory`). Nil —
    /// уровней нет вовсе (галерея), полоски лежат.
    private let levels: Levels?
    private let onMute: () -> Void
    private let onPause: () -> Void
    private let onStop: () -> Void

    public init(
        elapsed: String,
        isPaused: Bool,
        isMicMuted: Bool = false,
        canMuteMic: Bool = true,
        levels: Levels? = nil,
        onMute: @escaping () -> Void = {},
        onPause: @escaping () -> Void,
        onStop: @escaping () -> Void
    ) {
        self.elapsed = elapsed
        self.isPaused = isPaused
        self.isMicMuted = isMicMuted
        self.canMuteMic = canMuteMic
        self.levels = levels
        self.onMute = onMute
        self.onPause = onPause
        self.onStop = onStop
    }

    public var body: some View {
        HStack(spacing: Tokens.Pane.headerActionsGap) {
            RecordingWaveform(isPaused: isPaused, levels: levels)
            timer
            PaneIconButton(
                symbol: isMicMuted ? "mic.slash" : "mic",
                help: micHelp,
                isOn: isMicMuted,
                isEnabled: canMuteMic,
                action: onMute
            )
            PaneIconButton(
                symbol: isPaused ? "play.fill" : "pause.fill",
                help: isPaused ? "Продолжить" : "Пауза",
                isOn: isPaused,
                action: onPause
            )
            SharePill(
                title: "Остановить",
                fill: .record,
                help: "Остановить запись (⌘.)",
                action: onStop
            )
        }
        .fixedSize()
    }

    private var micHelp: String {
        if !canMuteMic { return "Пишем только микрофон — выключить его нельзя" }
        return isMicMuted ? "Включить микрофон" : "Выключить микрофон"
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

/// Пять полосок в коробке иконочной кнопки: пишется ли сейчас звук.
///
/// Полоска — это момент истории уровней, а не событие, которое кто-то
/// публикует: вид сам спрашивает уровни 10 раз в секунду и перерисовывается,
/// только если высоты поменялись. На паузе часов нет вовсе — полоски лежат,
/// как и таймер стоит.
///
/// **Таймер, а не `TimelineView`, и это замер** (`WaveformCostTests`,
/// 2026-11-05): `TimelineView(.periodic(by: 0.1))` на этих же пяти полосках
/// держал процесс на 1,1 ядра, с анимацией высот и без неё; `Timer` с `@State`
/// — 0,009 ядра. Час встречи разницы — это и есть «подтормаживание», ради
/// которого снимали живой транскрипт.
struct RecordingWaveform: View {
    let isPaused: Bool
    let levels: RecordingControls.Levels?

    @State private var heights = WaveformBars.flat

    var body: some View {
        Group {
            if isPaused || levels == nil {
                bars(WaveformBars.flat, ink: Tokens.Pane.Waveform.quiet)
            } else {
                bars(heights, ink: Tokens.Pane.Waveform.live)
                    .onReceive(Self.clock) { _ in
                        guard let now = levels?() else { return }
                        let next = WaveformBars.heights(mic: now.mic, system: now.system)
                        if next != heights { heights = next }
                    }
            }
        }
        .frame(width: Tokens.Pane.headerButtonSide, height: Tokens.Pane.headerButtonSide)
        .accessibilityElement()
        .accessibilityLabel(isPaused ? "Запись на паузе" : "Звук записи")
    }

    private static let clock = Timer.publish(
        every: Tokens.Pane.Waveform.frameInterval, on: .main, in: .common
    ).autoconnect()

    private func bars(_ heights: [Double], ink: Color) -> some View {
        HStack(spacing: Tokens.Pane.Waveform.barGap) {
            ForEach(heights.indices, id: \.self) { index in
                Capsule()
                    .fill(ink)
                    .frame(
                        width: Tokens.Pane.Waveform.barWidth,
                        height: max(Tokens.Pane.Waveform.barWidth,
                                    Tokens.Pane.Waveform.maxHeight * heights[index])
                    )
            }
        }
    }
}

// MARK: - Решения с прошлого раза

/// С чем подошли к встрече: решения прошлой встречи серии, собранные
/// механически (`PreviousDecisions`). Задачи стоят в том же списке — у них
/// просто есть исполнитель.
public struct RecordingPrevious {
    /// «Решения с прошлого раза, 29 окт».
    public let heading: String
    /// Пункты как в конспекте — markdown: жирное имя исполнителя остаётся жирным.
    public let items: [String]

    public init(heading: String, items: [String]) {
        self.heading = heading
        self.items = items
    }
}

/// Раздел листа — тот же, что в саммари: тихая подпись 12/14 в 30 %, под ней
/// пункты 13/22. Своей вёрстки у записи нет: после стопа лист дозаполняется, а
/// не сменяется.
struct RecordingSheetSection<Content: View>: View {
    let heading: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Pane.summaryHeadingGap) {
            if let heading {
                Text(heading)
                    .typoBlock(Tokens.Pane.Typo.sectionTitle)
                    .foregroundStyle(Color(nsColor: Tokens.Pane.headingNSColor))
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Панель целиком

/// Лист встречи — голова как у саммари, под ней решения с прошлого раза и
/// заметки, — и поле заметки поперёк его низа.
///
/// Пусто — значит пусто: у встречи без серии и без заметок под именем ничего
/// нет, и строки-заглушки там не будет. Подсказка, что сюда пишут, уже стоит в
/// поле внизу.
public struct RecordingPaneBody: View {
    private let identity: MeetingPane.Identity?
    private let meta: MeetingPane.Meta?
    private let previous: RecordingPrevious?
    private let isPaused: Bool
    /// Заметки на своих секундах.
    private let transcriptNotes: [TranscriptNote]
    /// Что печатают прямо сейчас. Nil у панели, которую рисуют без записи —
    /// в галерее: писать там некуда и незачем.
    private let composer: NoteComposer?

    public init(
        identity: MeetingPane.Identity? = nil,
        meta: MeetingPane.Meta? = nil,
        previous: RecordingPrevious? = nil,
        isPaused: Bool = false,
        transcriptNotes: [TranscriptNote] = [],
        composer: NoteComposer? = nil
    ) {
        self.identity = identity
        self.meta = meta
        self.previous = previous
        self.isPaused = isPaused
        self.transcriptNotes = transcriptNotes
        self.composer = composer
    }

    /// Пустышка в конце листа — то, к чему доезжают.
    private static var bottomAnchor: String { "recording-column-bottom" }

    /// Добавили заметку — лист доезжает до низа.
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
        // Поле само сообщает, сколько занимает: оно растёт с текстом, и лист
        // обязан освобождать под ним ровно столько же. Считать эту высоту здесь
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
                VStack(alignment: .leading, spacing: 0) {
                    if identity != nil || meta != nil {
                        MeetingPaneHead(identity: identity, meta: meta)
                    }
                    sections
                    // Столько, чтобы последняя заметка доезжала из-под поля и
                    // из-под растворения над ним.
                    Color.clear
                        .frame(height: bottomClear)
                        .id(Self.bottomAnchor)
                }
                // Та же мера, что у саммари: превращение в саммари не сдвигает
                // ни одной строки.
                .frame(maxWidth: Tokens.Pane.paneMeasure, alignment: .leading)
                .frame(maxWidth: .infinity)
                // Пауза — тише весь лист: он про «сейчас», а «сейчас»
                // приостановлено.
                .opacity(isPaused ? 0.55 : 1)
                .animation(.easeOut(duration: Tokens.Motion.hover), value: isPaused)
            }
            .scrollIndicators(.hidden)
            .coordinateSpace(name: PaneProbe.space)
            .onChange(of: follow) { _, _ in
                withAnimation(.easeOut(duration: Tokens.Pane.followScroll)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
        }
        // Растворение, а не обрез: строка, уходящая под поле, должна гаснуть.
        // Маска, а не крашеный градиент, — под листом стекло окна, и любой
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

    @ViewBuilder
    private var sections: some View {
        let hasPrevious = !(previous?.items.isEmpty ?? true)
        if hasPrevious || !transcriptNotes.isEmpty {
            VStack(alignment: .leading, spacing: Tokens.Pane.summarySectionGap) {
                if let previous, hasPrevious {
                    RecordingSheetSection(heading: previous.heading) {
                        VStack(alignment: .leading, spacing: Tokens.Pane.summaryItemGap) {
                            ForEach(previous.items.indices, id: \.self) { index in
                                Text(Self.inline(previous.items[index]))
                                    .typoBlock(Tokens.Pane.Typo.body)
                                    .foregroundStyle(Color(nsColor: Tokens.Pane.bodyNSColor))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                if !transcriptNotes.isEmpty {
                    // Подпись нужна, только когда над заметками есть что-то
                    // ещё: одни заметки под именем — и так заметки.
                    RecordingSheetSection(heading: hasPrevious ? "Заметки" : nil) {
                        VStack(alignment: .leading, spacing: Tokens.Pane.transcriptTurnGap) {
                            ForEach(transcriptNotes) { note in
                                // Заметка не влетает откуда-то, а проступает там, где стоит.
                                TranscriptNoteRow(note: note, plated: false)
                                    .transition(.opacity)
                            }
                        }
                        .animation(.easeOut(duration: Tokens.Motion.hover), value: transcriptNotes.count)
                    }
                }
            }
            .multilineTextAlignment(.leading)
            .padding(.horizontal, Tokens.Pane.summaryHPadding)
            .padding(.top, Tokens.Pane.summarySectionGap)
        }
    }

    /// Пункт конспекта как строчный markdown: жирное имя исполнителя остаётся
    /// жирным, а звёздочки не печатаются.
    private static func inline(_ markdown: String) -> AttributedString {
        (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(markdown)
    }

    private var bottomClear: CGFloat {
        barHeight + Tokens.Pane.transcriptBottomFade
    }
}

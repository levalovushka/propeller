import SwiftUI
import QuartzCore
import PropellerPure

/// # Экран идущей записи
///
/// Та же панель, что у готовой встречи, и это главное про неё. Слева, на месте
/// саммари, — то, что говорят прямо сейчас; справа — те же заметки, тот же
/// композер, те же правила ширины. В шапке — имя встречи (переименовывается так
/// же, как у готовой), а справа таймер и две кнопки: пауза и стоп.
///
/// Запись перестала быть отдельным режимом приложения. Встреча создаётся в
/// рельсе в первую же секунду, и пока она пишется, можно уйти читать любую
/// другую — эта панель просто одна из тех, между которыми переключаются.

// MARK: - Шапка

/// Имя встречи слева, время и управление справа.
public struct RecordingPaneHeader: View {
    private let meetingID: String
    private let title: String
    private let onRename: ((_ meetingID: String, _ newTitle: String) -> Void)?
    private let elapsed: String
    private let isPaused: Bool
    private let onPause: () -> Void
    private let onStop: () -> Void

    public init(
        meetingID: String,
        title: String,
        elapsed: String,
        isPaused: Bool,
        onRename: ((_ meetingID: String, _ newTitle: String) -> Void)? = nil,
        onPause: @escaping () -> Void,
        onStop: @escaping () -> Void
    ) {
        self.meetingID = meetingID
        self.title = title
        self.elapsed = elapsed
        self.isPaused = isPaused
        self.onRename = onRename
        self.onPause = onPause
        self.onStop = onStop
    }

    public var body: some View {
        HStack(spacing: 0) {
            MeetingPaneIdentity(meetingID: meetingID, title: title, onRename: onRename)
            Spacer(minLength: Tokens.Space.s8)
            controls
        }
        .frame(height: Tokens.Pane.headerHeight)
    }

    private var controls: some View {
        HStack(spacing: Tokens.Pane.headerActionsGap) {
            timer
            PaneIconButton(
                symbol: isPaused ? "play.fill" : "pause.fill",
                help: isPaused ? "Продолжить" : "Пауза",
                action: onPause
            )
            PaneIconButton(symbol: "stop.fill", help: "Остановить запись (⌘.)", action: onStop)
        }
        .padding(.horizontal, Tokens.Pane.headerActionsPadding)
        .frame(height: Tokens.Pane.headerHeight)
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

// MARK: - Живая колонка

/// То, что говорят, — по мере того как это распознаётся.
///
/// Реплики устроены как в готовом транскрипте: кто, когда, что сказал. Разница
/// одна — последняя реплика дописывается на глазах. Догадок движка тут нет
/// вовсе (`GigasttLiveSession`): текст, который через полсекунды станет другим,
/// читающему не отличить от решённого, а строка под глазами меняется. Поэтому
/// показывается только то, что уже не изменится, — и печатная машинка
/// допечатывает его хвостом, а не проявляет реплику заново.
public struct LiveTranscriptColumn: View {
    private let turns: [LiveTranscript.Turn]
    private let ownerName: String
    private let remoteName: String
    /// Есть ли из чего выводить, кто говорит.
    ///
    /// Имя здесь **зарабатывается контрастом**, а не назначается. Дорожек две,
    /// и разделить людей можно ровно потому, что их две: в микрофон говорит
    /// владелец, из системного стема — дальняя сторона. Когда системной дорожки
    /// нет (захват не прицепился к звонку, встреча вживую, запись руками), канал
    /// остаётся один — и он слышит всех в комнате. Подписать этот единственный
    /// канал именем владельца значит приписать ему каждую чужую реплику до
    /// конца встречи, а имя человека — самая убедительная форма вранья, какая у
    /// нас есть.
    ///
    /// Поэтому без второй дорожки подписи нет вовсе. Реплики всё равно разделены
    /// паузой и подписаны временем; кто говорил — скажет диаризация после
    /// встречи, и это единственное место, где мы это знаем.
    private let namesSpeakers: Bool
    /// Что стоит на месте текста, пока его нет. Не «ошибка» и не «ожидание»:
    /// встреча пишется, а живой строки может не быть вовсе (микрофонный путь).
    private let placeholder: String
    /// Запись на паузе — тише весь столбец, потому что он весь про «сейчас», а
    /// «сейчас» приостановлено.
    private let isPaused: Bool
    /// То, что человек записал сам, — в той же ленте, на своих секундах.
    private let notes: [TranscriptNote]

    public init(
        turns: [LiveTranscript.Turn],
        ownerName: String,
        notes: [TranscriptNote] = [],
        remoteName: String = SourceAwareSpeaker.defaultRemoteName,
        namesSpeakers: Bool = true,
        placeholder: String = "Пока тихо",
        isPaused: Bool = false
    ) {
        self.turns = turns
        self.notes = notes
        self.ownerName = ownerName
        self.remoteName = remoteName
        self.namesSpeakers = namesSpeakers
        self.placeholder = placeholder
        self.isPaused = isPaused
    }

    /// Реплики и заметки одной лентой — тем же правилом, что у готовой
    /// колонки. Разное правило означало бы, что встреча до стопа и после него
    /// собрана по-разному, а замена живого текста готовым и так самая заметная
    /// склейка в приложении.
    private var feed: [NotePlacement.Item] {
        NotePlacement.interleave(
            turnStarts: turns.map(\.startSeconds),
            noteOffsets: notes.map(\.seconds)
        )
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Pane.transcriptTurnGap) {
            if turns.isEmpty, notes.isEmpty {
                Text(placeholder)
                    .typoBlock(Tokens.Pane.Typo.body)
                    .foregroundStyle(Tokens.Pane.placeholder)
            }
            ForEach(feed, id: \.self) { item in
                switch item {
                case .turn(let index): remark(turns[index])
                case .note(let index): TranscriptNoteRow(note: notes[index])
                }
            }
        }
        .multilineTextAlignment(.leading)
        .opacity(isPaused ? 0.55 : 1)
        .animation(.easeOut(duration: Tokens.Motion.hover), value: isPaused)
        .animation(.easeOut(duration: Tokens.Motion.hover), value: feed.count)
        .padding(.horizontal, Tokens.Pane.summaryHPadding)
        .padding(.vertical, Tokens.Pane.summaryVPadding)
        .frame(maxWidth: Tokens.Pane.summaryMaxWidth + Tokens.Pane.summaryHPadding * 2)
        .frame(maxWidth: .infinity)
    }

    private func remark(_ turn: LiveTranscript.Turn) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Pane.transcriptLineGap) {
            HStack(spacing: Tokens.Pane.transcriptMetaGap) {
                if namesSpeakers {
                    Text(name(of: turn.channel))
                        .typoBlock(Tokens.Pane.Typo.transcriptMeta)
                        .lineLimit(1)
                }
                Text(turn.timestamp)
                    .typoBlock(Tokens.Pane.Typo.transcriptMeta, monospacedDigit: true)
                    .frame(width: Tokens.Pane.transcriptTimeWidth, alignment: .leading)
            }
            .foregroundStyle(Tokens.Pane.meta)
            LiveTurnText(text: turn.text)
        }
        .fixedSize(horizontal: false, vertical: true)
        // Новая реплика не влетает — она появляется там, где стояла бы всё это
        // время.
        .transition(.opacity)
    }

    private func name(of channel: LiveTranscript.Channel) -> String {
        switch channel {
        case .owner:  return ownerName.isEmpty ? SourceAwareSpeaker.defaultOwnerName : ownerName
        case .remote: return remoteName
        }
    }
}

/// Одна реплика: то, что уже сказано, и хвост, который допечатывается.
private struct LiveTurnText: View {
    let text: String

    @StateObject private var typewriter = LiveTypewriter()

    var body: some View {
        Text(typewriter.painted(color: Tokens.Pane.body))
            .typoBlock(Tokens.Pane.Typo.transcriptBody)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear { typewriter.show(text, animated: false) }
            .onChange(of: text) { _, new in typewriter.show(new, animated: true) }
    }
}

/// Печатная машинка, которая **дописывает**, а не переписывает.
///
/// `SoftTypewriterSession` рядом делает другое: гасит старую строку и проявляет
/// новую — так меняется фраза состояния в рельсе. Здесь текст растёт, и
/// проявлять заново уже прочитанное было бы враньём про то, что оно новое.
/// Поэтому проявляется только хвост, а всё, что было, остаётся как было.
@MainActor
private final class LiveTypewriter: ObservableObject {
    /// Уже показанное целиком.
    @Published private(set) var settled = ""
    /// Хвост, который сейчас проявляется.
    @Published private(set) var tail = ""
    @Published private(set) var progress: Double = 1

    private var timer: Timer?
    private var generation = 0

    deinit { timer?.invalidate() }

    func show(_ text: String, animated: Bool) {
        let current = settled + tail
        guard text != current else { return }

        // Текст только вырос — проявляем прирост. Не вырос (движок переписал
        // реплику целиком) — показываем как есть: мигать половиной строки
        // хуже, чем поменять её.
        guard animated, text.hasPrefix(current) else {
            finish(with: text)
            return
        }
        settled = current
        tail = String(text.dropFirst(current.count))
        progress = 0
        animate()
    }

    private func finish(with text: String) {
        timer?.invalidate()
        timer = nil
        generation += 1
        settled = text
        tail = ""
        progress = 1
    }

    private func animate() {
        timer?.invalidate()
        generation += 1
        let gen = generation
        let duration = SummaryTypewriter.duration(
            count: tail.count,
            secondsPerChar: Tokens.Pane.LiveReveal.secondsPerChar,
            minimum: Tokens.Pane.LiveReveal.minimum,
            maximum: Tokens.Pane.LiveReveal.maximum
        )
        guard duration > 0 else { progress = 1; return }
        let started = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] tick in
            Task { @MainActor [weak self] in
                guard let self, self.generation == gen else { tick.invalidate(); return }
                let t = min(1, (CACurrentMediaTime() - started) / duration)
                self.progress = t
                if t >= 1 {
                    tick.invalidate()
                    self.timer = nil
                    // Проявленный хвост становится частью показанного: следующий
                    // прирост поедет от него, а не от начала реплики.
                    self.settled += self.tail
                    self.tail = ""
                }
            }
        }
        timer.tolerance = 1.0 / 120.0
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func painted(color: Color) -> AttributedString {
        var out = AttributedString(settled)
        out.foregroundColor = color
        guard !tail.isEmpty else { return out }
        out.append(
            SoftTypewriter.paint(
                tail,
                color: color,
                progress: progress,
                softness: Tokens.Pane.LiveReveal.softChars
            )
        )
        return out
    }
}

// MARK: - Панель целиком

/// Живая колонка слева, заметки справа — те же самые заметки.
public struct RecordingPaneBody: View {
    private let turns: [LiveTranscript.Turn]
    private let ownerName: String
    private let namesSpeakers: Bool
    private let placeholder: String
    private let isPaused: Bool
    private let notes: [MeetingNote]
    /// Заметки на своих секундах — они стоят в живой ленте, среди реплик.
    private let transcriptNotes: [TranscriptNote]
    private let composer: MeetingPaneBody.NoteComposer?
    private let onRevealNotes: (() -> Void)?
    private let onHideNotes: (() -> Void)?
    private let notesHidden: Bool
    private let notesInk: Double
    private let notesFocusRequest: Binding<Bool>?
    private let travel: Binding<WindowReveal.NotesTravel?>?

    public init(
        turns: [LiveTranscript.Turn],
        ownerName: String,
        namesSpeakers: Bool = true,
        placeholder: String = "Пока тихо",
        isPaused: Bool = false,
        notes: [MeetingNote],
        transcriptNotes: [TranscriptNote] = [],
        composer: MeetingPaneBody.NoteComposer? = nil,
        onRevealNotes: (() -> Void)? = nil,
        onHideNotes: (() -> Void)? = nil,
        notesHidden: Bool = false,
        notesInk: Double = 1,
        notesFocusRequest: Binding<Bool>? = nil,
        travel: Binding<WindowReveal.NotesTravel?>? = nil
    ) {
        self.turns = turns
        self.ownerName = ownerName
        self.namesSpeakers = namesSpeakers
        self.placeholder = placeholder
        self.isPaused = isPaused
        self.notes = notes
        self.transcriptNotes = transcriptNotes
        self.composer = composer
        self.onRevealNotes = onRevealNotes
        self.onHideNotes = onHideNotes
        self.notesHidden = notesHidden
        self.notesInk = notesInk
        self.notesFocusRequest = notesFocusRequest
        self.travel = travel
    }

    public var body: some View {
        PaneColumns(
            notes: notes,
            composer: composer,
            onRevealNotes: onRevealNotes,
            onHideNotes: onHideNotes,
            notesHidden: notesHidden,
            notesInk: notesInk,
            notesFocusRequest: notesFocusRequest,
            travel: travel,
            // Дописали реплику или начали новую — колонка доезжает до низа.
            // Отпечаток по последней реплике, а не по всему тексту: перебирать
            // всю встречу на каждый партиал незачем.
            follow: "\(turns.count)-\(turns.last?.text.count ?? 0)"
        ) {
            LiveTranscriptColumn(
                turns: turns,
                ownerName: ownerName,
                notes: transcriptNotes,
                namesSpeakers: namesSpeakers,
                placeholder: placeholder,
                isPaused: isPaused
            )
        }
    }
}

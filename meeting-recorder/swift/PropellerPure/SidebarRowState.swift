import Foundation

/// # The sidebar's state machine
///
/// A row in the left rail has to answer two independent questions, and the whole
/// point of this file is that they stay independent:
///
/// 1. **Is this the meeting you are looking at?** — selection and hover. Owned by
///    the window, not by the pipeline.
/// 2. **Is anything happening to it?** — `SidebarRowActivity`. Derived from the
///    durable stage plus whatever the one worker is doing, exactly the two
///    dimensions `CLAUDE.md` refuses to let anyone merge.
///
/// Folding them into a single `case selectedAndProcessing` is how you end up
/// with a row that stops shimmering because the user clicked it. They are two
/// fields, and `SidebarRowMachine` only ever computes the second.
///
/// The mapping is here, in `PropellerPure`, rather than next to the view,
/// because `Sources/` is an executable target that no test can import — and this
/// is precisely the kind of rule that is wrong in a way nobody notices for a
/// month.

// MARK: - Activity

/// What is happening to a meeting, from the rail's point of view.
///
/// Four cases, not eleven. The pipeline distinguishes queued-for-ASR from
/// queued-for-summary; a 276 pt row cannot, and pretending otherwise would put
/// two identical pixels in the state gallery under two different names.
public enum SidebarRowActivity: String, CaseIterable, Equatable, Sendable {
    /// Nothing is owed and nothing is running: the meeting is done, and the quiet
    /// line is free for its topics.
    case none
    /// Owed work the single worker has not reached yet.
    ///
    /// It used to look identical to «done» — `queuedIsQuiet`, on the grounds that
    /// the comps drew one meeting in motion and the rest flat. That made a waiting
    /// meeting indistinguishable from a finished one, which is the same lie as
    /// hiding the backlog: the row says «В очереди» now, and shimmers, because it
    /// *is* in progress — it is just not its turn.
    case queued
    /// Audio is arriving right now.
    case recording
    /// The worker is on this meeting: ASR, diarization, saving or summarising.
    case processing
    /// Nothing further will happen: the audio is gone, or there was no speech in
    /// it. **Not an error and not a request** — the row says what it is
    /// («Аудио удалено», «Речи не найдено») and offers nothing, because there is
    /// nothing to offer (`design/no-dead-ends.md`). The mark next to it is the
    /// same weight as the recording dot: a state, not an alarm.
    case rests
    /// Deleted, and still bringable back.
    ///
    /// The undo used to be a bar floating over the list. It belongs to the
    /// meeting: the row is already the thing that was deleted, it is already in
    /// the place the eye went to, and a row that says «Удалена · Вернуть» cannot
    /// be missed the way a bar in the corner can. It is also the only way the
    /// offer survives a collapsed rail — there is nowhere else for a bar to go.
    case deletedUndoable
}

extension SidebarRowActivity {
    /// Rows that shimmer: work is happening to this meeting, whether or not it is
    /// its turn this second. A queued meeting shimmers too — it is in the pipeline,
    /// and a still row would say «finished» about something that is not.
    public var isInFlight: Bool { self == .processing || self == .queued }
}

// MARK: - Row state

/// Everything the row needs to draw itself, and nothing about the meeting.
public struct SidebarRowState: Equatable, Sendable {
    /// This is the meeting open in the content pane.
    public let isSelected: Bool
    /// The pointer is over the row. Never persisted, never derived from data.
    public let isHovered: Bool
    public let activity: SidebarRowActivity

    public init(isSelected: Bool = false, isHovered: Bool = false, activity: SidebarRowActivity = .none) {
        self.isSelected = isSelected
        self.isHovered = isHovered
        self.activity = activity
    }

    public static let rest = SidebarRowState()
}

// MARK: - The machine

public enum SidebarRowMachine {

    /// Activity for one meeting, given the durable stage and what the single
    /// worker is up to.
    ///
    /// The order of the branches is the whole content of this function:
    ///
    /// - **Recording wins.** Audio is being written to disk; there is no state a
    ///   meeting could also be in that matters more.
    /// - **A meeting at rest beats work**, and cannot coexist with it: the worker
    ///   skips a recording whose failure is terminal, so `working` and `rests` are
    ///   mutually exclusive by construction. Ordering them anyway means a bug in
    ///   the scheduler shows up as a visible state rather than as a shimmer that
    ///   never ends.
    /// - **Only *our* work counts.** `.elsewhere` is the worker on a different
    ///   meeting, and this row must look untouched — that regression (every row
    ///   spinning because the app was busy) is state `10-other-busy` in the
    ///   catalogue.
    /// - **Queued is last**, because it is the weakest claim: everything above it
    ///   is a fact about this meeting right now, while «в очереди» only says the
    ///   worker has not got here yet.
    /// - **Deleted wins over everything.** The entry is out of the index; there
    ///   is no work the pipeline could still be doing on it, and the only thing
    ///   the row is for now is the few seconds in which it can come back.
    public static func activity(
        stage: RecordingStage,
        involvement: UIStateCatalog.Involvement,
        isTerminal: Bool,
        isDeletedUndoable: Bool = false,
        isQueued: Bool = false
    ) -> SidebarRowActivity {
        if isDeletedUndoable { return .deletedUndoable }
        if stage == .recording { return .recording }
        if isTerminal { return .rests }
        if case .working = involvement { return .processing }
        return isQueued ? .queued : .none
    }

    /// The full row state. Selection and hover come from the window and are
    /// passed straight through — the machine has no opinion about them.
    public static func state(
        stage: RecordingStage,
        involvement: UIStateCatalog.Involvement,
        isTerminal: Bool,
        isSelected: Bool,
        isHovered: Bool,
        isDeletedUndoable: Bool = false,
        isQueued: Bool = false
    ) -> SidebarRowState {
        SidebarRowState(
            // A deleted meeting is not the one you are looking at, whatever the
            // pane still has open: selection would draw it as the current row
            // right as it goes away.
            isSelected: isDeletedUndoable ? false : isSelected,
            isHovered: isHovered,
            activity: activity(
                stage: stage,
                involvement: involvement,
                isTerminal: isTerminal,
                isDeletedUndoable: isDeletedUndoable,
                isQueued: isQueued
            )
        )
    }

    /// The quiet half of the title line: what this meeting was about, or what is
    /// being done to it.
    ///
    /// A meeting mid-pipeline has no topics yet — that is the last thing the
    /// summary produces — so the row would show a bare title and nothing else
    /// for the whole minute the work takes. Spending that line on the phase is
    /// the difference between "it is stuck" and "it is thinking".
    public static func preview(
        activity: SidebarRowActivity,
        phaseMessage: String?,
        topics: String,
        elapsed: String? = nil,
        restingReason: String? = nil,
        isPaused: Bool = false
    ) -> String {
        switch activity {
        case .recording:
            // Пауза — тоже состояние записи, и строка обязана его называть:
            // «Идёт запись» под остановленным таймером это ровно то враньё,
            // ради которого строку вообще пишут.
            if isPaused { return "Пауза" }
            return elapsed.map { "Идёт запись · \($0)" } ?? "Идёт запись"
        case .processing:
            return phaseMessage.flatMap { $0.isEmpty ? nil : $0 } ?? "Обрабатываем…"
        case .queued:
            return "В очереди"
        case .rests:
            // The words come from the meeting's own resting reason
            // (`MeetingRest.disclosure`); this is the fallback for a row whose
            // reason was not passed — never «Не удалось», which is the sentence
            // this whole change exists to delete.
            return restingReason ?? "Обработка не требуется"
        case .deletedUndoable:
            return "Удалена"
        case .none:
            return topics
        }
    }
}

extension PipelineActivity {
    /// How the one worker relates to *this* meeting.
    ///
    /// The rail asks this once per row, and the answer has to distinguish "busy
    /// on you" from "busy on someone else" — conflating them is how every row in
    /// the list ended up spinning because the app was doing one thing.
    public func involvement(with recordingID: String) -> UIStateCatalog.Involvement {
        guard case .working(let id, let phase, _) = self else { return .idle }
        return id == recordingID ? .working(phase) : .elsewhere(phase)
    }
}

/// The meeting's name, ended so the preview can run on from it.
///
/// The comps write «Воркшоп по VK Музыке. Обсудили этапы…» as one sentence and
/// one paragraph; real titles arrive without the full stop, and without it the
/// two halves collide into «Воркшоп по VK Музыке Обсудили этапы».
public enum SidebarTitleText {
    public static func terminated(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return trimmed }
        return ".!?…:;".contains(last) ? trimmed : trimmed + "."
    }
}

// MARK: - Catalogue

/// Every appearance the rail's two components can take, as data — the same
/// contract `UIStateCatalog` has with the window, and for the same reason: a
/// state you cannot enumerate is a state you cannot look at.
public enum SidebarStateCatalog {

    public struct Case<State: Equatable & Sendable>: Identifiable, Equatable, Sendable {
        /// Stable slug — gallery section id and screenshot filename.
        public let id: String
        /// What a person sees, in their words.
        public let label: String
        public let state: State

        public init(id: String, label: String, state: State) {
            self.id = id
            self.label = label
            self.state = state
        }
    }

    // MARK: Meeting rows

    /// Every visual a meeting row can take: each activity, with and without
    /// selection. Hover is another axis and is shown on the rest case only — it
    /// is a pointer state, not a state of the meeting.
    public static let meetingRows: [Case<SidebarRowState>] = {
        var cases: [Case<SidebarRowState>] = []
        for activity in SidebarRowActivity.allCases {
            // A deleted row cannot also be the selected one — the machine
            // refuses that combination, so the board must not draw it.
            for selected in (activity == .deletedUndoable ? [false] : [false, true]) {
                cases.append(.init(
                    id: "row-\(activity.rawValue)\(selected ? "-selected" : "")",
                    label: "\(activityLabel(activity))\(selected ? ", открыта" : "")",
                    state: SidebarRowState(isSelected: selected, activity: activity)
                ))
            }
        }
        cases.append(.init(
            id: "row-none-hover",
            label: "Ничего не происходит, курсор на строке",
            state: SidebarRowState(isHovered: true, activity: .none)
        ))
        return cases
    }()

    public static func activityLabel(_ activity: SidebarRowActivity) -> String {
        switch activity {
        case .none:            return "Готова, ничего не происходит"
        case .queued:          return "В очереди"
        case .recording:       return "Идёт запись"
        case .processing:      return "Обработка записи"
        case .rests:           return "Дальше нечего делать"
        case .deletedUndoable: return "Удалена, можно вернуть"
        }
    }

    // MARK: Nav rows

    public struct NavState: Equatable, Sendable {
        public let isSelected: Bool
        public let isHovered: Bool
        public init(isSelected: Bool = false, isHovered: Bool = false) {
            self.isSelected = isSelected
            self.isHovered = isHovered
        }
    }

    public static let navRows: [Case<NavState>] = [
        .init(id: "nav-rest",     label: "Обычная",              state: .init()),
        .init(id: "nav-hover",    label: "Курсор на строке",     state: .init(isHovered: true)),
        .init(id: "nav-selected", label: "Выбранный раздел",     state: .init(isSelected: true)),
        .init(id: "nav-selected-hover", label: "Выбранный, курсор на строке",
              state: .init(isSelected: true, isHovered: true)),
    ]

    // MARK: Pipeline → row

    /// Every pipeline state from `UIStateCatalog`, run through the machine.
    ///
    /// This is the honest view of what the rail can and cannot say: eleven
    /// states arrive, four appearances come out, and the gallery renders the
    /// collapse instead of hiding it.
    public static var pipelineMapping: [(state: UIStateCatalog.MeetingState, activity: SidebarRowActivity)] {
        UIStateCatalog.meetingStates.map { meeting in
            (meeting, SidebarRowMachine.activity(
                stage: meeting.stage,
                involvement: meeting.involvement,
                isTerminal: meeting.hasFailure
            ))
        }
    }
}

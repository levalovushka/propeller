import Foundation
import PropellerPure
import PropellerUI

/// Turns the app into a `SidebarModel`.
///
/// The one place that knows both `AppState` and the rail, and it is deliberately
/// thin: every decision it could get wrong — which appearance a meeting gets,
/// what the quiet line says, which day a meeting belongs to — has already been
/// made by a pure function that a test can call. What is left here is reading
/// fields off the store, which is the part that cannot be tested from
/// `Sources/` anyway.
@MainActor
enum SidebarPresenter {

    /// Where the fixed rows go. Ids rather than closures so the view stays
    /// value-typed and the window keeps the actions.
    enum NavAction: String {
        case record, search, settings, feedback
        /// The record row when the microphone is not ours: same slot, different
        /// job — it goes to the permission instead of starting a recording.
        case micAccess
    }

    static func model(
        state: AppState,
        store: RecordingStore,
        now: Date = Date()
    ) -> SidebarModel {
        SidebarModel(
            nav: nav(state: state),
            groups: groups(state: state, store: store, now: now),
            emptyMessage: "Пока нет встреч",
            prompt: prompt(state.setupPrompt)
        )
    }

    // MARK: - The docked question

    /// Every word of it comes off `SetupPrompt`; this only chooses which of the
    /// two control shapes the step wears. Both are declared on the step, so a
    /// step with neither — or with both — cannot be built by accident.
    private static func prompt(_ step: SetupPrompt?) -> SidebarPromptModel? {
        guard let step else { return nil }
        let action: SidebarPromptModel.Action
        if let title = step.actionTitle {
            action = .button(title)
        } else if let placeholder = step.fieldPlaceholder {
            action = .field(placeholder: placeholder)
        } else {
            return nil
        }
        return SidebarPromptModel(
            id: step.rawValue,
            title: step.title,
            subtitle: step.subtitle,
            counter: step.counter,
            action: action
        )
    }

    // MARK: - Nav

    private static func nav(state: AppState) -> [SidebarNavItem] {
        [
            recordRow(state: state),
            SidebarNavItem(
                id: NavAction.search.rawValue,
                symbol: "magnifyingglass",
                title: "Поиск",
                shortcut: "⌘K"
            ),
            SidebarNavItem(
                id: NavAction.settings.rawValue,
                symbol: "gearshape.fill",
                title: "Настройки",
                // Обычная строка, как все: настройки — состояние панели, а не
                // окно, и открывает их клик, а не `SettingsLink`. Пока они
                // открыты, строка выбрана — ровно как выбрана строка встречи,
                // которую панель показывает.
                isSelected: state.paneRoute == .settings
            ),
            SidebarNavItem(
                id: NavAction.feedback.rawValue,
                symbol: "ladybug.fill",
                title: "Сообщить о проблеме"
            ),
        ]
    }

    /// The row that starts a recording — and the one place the app says it cannot.
    ///
    /// «Нет доступа к микрофону» is a property of recording, so it is written on
    /// the control that records. It replaced a floating message, which had to be
    /// seen in the second it appeared — the second a call starts, when this window
    /// is closed.
    /// This waits, in the place a person goes when they wonder why nothing was
    /// recorded, and clicking it opens the pane that grants the access.
    private static func recordRow(state: AppState) -> SidebarNavItem {
        if state.micAccessDenied, !state.isRecording {
            return SidebarNavItem(
                id: NavAction.micAccess.rawValue,
                symbol: "mic.slash",
                title: "Нет доступа к\u{00A0}микрофону"
            )
        }
        // Always «Новая запись» — stop lives in the recording pane (and ⌘.).
        // The row that is recording already says so on itself.
        return SidebarNavItem(
            id: NavAction.record.rawValue,
            symbol: SidebarNavItem.propellerMarkSymbol,
            title: "Новая запись",
            shortcut: "⌘R"
        )
    }

    // MARK: - Meetings

    private static func groups(
        state: AppState,
        store: RecordingStore,
        now: Date
    ) -> [SidebarMeetingGroup] {
        var order: [String] = []
        var byDay: [String: (header: String?, rows: [SidebarMeetingRowModel])] = [:]

        // Soft-deleted meetings leave the store after ash. During ash they stay
        // so the same row can collapse its height. See `hasSomethingToShow`.
        let listed = store.recordings.filter(\.hasSomethingToShow)

        for entry in listed {
            let day = SidebarDayGrouping.day(for: entry.date, now: now)
            if byDay[day.key] == nil {
                order.append(day.key)
                byDay[day.key] = (day.header, [])
            }
            byDay[day.key]?.rows.append(row(for: entry, state: state))
        }

        return order.compactMap { key in
            guard let bucket = byDay[key] else { return nil }
            return SidebarMeetingGroup(id: key, header: bucket.header, rows: bucket.rows)
        }
    }

    private static func row(for entry: RecordingEntry, state: AppState) -> SidebarMeetingRowModel {
        let involvement = state.activity.involvement(with: entry.id)
        let rest = state.rest(of: entry)
        let rowState = SidebarRowMachine.state(
            stage: entry.status,
            involvement: involvement,
            isTerminal: entry.hasTerminalFailure,
            // Только когда панель действительно показывает эту встречу: пока в
            // ней настройки, выбранных строк в рельсе одна — их собственная.
            isSelected: state.paneRoute == .meeting && state.selectedRecordingID == entry.id,
            isHovered: false,      // the view tracks the live pointer itself
            isDeletedUndoable: false,
            // «В очереди» comes from the one place that knows whether work is
            // still owed — the same answer the card reads (`MeetingRest`).
            isQueued: rest.owesWork && !state.activity.concerns(entry.id)
        )
        return SidebarMeetingRowModel(
            id: entry.id,
            meta: SidebarMeta.line(start: entry.date, duration: entry.duration),
            title: SidebarTitleText.terminated(entry.title.isEmpty ? "Без названия" : entry.title),
            preview: SidebarRowMachine.preview(
                activity: rowState.activity,
                phaseMessage: state.activity.concerns(entry.id) ? state.activity.sidebarMessage : nil,
                topics: entry.subtitleText,
                restingReason: rest.disclosure,
                isPaused: state.isRecordingPaused && entry.id == state.activeRecordingID
            ),
            state: rowState,
            hasSummary: state.hasRecap(for: entry)
        )
    }

}

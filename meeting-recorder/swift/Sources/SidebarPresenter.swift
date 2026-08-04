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
            emptyMessage: "Пока нет встреч"
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
                // A `SettingsLink`, not a closure — see `SidebarNavItem.Role`.
                role: .settings
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
        return SidebarNavItem(
            id: NavAction.record.rawValue,
            // The comps leave a gear on this row — the same glyph as
            // Настройки two rows down, which is a placeholder rather than a
            // decision. Change one line here if it turns out to be one.
            symbol: state.isRecording ? "stop.circle" : "record.circle",
            title: state.isRecording ? "Завершить запись" : "Начать запись",
            shortcut: "⌘R",
            // Recording is the one nav row that can be *on*: it is the state
            // the window is in, not a place you navigated to.
            isSelected: state.isRecording
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

        // A deletion that can still be taken back stays in the list, in its own
        // place, wearing «Вернуть». It is already out of the store — that is what
        // makes the undo window a window — so it is put back here, and only here.
        var listed = store.recordings
        if let pending = state.pendingDeletion {
            listed.append(pending)
            listed.sort { $0.date > $1.date }
        }

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
            isSelected: state.selectedRecordingID == entry.id,
            isHovered: false,      // the view tracks the live pointer itself
            isDeletedUndoable: state.pendingDeletion?.id == entry.id
        )
        return SidebarMeetingRowModel(
            id: entry.id,
            meta: SidebarMeta.line(start: entry.date, duration: entry.duration),
            title: SidebarTitleText.terminated(entry.title.isEmpty ? "Без названия" : entry.title),
            preview: SidebarRowMachine.preview(
                activity: rowState.activity,
                phaseMessage: state.activity.concerns(entry.id) ? state.activity.message : nil,
                topics: entry.subtitleText,
                restingReason: rest.disclosure
            ),
            state: rowState
        )
    }

}

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
        case projects
        case record, settings, feedback
        /// The record row when the microphone is not ours: same slot, different
        /// job — it goes to the permission instead of starting a recording.
        case micAccess
    }

    static func model(
        state: AppState,
        store: RecordingStore,
        now: Date = Date()
    ) -> SidebarModel {
        // Настройки занимают рельс целиком: их разделы стоят там, где обычно
        // список встреч. Архив при этом никуда не девается — из раздела в него
        // возвращает «Назад», и выбранная встреча ждёт там же, где была.
        if case .settings(let section) = state.paneRoute {
            return SidebarModel(
                nav: sectionNav(current: section),
                body: .section(footer: footer())
            )
        }
        return SidebarModel(
            nav: nav(state: state),
            // Пустому рельсу сказать нечего, и это не забывчивость.
            //
            // Дойти до него можно единственным путём: пустой архив и открытые
            // настройки — в остальных случаях окно занимает `FirstRunView`, и
            // рельса на экране нет вовсе. То есть человек в этот момент смотрит
            // на настройки, а рядом висит колонка, которая объявляет ему, что
            // встреч нет. Он это знает: он только что поставил приложение.
            //
            // Пустым рельс при этом не выглядит — нав-блок («Новая запись»,
            // поиск, настройки) на месте, потому что он не часть списка.
            body: .archive(groups: groups(state: state, store: store, now: now)),
            prompt: prompt(state.setupPrompt, offering: MCPConnector.clientToOffer)
        )
    }

    // MARK: - Настройки

    /// Идентификатор строки раздела в рельсе. С приставкой, чтобы разделы и
    /// действия не делили пространство имён: одна строка `onNav` на всё.
    static func navID(for section: SettingsSection) -> String {
        "settings." + section.rawValue
    }

    static func section(fromNavID id: String) -> SettingsSection? {
        guard id.hasPrefix("settings.") else { return nil }
        return SettingsSection(rawValue: String(id.dropFirst("settings.".count)))
    }

    private static func sectionNav(current: SettingsSection) -> [SidebarNavItem] {
        SettingsSection.allCases.map { section in
            SidebarNavItem(
                id: navID(for: section),
                symbol: section.symbol,
                title: section.title,
                isSelected: section == current
            )
        }
    }

    /// Марка, версия и единственная дверь наружу.
    ///
    /// «Сообщить о проблеме» стояло строкой рельса — единственной, которая
    /// уводила из приложения, среди строк, обещающих место внутри. Здесь она
    /// рядом с версией, которую в письме всё равно спросят.
    private static func footer() -> SidebarFooterModel {
        SidebarFooterModel(
            name: "Propeller Beta",
            version: LoginItem.appVersionString,
            invitation: "Что-то сломалось? Напишите,\nразберёмся и починим",
            actionTitle: "Помощь"
        )
    }

    // MARK: - The docked question

    /// Every word of it comes off `SetupPrompt`; this only chooses which of the
    /// two control shapes the step wears. Both are declared on the step, so a
    /// step with neither — or with both — cannot be built by accident.
    private static func prompt(
        _ step: SetupPrompt?, offering client: MCPClient?
    ) -> SidebarPromptModel? {
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
            // Имя клиента в вопросе — того, кто стоит на машине. Спросить про
            // Клода у человека, у которого только ChatGPT, значит предложить
            // ему поставить чужое приложение вместо того, что уже есть.
            title: step.title(offering: client ?? .claudeDesktop),
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
                id: NavAction.projects.rawValue,
                symbol: "folder.fill",
                title: "Проекты",
                // Единственная строка рельса с плюсом (`showQuickAction`,
                // 307:6744) — и единственная, у которой есть что создавать
                // отсюда. Запись начинает строка выше собой, у настроек
                // создавать нечего.
                quickAction: .init(symbol: "plus", title: "Новый проект"),
                isSelected: state.paneRoute.isProjectsArea
            ),
            // Поиска здесь нет: он стал кнопкой в шапке рельса, рядом с
            // тумблером. Строка списка обещает место, куда ведёт, а палитра —
            // не место.
            SidebarNavItem(
                id: NavAction.settings.rawValue,
                symbol: "gearshape.fill",
                title: "Настройки",
                // Обычная строка, как все: настройки — состояние панели, а не
                // окно, и открывает их клик, а не `SettingsLink`. Пока они
                // открыты, строка выбрана — ровно как выбрана строка встречи,
                // которую панель показывает.
                isSelected: state.paneRoute.isSettings
            ),
            // «Сообщить о проблеме» здесь больше нет: единственная строка,
            // уводившая из приложения, стояла в списке мест внутри него.
            // Уехала в подвал раздела настроек, к версии, которую в письме всё
            // равно спросят (`footer()`).
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
            hint: .shortcut("⌘R")
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

    /// The same rows as the rail, flat and in the rail's order — what the ⌥Tab
    /// panel shows. One producer, so the panel cannot describe a meeting
    /// differently from the list it is a view of.
    static func switcherRows(state: AppState, store: RecordingStore) -> [SidebarMeetingRowModel] {
        store.recordings.filter(\.hasSomethingToShow).map { row(for: $0, state: state) }
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
            // Ожидание приходит из того же места, что и ответ карточки
            // (`MeetingRest`), и приходит причиной, а не флагом: «в очереди» и
            // «ждём модель» рисуются разными иконками. Пока воркер стоит на
            // этой встрече, ждать нечего — она и есть текущая работа.
            waiting: state.activity.concerns(entry.id) ? nil : rest.waitReason
        )
        return SidebarMeetingRowModel(
            id: entry.id,
            meta: SidebarMeta.line(start: entry.date, duration: entry.duration),
            title: entry.title.isEmpty ? "Без названия" : entry.title,
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

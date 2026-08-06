#if GALLERY
import PropellerPure
import PropellerUI
import SwiftUI

/// # The rail's state machine, on a wall
///
/// `StateGallery` photographs whole screens. That is the wrong grain for a
/// component: nine appearances of one row, shot nine times inside a 940 pt
/// window, is nine pictures that differ by forty pixels each and cannot be
/// compared without a diff tool.
///
/// So the rail gets its own boards, and each one puts the whole axis in a single
/// frame — every row state next to every other, dark beside light. That is the
/// arrangement that answers the questions people actually have: *does working
/// read differently from selected*, *is the error visible at a glance*, *did the
/// light theme forget a colour*.
///
/// The content is `SidebarStateCatalog`, so a state added to the machine turns
/// up here without anyone remembering to draw it — and `SidebarStateTests`
/// fails if the catalogue and the type drift apart.
enum SidebarGallery {

    static let ids = ["sb-rows", "sb-nav", "sb-rail", "sb-pane", "sb-machine"]

    static func label(for id: String) -> String {
        switch id {
        case "sb-rows":    return "Строка встречи — все состояния"
        case "sb-nav":     return "Строка меню — все состояния"
        case "sb-rail":    return "Сайдбар целиком"
        case "sb-pane":    return "Правая панель — шапка и две колонки"
        case "sb-machine": return "Пайплайн → вид строки"
        default:           return id
        }
    }

    @ViewBuilder
    static func view(for id: String) -> some View {
        switch id {
        case "sb-rows":    Board { RowStates() }
        case "sb-nav":     Board { NavStates() }
        case "sb-rail":    RailBoard()
        case "sb-pane":    PaneBoard()
        // One pane: the table documents the mapping, and a mapping has no
        // light-mode version to compare against.
        case "sb-machine": Board(schemes: [.dark]) { MachineTable() }
        default:           EmptyView()
        }
    }

    // MARK: - Chrome

    /// Dark and light of the same thing, side by side, on the surface each one
    /// is meant to sit on. Judging a light token against a black backdrop is how
    /// you ship a rail nobody can read.
    struct Board<Content: View>: View {
        var schemes: [ColorScheme] = [.dark, .light]
        @ViewBuilder var content: () -> Content

        var body: some View {
            // Sized to what is in it. A fixed board width silently crops
            // anything wider — which is how the mapping table lost its light
            // half the first time.
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(schemes.enumerated()), id: \.offset) { _, scheme in
                    pane(scheme)
                }
            }
            .fixedSize()
        }

        private func pane(_ scheme: ColorScheme) -> some View {
            VStack(alignment: .leading, spacing: Tokens.Space.s16) {
                Text(scheme == .dark ? "Тёмная" : "Светлая")
                    .typo(Tokens.Typography.Label.smMedium)
                    .foregroundStyle(Tokens.Paint.Text.tertiary)
                content()
            }
            .padding(Tokens.Space.s24)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .background(Tokens.Sidebar.surface)
            .background(GalleryBackdrop())
            .environment(\.colorScheme, scheme)
            .environment(\.sidebarSweepFrozen, true)
        }
    }

    /// Stands in for the window's glass.
    ///
    /// The rail paints only a 2 % wash of its own — in the app the material
    /// behind it supplies the rest. A board on pure black would therefore export
    /// a rail darker than any user will ever see, and the comps would look wrong
    /// beside it for a reason that is not the rail's.
    struct GalleryBackdrop: View {
        var body: some View {
            // The value the comps composite against (#141414 in dark).
            Tokens.Primitive.surface(dark: 20.0 / 255.0, light: 236.0 / 255.0)
        }
    }

    // MARK: - Boards

    /// One row per catalogue case, drawn at the real 276 pt so wrapping and the
    /// sweep are the ones that ship.
    struct RowStates: View {
        var body: some View {
            VStack(alignment: .leading, spacing: Tokens.Space.s16) {
                ForEach(SidebarStateCatalog.meetingRows) { item in
                    VStack(alignment: .leading, spacing: Tokens.Space.s4) {
                        Text(item.label)
                            .typo(Tokens.Sidebar.Typo.sectionHeader)
                            .foregroundStyle(Tokens.Sidebar.sectionHeader)
                        // The hover case has to be handed its actions or the
                        // slot draws empty — which is the one thing the board
                        // exists to show. Same for the deleted row and its
                        // «Вернуть»: absent handler, absent offer.
                        SidebarMeetingRow(
                            row: Self.sample(item.state),
                            action: {}, onDelete: {}, onRestore: {}
                        )
                        .frame(width: Tokens.Sidebar.width - Tokens.Sidebar.bodyHPadding * 2)
                    }
                }
            }
        }

        /// Real copy, not lorem: the sweep is only convincing over a line that
        /// actually wraps, and the failure badge only fits if the meta line is
        /// the length it will be.
        static func sample(_ state: SidebarRowState) -> SidebarMeetingRowModel {
            let title = SidebarTitleText.terminated("Воркшоп по VK Музыке")
            let preview = SidebarRowMachine.preview(
                activity: state.activity,
                phaseMessage: PipelineActivity.Phase.transcribing.defaultMessage,
                topics: "Обсудили этапы, выявили препятствия, наметили следующие шаги"
            )
            return SidebarMeetingRowModel(
                id: "sample", meta: "17:30 · 45 мин", title: title, preview: preview, state: state
            )
        }
    }

    struct NavStates: View {
        var body: some View {
            VStack(alignment: .leading, spacing: Tokens.Space.s16) {
                ForEach(SidebarStateCatalog.navRows) { item in
                    VStack(alignment: .leading, spacing: Tokens.Space.s4) {
                        Text(item.label)
                            .typo(Tokens.Sidebar.Typo.sectionHeader)
                            .foregroundStyle(Tokens.Sidebar.sectionHeader)
                        // Hover is a pointer state and a still frame has no
                        // pointer, so it is posed through the row's own
                        // `isHovered` — the same field the live pointer feeds.
                        SidebarNavRow(
                            item: SidebarNavItem(
                                id: "sample", symbol: SidebarNavItem.propellerMarkSymbol,
                                title: "Новая запись", shortcut: "⌘R",
                                isSelected: item.state.isSelected,
                                isHovered: item.state.isHovered
                            ),
                            action: {}
                        )
                        .frame(width: Tokens.Sidebar.width - Tokens.Sidebar.bodyHPadding * 2)
                    }
                }
                // The one nav row that is also a notice: recording asked for and
                // the microphone denied. It used to be a floating message, so it belongs on
                // the board where the rest of the rail's states are judged.
                VStack(alignment: .leading, spacing: Tokens.Space.s4) {
                    Text("Нет доступа к микрофону")
                        .typo(Tokens.Sidebar.Typo.sectionHeader)
                        .foregroundStyle(Tokens.Sidebar.sectionHeader)
                    SidebarNavRow(
                        item: SidebarNavItem(
                            id: "sample", symbol: "mic.slash", title: "Нет доступа к микрофону"
                        ),
                        action: {}
                    )
                    .frame(width: Tokens.Sidebar.width - Tokens.Sidebar.bodyHPadding * 2)
                }
            }
        }
    }

    /// The rail as a person sees it, with one meeting of each kind in the list.
    struct RailBoard: View {
        var body: some View {
            HStack(spacing: 0) {
                rail(.dark)
                rail(.light)
            }
            .frame(height: 640)
        }

        private func rail(_ scheme: ColorScheme) -> some View {
            PropellerSidebar(
                model: Self.model,
                trafficLights: .drawn,
                onToggle: {}
            )
                .frame(height: 640)
                .background(GalleryBackdrop())
                .environment(\.colorScheme, scheme)
                .environment(\.sidebarSweepFrozen, true)
        }

        static let model = SidebarModel(
            nav: [
                .init(id: "record", symbol: SidebarNavItem.propellerMarkSymbol, title: "Новая запись", shortcut: "⌘R"),
                .init(id: "search", symbol: "magnifyingglass", title: "Поиск", shortcut: "⌘K"),
                .init(id: "settings", symbol: "gearshape.fill", title: "Настройки", shortcut: "⌘,"),
                .init(id: "feedback", symbol: "ladybug.fill", title: "Сообщить о проблеме"),
            ],
            groups: [
                .init(id: "today", header: nil, rows: [
                    row("1", "17:30 · 45 мин", "PG x VK Музыка",
                        state: .init(activity: .processing)),
                    row("2", "17:30 · 45 мин", "Воркшоп по VK Музыке",
                        preview: "Обсудили этапы, выявили препятствия, наметили следующие шаги",
                        state: .init(isSelected: true)),
                    row("3", "17:30 · 45 мин", "Тактика | Лиды",
                        preview: "Обсудили ошибки и предложили пути их устранения",
                        state: .rest),
                    row("4", "17:30 · 45 мин", "ГПН Портал | Внутренний воркшоп",
                        preview: "Определили задачи, приоритеты и сроки выполнения",
                        state: .rest),
                ]),
                .init(id: "yesterday", header: "Вчера, 24 августа", rows: [
                    row("5", "17:30 · 45 мин", "Планирование следующего спринта",
                        preview: "Определили задачи, приоритеты и сроки выполнения",
                        state: .rest),
                    row("6", "12:05", "Синк по релизу",
                        state: .init(activity: .recording)),
                    row("7", "09:15 · 28 мин", "Дизайн-ревью",
                        state: .init(activity: .rests)),
                ]),
            ]
        )

        static func row(
            _ id: String, _ meta: String, _ title: String,
            preview: String = "", state: SidebarRowState
        ) -> SidebarMeetingRowModel {
            SidebarMeetingRowModel(
                id: id,
                meta: meta,
                title: SidebarTitleText.terminated(title),
                preview: SidebarRowMachine.preview(
                    activity: state.activity,
                    phaseMessage: PipelineActivity.Phase.transcribing.defaultMessage,
                    topics: preview
                ),
                state: state
            )
        }
    }

    /// The pane at the width the comps draw it: 800 pt, header on the rail's
    /// own 48 pt line, then the two columns.
    struct PaneBoard: View {
        var body: some View {
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    pane(.dark, width: 800)
                    pane(.light, width: 800)
                }
                VStack(spacing: 0) {
                    pane(.dark, width: 601)
                    pane(.light, width: 601)
                }
                // Wide: the notes stop at their ceiling and the summary centres
                // its measure in everything left over.
                VStack(spacing: 0) {
                    pane(.dark, width: 1200)
                    pane(.light, width: 1200)
                }
            }
            .fixedSize()
        }

        private func pane(_ scheme: ColorScheme) -> some View {
            pane(scheme, width: 800)
        }

        /// The comps draw the pane at 800, 788 and 601 — the last of which is
        /// where the notes collapse. One board, all three, or the collapse is
        /// something nobody looks at until a user resizes the window.
        private func pane(_ scheme: ColorScheme, width: CGFloat) -> some View {
            VStack(spacing: 0) {
                MeetingPaneHeader(
                    meetingID: "gallery",
                    title: "Воркшоп по VK Музыке",
                    onRename: { _, _ in },
                    share: .init("Поделиться") {}
                ) {
                    Button("Показать в Finder") {}
                    Button("Удалить встречу", role: .destructive) {}
                }
                MeetingPaneBody(summary: Self.summary, notes: Self.notes)
            }
            .frame(width: width, height: 640)
            .background(GalleryBackdrop())
            .environment(\.colorScheme, scheme)
        }

        /// The posed summary, written as the markdown a recap actually is
        /// rather than assembled block by block. The board then photographs the
        /// same parse the app runs — a fixture built by hand can be shaped like
        /// nothing `RecapService` ever writes, and this one was.
        static let summary = MeetingSummary.parse(markdown: """
        ## Итог
        Проведен воркшоп по музыкальному приложению «интерактивная вики», где фокус на исследовании связей между артистами, треками и эпохами.

        Ключевая цель — создание системы, которая снижает когнитивную нагрузку («усталость от норы») за счёт визуализации маршрутов исследования и быстрой ориентации через обогащённый текст (мету) с кликабельными ссылками на смежные объекты.

        ## Решения
        - **Мета как основа навигации:** Метаданные описываются не просто текстом, а структурированными блоками («краткая версия» + «развёрнутая»), где ключевые факты оформляются в виде кликабельных ссылок (сниппетов) на связанные объекты.
        - Связи вместо статических страниц: Каждая единица контента (трек, релиз, жанр, эпоха) рассматривается как узел графа. Важным элементом является отображение связей «вбок» и «назад».
        """)

        static let notes: [MeetingNote] = [
            .init(id: "n1", text: "Убедиться что все ошибки дают путь дальше"),
            .init(id: "n2", text: "дальний горизонт:\n\n* собрать контекст по рынку че похожего делают\n* зарелизить бота для лидов пг\n\nв понедельник проводим дейлик."),
        ]
    }

    /// Eleven pipeline states in, four appearances out. Printed as a table
    /// because the collapse is the interesting part: three of these rows say
    /// «в очереди» and the rail draws all three as nothing at all.
    struct MachineTable: View {
        var body: some View {
            VStack(alignment: .leading, spacing: Tokens.Space.s8) {
                ForEach(SidebarStateCatalog.pipelineMapping, id: \.state.id) { pair in
                    HStack(alignment: .top, spacing: Tokens.Space.s12) {
                        Text(pair.state.id)
                            .typo(Tokens.Sidebar.Typo.meta)
                            .foregroundStyle(Tokens.Sidebar.meetingMeta)
                            .frame(width: 120, alignment: .leading)
                        Text(pair.state.label)
                            .typo(Tokens.Sidebar.Typo.meetingTitle)
                            .foregroundStyle(Tokens.Sidebar.meetingPreview)
                            .frame(width: 220, alignment: .leading)
                        Text(SidebarStateCatalog.activityLabel(pair.activity))
                            .typo(Tokens.Sidebar.Typo.navLabel)
                            .foregroundStyle(pair.activity == .none
                                             ? Tokens.Sidebar.sectionHeader
                                             : Tokens.Sidebar.meetingTitle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(width: 800, alignment: .leading)
        }
    }
}
#endif

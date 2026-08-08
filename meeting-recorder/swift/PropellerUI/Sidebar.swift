import SwiftUI
import AppKit
import PropellerPure

/// # The left rail — Figma `sidebar / Frame 127` (31:4581)
///
/// A 300 pt column: the window's titlebar row, a short list of things the app
/// can do, a rule, then every meeting you have, newest first, grouped by day.
///
/// It is deliberately **pure presentation**. It takes a `SidebarModel` and hands
/// back ids; it never sees `AppState`, a `RecordingEntry` or the pipeline. That
/// is what lets the state gallery pose all nine row appearances side by side
/// without a recording on disk, and what keeps the interesting decision — which
/// appearance a meeting gets — in `SidebarRowMachine`, where a test can reach it.
///
/// Numbers live in `Tokens.Sidebar`, measured off the frame. Nothing here should
/// contain a literal that isn't a string.

// MARK: - Model

public struct SidebarNavItem: Identifiable, Equatable, Sendable {

    // Settings used to need a `Role` of their own: opening the Settings *scene*
    // is not something a closure can do — `NSApp.sendAction(showSettingsWindow:)`
    // silently does nothing from a menu-bar app that is `.accessory`, and
    // `SettingsLink` is a view rather than an action. That scene is gone
    // (2026-08-07): settings are a state of the content pane, so every nav row
    // is now the same thing — a button that reports its id.

    /// What the row's trailing slot says about the click. One tenant, two kinds:
    /// a key that does the same thing, or the fact that the click leaves the app.
    /// The second cannot be spelled as a shortcut string — there is no key for
    /// «откроется браузер» — and a row that lands somewhere else has to say so
    /// before it is pressed.
    public enum Hint: Equatable, Sendable {
        case shortcut(String)
        case opensBrowser
    }

    public let id: String
    /// SF Symbol name — or `SidebarNavItem.propellerMarkSymbol` for the brand glyph.
    public let symbol: String
    public let title: String
    /// Revealed on hover. The comps reserve the slot and paint it transparent.
    public let hint: Hint?
    public let isSelected: Bool
    /// A *forced* hover pose, OR-ed with the live pointer. Only the state
    /// gallery sets it — a still frame has no pointer, and a second "looks
    /// hovered" flag inside the view would let the gallery draw something the
    /// app cannot produce.
    public let isHovered: Bool

    /// Reserved `symbol` for the Propeller mark in the record row.
    public static let propellerMarkSymbol = "propeller.mark"

    public init(
        id: String,
        symbol: String,
        title: String,
        hint: Hint? = nil,
        isSelected: Bool = false,
        isHovered: Bool = false
    ) {
        self.id = id
        self.symbol = symbol
        self.title = title
        self.hint = hint
        self.isSelected = isSelected
        self.isHovered = isHovered
    }
}

public struct SidebarMeetingRowModel: Identifiable, Equatable, Sendable {
    public let id: String
    /// «17:30 · 45 мин».
    public let meta: String
    /// The meeting's name — the loud half of the title line.
    public let title: String
    /// What it was about, or what is being done to it — the quiet half.
    public let preview: String
    /// Selection and activity from `SidebarRowMachine`. Its `isHovered` is a
    /// *forced* pose for the gallery; the live pointer is tracked by the view
    /// and the two are OR-ed, so the real app passes `false` and forgets it.
    public let state: SidebarRowState
    /// Whether «Копировать саммари» in the row's menu has anything to copy.
    public let hasSummary: Bool

    public init(
        id: String,
        meta: String,
        title: String,
        preview: String,
        state: SidebarRowState,
        hasSummary: Bool = false
    ) {
        self.id = id
        self.meta = meta
        self.title = title
        self.preview = preview
        self.state = state
        self.hasSummary = hasSummary
    }
}

public struct SidebarMeetingGroup: Identifiable, Equatable, Sendable {
    public let id: String
    /// «Вчера, 24 августа». Nil for the newest group — today needs no label,
    /// and the comps give it none.
    public let header: String?
    public let rows: [SidebarMeetingRowModel]

    public init(id: String, header: String?, rows: [SidebarMeetingRowModel]) {
        self.id = id
        self.header = header
        self.rows = rows
    }
}

public struct SidebarModel: Equatable, Sendable {
    public var nav: [SidebarNavItem]
    public var groups: [SidebarMeetingGroup]
    /// Shown in place of the list when there is nothing to show.
    public var emptyMessage: String?
    /// The one question setup did not ask on its own screen — the calendar, then
    /// the name. Nil once both are settled, which for most of the app's life is
    /// always. See `SetupPromptMachine`.
    public var prompt: SidebarPromptModel?

    public init(
        nav: [SidebarNavItem],
        groups: [SidebarMeetingGroup],
        emptyMessage: String? = nil,
        prompt: SidebarPromptModel? = nil
    ) {
        self.nav = nav
        self.groups = groups
        self.emptyMessage = emptyMessage
        self.prompt = prompt
    }
}

/// Who draws the three discs at the top-left.
public enum SidebarTrafficLights: Equatable, Sendable {
    /// The real `NSWindow` buttons, moved into the slot by `SceneWindowChrome`.
    /// The rail only reserves the space.
    case system
    /// Painted discs — previews and the state gallery, which have no window
    /// buttons to move. Never in the shipping window: a picture of a close
    /// button that doesn't close is worse than no picture.
    case drawn
}

// MARK: - The rail

public struct PropellerSidebar: View {
    private let model: SidebarModel
    private let trafficLights: SidebarTrafficLights
    private let onNav: (String) -> Void
    private let onSelectMeeting: (String) -> Void
    /// The row's hover action, by meeting id. Absent means the rows show none.
    private let onDeleteMeeting: ((String) -> Void)?
    private let onToggle: (() -> Void)?
    /// Search lives in the header rather than in the list: it is chrome, like the
    /// toggle beside it, and a row that opens a palette was the one nav item that
    /// did not lead anywhere in the rail. Absent means no button.
    private let onSearch: (() -> Void)?
    /// Bring back a meeting whose deletion is still undoable. Absent means the
    /// rows don't offer it.
    private let onRestoreMeeting: ((String) -> Void)?
    /// Right-click actions, by meeting id. Absent means that item is omitted.
    private let onCopySummary: ((String) -> Void)?
    private let onShareMeeting: ((String) -> Void)?
    private let onRevealMeeting: ((String) -> Void)?
    /// Meeting row playing Codelaby disintegrate — still laid out until finish.
    private let dissolvingMeetingID: String?
    /// Ash finished — soft-delete can land.
    private let onDissolveFinished: (() -> Void)?
    /// The docked question's button was pressed — the step's id comes back with it.
    private let onPromptAction: (String) -> Void
    /// The docked question's field was submitted: step id, then the answer.
    private let onPromptSubmit: (String, String) -> Void

    public init(
        model: SidebarModel,
        trafficLights: SidebarTrafficLights = .system,
        onNav: @escaping (String) -> Void = { _ in },
        onSelectMeeting: @escaping (String) -> Void = { _ in },
        onDeleteMeeting: ((String) -> Void)? = nil,
        onRestoreMeeting: ((String) -> Void)? = nil,
        onCopySummary: ((String) -> Void)? = nil,
        onShareMeeting: ((String) -> Void)? = nil,
        onRevealMeeting: ((String) -> Void)? = nil,
        dissolvingMeetingID: String? = nil,
        onDissolveFinished: (() -> Void)? = nil,
        onToggle: (() -> Void)? = nil,
        onSearch: (() -> Void)? = nil,
        onPromptAction: @escaping (String) -> Void = { _ in },
        onPromptSubmit: @escaping (String, String) -> Void = { _, _ in }
    ) {
        self.model = model
        self.trafficLights = trafficLights
        self.onNav = onNav
        self.onSelectMeeting = onSelectMeeting
        self.onDeleteMeeting = onDeleteMeeting
        self.onRestoreMeeting = onRestoreMeeting
        self.onCopySummary = onCopySummary
        self.onShareMeeting = onShareMeeting
        self.onRevealMeeting = onRevealMeeting
        self.dissolvingMeetingID = dissolvingMeetingID
        self.onDissolveFinished = onDissolveFinished
        self.onToggle = onToggle
        self.onSearch = onSearch
        self.onPromptAction = onPromptAction
        self.onPromptSubmit = onPromptSubmit
    }

    /// What the docked block takes off the foot of the rail, including its own
    /// bottom margin. Zero when nothing is docked.
    @State private var promptHeight: CGFloat = 0

    /// There is no toast layer. Everything the app has to say about a meeting is
    /// said by that meeting's own row — a failure showing its mark — and
    /// everything it has to say about recording is said by the row that starts
    /// one. Deletion dissolves the row; ⌘Z restores. A bar that floated over the
    /// list said things nobody could act on, and one of them managed to blame
    /// the user for the app's own crash.
    public var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        // The rail *is* the titlebar on its side of the window — it holds the
        // slot the traffic lights are moved into. AppKit puts those buttons at
        // y 18 whatever SwiftUI thinks, so a rail that honours the top safe area
        // drops its own header below them and the toggle lands on a second line
        // under the discs. Owning this here rather than relying on the window to
        // say it means the rail cannot be composed wrongly.
        .ignoresSafeArea(.container, edges: .top)
        .frame(width: Tokens.Sidebar.width)
        .frame(maxHeight: .infinity)
        .background(Tokens.Sidebar.surface)
        .overlay(alignment: .trailing) {
            // A hairline, not a point: on a 2× display 0.5 pt is one device pixel,
            // which is what the comps' 1 px border actually is.
            Rectangle()
                .fill(Tokens.Sidebar.border)
                .frame(width: 0.5)
        }
    }

    // MARK: Header (Frame 104) — h 48, p 12

    /// The toggle's slot is always reserved here and usually **empty**: in the app
    /// the button belongs to the window (`Tokens.Window.chromeToggleLeading`), so
    /// that putting the rail away cannot move the control that puts it away. The
    /// rail draws its own only when handed an `onToggle` — the state gallery, which
    /// photographs the rail on its own and has no window around it.
    ///
    /// What does change with the rail is the *other* end of this row: with the rail
    /// up it holds search, and with the rail away there is no row to hold anything,
    /// which is the whole point of collapsing it.
    private var header: some View {
        HStack(spacing: 0) {
            trafficLightSlot
            if let onToggle {
                SidebarChromeButton(symbol: "sidebar.left", help: "Скрыть список", action: onToggle)
            } else {
                Color.clear.frame(width: Tokens.Sidebar.toggleSide, height: Tokens.Sidebar.toggleSide)
            }
            Spacer(minLength: Tokens.Space.s8)
            if let onSearch {
                SidebarChromeButton(symbol: "magnifyingglass", help: "Поиск (⌘K)", action: onSearch)
            }
        }
        .padding(Tokens.Sidebar.headerPadding)
        .frame(height: Tokens.Sidebar.headerHeight)
        .background {
            GeometryReader { geo in
                Color.clear.preference(
                    key: SidebarHeaderMidYKey.self,
                    value: geo.frame(in: .global).midY
                )
            }
        }
    }

    @ViewBuilder
    private var trafficLightSlot: some View {
        switch trafficLights {
        case .system:
            Color.clear.frame(
                width: Tokens.Sidebar.trafficLightSlotWidth,
                height: Tokens.Sidebar.toggleSide
            )
        case .drawn:
            HStack(spacing: Tokens.Sidebar.trafficLightSpacing - Tokens.Sidebar.trafficLightDiameter) {
                ForEach(Array(SidebarChromeButton.discColors.enumerated()), id: \.offset) { _, color in
                    Circle()
                        .fill(color)
                        .frame(
                            width: Tokens.Sidebar.trafficLightDiameter,
                            height: Tokens.Sidebar.trafficLightDiameter
                        )
                }
            }
            .frame(
                width: Tokens.Sidebar.trafficLightSlotWidth,
                height: Tokens.Sidebar.toggleSide,
                alignment: .leading
            )
            // Discs start at x 24 in the window; the slot itself starts at 12.
            .padding(.leading, Tokens.Sidebar.trafficLightLeading - Tokens.Sidebar.headerPadding)
        }
    }

    // MARK: Body (Frame 123) — px 10, py 10, gap 12

    /// The body's inset is applied per block rather than to the whole column,
    /// so the scroll view can run the full width of the rail.
    ///
    /// Otherwise the scroller sits 12 pt in from the edge, floating in the
    /// middle of the margin — every other Mac app puts it against the bezel,
    /// and it looks like a mistake anywhere else.
    private var content: some View {
        VStack(alignment: .leading, spacing: Tokens.Sidebar.blockGap) {
            navBlock
                .padding(.horizontal, Tokens.Sidebar.bodyHPadding)
            meetingList
        }
        // Top only: the meeting list owns the bottom of the rail and scrolls
        // flush to the window edge.
        .padding(.top, Tokens.Sidebar.bodyVPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .bottom) { promptLayer }
        .onPreferenceChange(SidebarPromptHeightKey.self) { height in
            promptHeight = height
        }
        .onChange(of: model.prompt?.id) { _, id in
            if id == nil { promptHeight = 0 }
        }
    }

    /// The one question setup left for the rail. Absent for the whole of the
    /// app's ordinary life — which is why it is an overlay and not a row: the
    /// list's layout must not know it was ever there.
    @ViewBuilder
    private var promptLayer: some View {
        if let prompt = model.prompt {
            SidebarPromptBlock(
                model: prompt,
                onAction: onPromptAction,
                onSubmit: onPromptSubmit
            )
            .padding(.horizontal, Tokens.RailPrompt.inset)
            .padding(.bottom, Tokens.RailPrompt.bottomInset)
            .background {
                GeometryReader { geo in
                    Color.clear.preference(
                        key: SidebarPromptHeightKey.self,
                        value: geo.size.height
                    )
                }
            }
            // Answered, it leaves downward — the direction it came from, and the
            // direction that says «убрано», not «закрыто».
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.easeOut(duration: 0.22), value: prompt.id)
        }
    }

    private var navBlock: some View {
        VStack(spacing: 0) {
            ForEach(model.nav) { item in
                SidebarNavRow(item: item) { onNav(item.id) }
            }
        }
    }

    @ViewBuilder
    private var meetingList: some View {
        if model.groups.isEmpty, let message = model.emptyMessage {
            Text(message)
                .typoBlock(Tokens.Sidebar.Typo.meetingTitle)
                .foregroundStyle(Tokens.Sidebar.sectionHeader)
                .padding(.horizontal, Tokens.Sidebar.meetingHPadding)
                .padding(.top, Tokens.Space.s4)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            SidebarMeetingScroll(
                groups: model.groups,
                bottomClear: promptHeight,
                dissolvingMeetingID: dissolvingMeetingID,
                onDissolveFinished: onDissolveFinished,
                onSelectMeeting: onSelectMeeting,
                onDeleteMeeting: onDeleteMeeting,
                onRestoreMeeting: onRestoreMeeting,
                onCopySummary: onCopySummary,
                onShareMeeting: onShareMeeting,
                onRevealMeeting: onRevealMeeting
            )
        }
    }
}

/// The scrollable meeting column. Dates scroll with their groups — nothing pins.
private struct SidebarMeetingScroll: View {
    let groups: [SidebarMeetingGroup]
    let bottomClear: CGFloat
    let dissolvingMeetingID: String?
    let onDissolveFinished: (() -> Void)?
    let onSelectMeeting: (String) -> Void
    let onDeleteMeeting: ((String) -> Void)?
    let onRestoreMeeting: ((String) -> Void)?
    let onCopySummary: ((String) -> Void)?
    let onShareMeeting: ((String) -> Void)?
    let onRevealMeeting: ((String) -> Void)?

    @State private var topFade: CGFloat = 0
    /// Only the first finish callback wins — row + fallback both may fire.
    @State private var dissolveReported = false

    /// Stable fingerprint of who is in the list — drives the reflow animation
    /// when a meeting appears, leaves, or moves between day groups.
    private var listSignature: String {
        groups.map { group in
            group.id + ":" + group.rows.map(\.id).joined(separator: ",")
        }.joined(separator: "|")
    }

    var body: some View {
        ScrollView(.vertical) {
            // `VStack`, not `LazyVStack`: the rail is short enough, and lazy
            // stacks skip insert/remove transitions — neighbours just teleport.
            // Spacing 0: the gap between groups is each group's own bottom
            // padding, so a group that leaves takes its gap with it. As stack
            // spacing it belonged to nobody, and vanished in one frame after the
            // ash — see `dayGroup`.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(groups) { group in
                    dayGroup(group)
                }
            }
            .padding(.horizontal, Tokens.Sidebar.bodyHPadding)
            // Room to scroll the last row clear of the bottom fade (and of a
            // docked prompt's clear zone), so nothing sits permanently veiled.
            .padding(.bottom, Tokens.Sidebar.listBottomFade + bottomClear)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Implicit animation on signature fights explicit withAnimation on
            // undo/delete and makes rows hop. Reflow is driven only by callers.
            .onChange(of: dissolvingMeetingID) { _, id in
                dissolveReported = id == nil
            }
            .background {
                SidebarScrollOffsetReader { offset in
                    topFade = SidebarEdgeFade.topHeight(scrollOffset: offset)
                }
            }
        }
        .scrollIndicators(.automatic)
        .mask {
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [.clear, .black],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: topFade)
                Color.black
                LinearGradient(
                    colors: [.black, .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: Tokens.Sidebar.listBottomFade)
                Color.clear
                    .frame(height: max(0, bottomClear))
            }
        }
    }

    /// One day's meetings, under its date.
    ///
    /// The group carries its own furniture: the date above it and the gap below it.
    /// Both collapse on the ash's clock when the meeting burning is the last one
    /// left in the group, because then there is nothing for the date to head and
    /// nothing for the gap to separate.
    ///
    /// Without that, a row would collapse smoothly to nothing and *then* 22 pt of
    /// date and 24 pt of gap would leave in a single frame as the entry left the
    /// store — the list slid up gently and jumped the last 46 pt. It only ever
    /// showed on the last meeting of a day, because that is the only time this
    /// furniture goes anywhere.
    @ViewBuilder
    private func dayGroup(_ group: SidebarMeetingGroup) -> some View {
        let vanishing = isVanishing(group)
        VStack(alignment: .leading, spacing: 0) {
            if let header = group.header {
                Text(header)
                    .typoBlock(Tokens.Sidebar.Typo.sectionHeader)
                    .foregroundStyle(Tokens.Sidebar.sectionHeader)
                    .padding(.horizontal, Tokens.Sidebar.meetingHPadding)
                    .padding(.bottom, Tokens.Sidebar.sectionHeaderBottomGap)
                    // The block's own height, stated so it can be animated to
                    // nothing. Equal to what it measures anyway, so a group that is
                    // staying is laid out exactly as before.
                    .frame(
                        height: vanishing ? 0 : Tokens.Sidebar.sectionHeaderBlockHeight,
                        alignment: .top
                    )
                    .clipped()
                    .opacity(vanishing ? 0 : 1)
            }
            ForEach(group.rows) { row in
                SidebarMeetingRow(
                    row: row,
                    action: { onSelectMeeting(row.id) },
                    onDelete: onDeleteMeeting.map { delete in { delete(row.id) } },
                    onRestore: onRestoreMeeting.map { restore in { restore(row.id) } },
                    onCopySummary: onCopySummary.map { copy in { copy(row.id) } },
                    onShare: onShareMeeting.map { share in { share(row.id) } },
                    onRevealInFinder: onRevealMeeting.map { reveal in { reveal(row.id) } },
                    isDissolving: row.id == dissolvingMeetingID,
                    onDissolveFinished: reportDissolveFinished
                )
                // Opacity only — move transitions shove neighbours.
                .transition(.opacity)
            }
        }
        .padding(.bottom, vanishing ? 0 : Tokens.Sidebar.groupGap)
        // Only on the way out. Undo mid-ash snaps the row back without animation
        // (`resetSlotCollapse`), and a date easing back in over half a second
        // while the row it heads is already there would be the same mismatch
        // pointing the other way.
        .animation(
            vanishing ? .easeInOut(duration: Tokens.Motion.Ash.duration) : nil,
            value: vanishing
        )
    }

    /// Is this whole group on its way out — the meeting burning being the only one
    /// left under its date.
    private func isVanishing(_ group: SidebarMeetingGroup) -> Bool {
        guard let dissolvingMeetingID else { return false }
        return group.rows.count == 1 && group.rows.first?.id == dissolvingMeetingID
    }

    private func reportDissolveFinished() {
        guard !dissolveReported else { return }
        dissolveReported = true
        onDissolveFinished?()
    }
}

/// How tall the top alpha fade should be for a given scroll offset.
public enum SidebarEdgeFade {
    /// Parked at the top → 0. Scrolled down → grows until `listTopFade`.
    public static func topHeight(
        scrollOffset: CGFloat,
        limit: CGFloat = Tokens.Sidebar.listTopFade
    ) -> CGFloat {
        min(limit, max(0, scrollOffset))
    }
}

/// Reads `NSScrollView.contentView.bounds.origin.y` — the offset AppKit updates
/// on every tick of a drag, which SwiftUI's content GeometryReader does not.
private struct SidebarScrollOffsetReader: NSViewRepresentable {
    var onChange: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onChange = onChange
        context.coordinator.attach(from: nsView)
    }

    final class Coordinator {
        var onChange: (CGFloat) -> Void
        private weak var scrollView: NSScrollView?
        private var token: NSObjectProtocol?
        private var attachAttempts = 0

        init(onChange: @escaping (CGFloat) -> Void) {
            self.onChange = onChange
        }

        deinit {
            if let token { NotificationCenter.default.removeObserver(token) }
        }

        func attach(from view: NSView) {
            guard scrollView == nil else { return }
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view else { return }
                guard self.scrollView == nil else { return }
                guard let scroll = view.enclosingScrollView else {
                    self.attachAttempts += 1
                    if self.attachAttempts < 8 {
                        self.attach(from: view)
                    }
                    return
                }
                self.scrollView = scroll
                let clip = scroll.contentView
                clip.postsBoundsChangedNotifications = true
                self.token = NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification,
                    object: clip,
                    queue: .main
                ) { [weak self] _ in
                    self?.publish(from: scroll)
                }
                self.publish(from: scroll)
            }
        }

        private func publish(from scroll: NSScrollView) {
            onChange(max(0, scroll.contentView.bounds.origin.y))
        }
    }
}

// MARK: - Nav row (list-item)

/// h 32, rounded 8, px 11 — icon 16, label, then the shortcut slot the comps
/// reserve. Icon and label are one colour and always move together: an icon that
/// stays dim next to a bright label reads as disabled.
public struct SidebarNavRow: View {
    let item: SidebarNavItem
    let action: () -> Void

    @State private var hovering = false

    public init(item: SidebarNavItem, action: @escaping () -> Void) {
        self.item = item
        self.action = action
    }

    private var isHovered: Bool { hovering || item.isHovered }

    private var foreground: Color {
        // Selected and hovered both take the 95 % ink — the icon and label
        // move together. The shortcut keeps its own quieter colour below.
        (item.isSelected || isHovered) ? Tokens.Sidebar.navLabelSelected : Tokens.Sidebar.navLabel
    }

    private var fill: Color {
        if item.isSelected { return Tokens.Sidebar.rowSelected }
        return isHovered ? Tokens.Sidebar.rowHover : .clear
    }

    public var body: some View {
        Button(action: action) { label }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: Tokens.Motion.hover), value: hovering)
            .animation(.easeOut(duration: Tokens.Motion.hover), value: item.isSelected)
    }

    private var label: some View {
        HStack(spacing: Tokens.Sidebar.navRowGap) {
            navGlyph
                .frame(width: Tokens.Sidebar.navIconSide, height: Tokens.Sidebar.navIconSide)

            Text(item.title)
                .typo(Tokens.Sidebar.Typo.navLabel)
                .lineLimit(1)
                .padding(.horizontal, Tokens.Sidebar.navLabelInset)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let hint = item.hint {
                // The comps reserve this slot and paint it transparent, so
                // the row's width never moves; showing it under the pointer
                // is the only way the reservation earns its keep.
                hintView(hint)
                    .foregroundStyle(Tokens.Sidebar.navShortcut)
                    .opacity(isHovered ? 1 : 0)
                    .frame(height: Tokens.Sidebar.navIconSide)
                    // Invisible is not the same as absent: VoiceOver would
                    // otherwise read a hint the eye cannot see.
                    .accessibilityHidden(!isHovered)
            }
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, Tokens.Sidebar.navRowHPadding)
        .frame(height: Tokens.Sidebar.navRowHeight)
        .frame(maxWidth: .infinity)
        .background(
            fill,
            in: RoundedRectangle(cornerRadius: Tokens.Sidebar.rowRadius, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: Tokens.Sidebar.rowRadius, style: .continuous))
    }

    /// Both tenants of the slot draw at the meta size, so the arrow sits on the
    /// same optical line as a «⌘R» and the slot never changes width between rows.
    @ViewBuilder
    private func hintView(_ hint: SidebarNavItem.Hint) -> some View {
        switch hint {
        case .shortcut(let keys):
            Text(keys)
                .typo(Tokens.Sidebar.Typo.meta)
        case .opensBrowser:
            Image(systemName: "arrow.up.right")
                .font(.system(size: Tokens.Sidebar.Typo.meta.size, weight: .regular))
        }
    }

    @ViewBuilder
    private var navGlyph: some View {
        if item.symbol == SidebarNavItem.propellerMarkSymbol {
            PropellerNavMark(spinning: isHovered)
        } else {
            Image(systemName: item.symbol)
                .font(.system(size: Tokens.Sidebar.navIconSize, weight: .regular))
        }
    }
}

// MARK: - Meeting row (meetingitem)

/// px 14 / py 11, rounded 8: the title and its preview as one wrapping
/// paragraph. The time line (and the hover / restore slot it carried) is built
/// below but not shown — still deciding whether that row belongs here.
///
/// The two halves of that paragraph carry the state:
///
/// | | title | preview |
/// |---|---|---|
/// | rest | 95 % | 55 % |
/// | open | 95 % | 95 % |
/// | working | 55 % + sweep | 55 % + sweep |
///
/// Selecting lifts the preview to the title's weight; working drops the title to
/// the preview's and sets the whole line moving. Both are one change to one
/// paragraph, which is why the row never has to re-flow between states.
public struct SidebarMeetingRow: View {
    let row: SidebarMeetingRowModel
    let action: () -> Void
    /// The hover action. Absent means the row has none — the gallery draws it
    /// that way, and so would a list of things that cannot be deleted.
    ///
    /// Occasional actions (Finder, share, copy) live on the right-click menu —
    /// not as hover icons. Two glyphs under the pointer made the quiet slot busy
    /// for things that are not routine; the card's «ещё» still has them too.
    let onDelete: (() -> Void)?
    /// Present only while the deletion can still be taken back.
    let onRestore: (() -> Void)?
    let onCopySummary: (() -> Void)?
    let onShare: (() -> Void)?
    let onRevealInFinder: (() -> Void)?
    /// Codelaby-style ash — snapshot of this label, then height collapse.
    let isDissolving: Bool
    let onDissolveFinished: (() -> Void)?

    @State private var hovering = false
    /// Measured row height — the slot collapses from this while ash plays.
    @State private var slotHeight: CGFloat = 0
    /// 0 = full slot, 1 = gone. Animated with the ash, same duration.
    @State private var slotCollapse: CGFloat = 0
    /// `slotHeight` is the height we collapse *from* — once the ash is lit it
    /// must stop tracking the row, or the collapse measures itself.
    @State private var slotFrozen = false
    /// Latched when the ash has burned out. The entry leaves the store from a
    /// different object than the one that clears `isDissolving`, and a frame
    /// rendered between those two updates was the row blinking back into place.
    @State private var burnedOut = false
    /// Phase line typewriter — «Расшифровываем…» → «Суммируем…».
    @StateObject private var statusTypewriter = SoftTypewriterSession()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.sidebarSweepFrozen) private var sweepFrozen

    public init(
        row: SidebarMeetingRowModel,
        action: @escaping () -> Void,
        onDelete: (() -> Void)? = nil,
        onRestore: (() -> Void)? = nil,
        onCopySummary: (() -> Void)? = nil,
        onShare: (() -> Void)? = nil,
        onRevealInFinder: (() -> Void)? = nil,
        isDissolving: Bool = false,
        onDissolveFinished: (() -> Void)? = nil
    ) {
        self.row = row
        self.action = action
        self.onDelete = onDelete
        self.onRestore = onRestore
        self.onCopySummary = onCopySummary
        self.onShare = onShare
        self.onRevealInFinder = onRevealInFinder
        self.isDissolving = isDissolving
        self.onDissolveFinished = onDissolveFinished
    }

    private var isHovered: Bool { hovering || row.state.isHovered }
    /// Both «being worked on» and «waiting its turn» shimmer: the sweep says
    /// «this meeting is in the pipeline», not «this second is spent on it».
    private var isWorking: Bool { row.state.activity.isInFlight }
    private var isDeleted: Bool { row.state.activity == .deletedUndoable }
    /// Ash is playing, or already has. Either way the row itself paints nothing.
    private var isVanishing: Bool { isDissolving || burnedOut }
    private var statusAnimated: Bool { !reduceMotion && !sweepFrozen }

    private var fill: Color {
        if row.state.isSelected { return Tokens.Sidebar.rowSelected }
        return isHovered ? Tokens.Sidebar.rowHover : .clear
    }

    private var titleColor: Color {
        SidebarMeetingParagraph.inks(for: row.state, isSelected: row.state.isSelected).title
    }

    private var previewColor: Color {
        SidebarMeetingParagraph.inks(for: row.state, isSelected: row.state.isSelected).preview
    }

    public var body: some View {
        // Keep the real row for layout. Ash is an overlay only — a ZStack/stand-in
        // that grew with the particle canvas was blowing the rail open.
        Button(action: isDeleted || isVanishing ? {} : action) {
            VStack(alignment: .leading, spacing: Tokens.Sidebar.meetingLineGap) {
                titleLine
                // Hidden for now — time, duration, hover trash / «Вернуть» /
                // recording badge. Logic stays compiled below; still thinking
                // whether this row belongs on the meeting item at all.
                if false { metaLine }
            }
            .padding(.horizontal, Tokens.Sidebar.meetingHPadding)
            .padding(.vertical, Tokens.Sidebar.meetingVPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                fill,
                in: RoundedRectangle(cornerRadius: Tokens.Sidebar.meetingRadius, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: Tokens.Sidebar.meetingRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !isVanishing { meetingMenu }
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.Motion.hover), value: hovering)
        .animation(.easeOut(duration: Tokens.Motion.hover), value: row.state)
        .opacity(isVanishing ? 0 : 1)
        // Measured as an *action*, not a preference. A preference arrives after
        // the layout that produced it, and a row can be born already dissolving —
        // `onAppear` then fires before the first delivery, so the collapse used to
        // start with `slotHeight` still 0 and fall back to a guessed one-line row.
        // Real rows wrap to three lines: the slot snapped 78 → 42 on the frame the
        // delete landed, and everything below it jumped by 36 pt before the smooth
        // part even began.
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { noteHeight(geo.size.height) }
                    .onChange(of: geo.size.height) { _, height in noteHeight(height) }
            }
        }
        // Ash and neighbours share one clock: slot shrinks while flakes fade.
        .frame(
            height: isVanishing && slotHeight > 1
                ? max(0.5, slotHeight * (1 - (burnedOut ? 1 : slotCollapse)))
                : nil,
            alignment: .top
        )
        .clipped()
        // Ash floats *above* the closing gap, outside the clip — it stands in
        // the slot it is burning, so the slot must not cut it down as it shrinks.
        .overlay(alignment: .top) {
            if isDissolving, slotHeight > 1 {
                MeetingRowAshView(
                    title: row.title,
                    preview: row.preview,
                    onFinished: {
                        burnedOut = true
                        onDissolveFinished?()
                    }
                )
                .frame(height: slotHeight, alignment: .top)
            }
        }
        .onChange(of: isDissolving) { _, dissolving in
            if dissolving { startSlotCollapse() }
            // Undo mid-ash — the row is staying. After a burn-out the row is on
            // its way out of the store and must not come back for a frame.
            else if !burnedOut { resetSlotCollapse() }
        }
        .onAppear {
            // Ghost rows are born already dissolving — `onChange` will not fire.
            if isDissolving { startSlotCollapse() }
            syncStatusTypewriter(animated: false)
        }
        .onChange(of: row.preview) { _, _ in syncStatusTypewriter(animated: isWorking) }
        .onChange(of: isWorking) { _, working in
            // Leaving the pipeline — snap to topics; no dismiss of «Суммируем».
            if !working { statusTypewriter.snap(to: row.preview) }
            else { syncStatusTypewriter(animated: true) }
        }
    }

    private func syncStatusTypewriter(animated: Bool) {
        statusTypewriter.play(to: row.preview, animated: animated && statusAnimated)
    }

    /// The row's own height, delivered on every layout pass until the ash freezes
    /// it. Also what *starts* the collapse when the row arrives already dissolving:
    /// there is nothing to collapse from until this has run once.
    private func noteHeight(_ height: CGFloat) {
        guard height > 1, !slotFrozen else { return }
        slotHeight = height
        if isDissolving { startSlotCollapse() }
    }

    private func startSlotCollapse() {
        // No guessing. Without a measurement the row simply holds its natural
        // height until the entry leaves the store — worse motion than a collapse,
        // but not a visible snap to the wrong size.
        guard slotHeight > 1, !slotFrozen else { return }
        AshLog.log.info("slot: collapsing from \(self.slotHeight)")
        slotFrozen = true
        slotCollapse = 0
        withAnimation(.easeInOut(duration: Tokens.Motion.Ash.duration)) {
            slotCollapse = 1
        }
    }

    private func resetSlotCollapse() {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            slotCollapse = 0
            burnedOut = false
            slotFrozen = false
        }
    }

    /// The system menu for a meeting — right-click, not hover chrome.
    @ViewBuilder
    private var meetingMenu: some View {
        if isDeleted {
            if let onRestore {
                Button("Вернуть", action: onRestore)
            }
        } else {
            if let onCopySummary {
                Button("Копировать саммари", action: onCopySummary)
                    .disabled(!row.hasSummary)
            }
            if let onShare {
                Button("Поделиться", action: onShare)
            }
            if let onRevealInFinder {
                Button("Показать в Finder", action: onRevealInFinder)
            }
            if onDelete != nil, onCopySummary != nil || onShare != nil || onRevealInFinder != nil {
                Divider()
            }
            if let onDelete {
                Button("Удалить встречу", role: .destructive, action: onDelete)
            }
        }
    }

    /// The time, and then the slot the comps keep to its right.
    ///
    /// That slot has two tenants and they never overlap. Under the pointer it
    /// holds the row's micro-actions — reveal and delete, exactly the pair drawn
    /// in `state=hover`. The rest of the time it is where a meeting says
    /// something the text cannot: that it is recording, or that it has stopped
    /// and needs a person. Sharing one slot is why neither has to find room.
    private var metaLine: some View {
        HStack(spacing: Tokens.Sidebar.rowActionGap) {
            Text(row.meta)
                .typoBlock(Tokens.Sidebar.Typo.meta, monospacedDigit: true)
                .foregroundStyle(Tokens.Sidebar.meetingMeta)
                .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if isDeleted, let onRestore {
                    // The third tenant of the slot, and the only one that is a
                    // word rather than a glyph: an icon-only undo is a puzzle,
                    // and this one has eight seconds to be understood.
                    SidebarRowRestore(action: onRestore)
                } else if isHovered {
                    microActions
                } else {
                    badge
                }
            }
            // Pinned to the time line's own height, ink allowed to overflow it.
            //
            // The comps draw `state=rest` and `state=hover` at the same 84 pt,
            // so the 16 pt icon slots cannot be allowed to set the row's height
            // — an `HStack` takes the tallest child, and a row that grows two
            // points under the pointer shoves everything below it down as the
            // mouse travels the list.
            .frame(height: Tokens.Sidebar.Typo.meta.lineHeight)
        }
    }

    @ViewBuilder
    private var microActions: some View {
        HStack(spacing: Tokens.Sidebar.rowActionGap) {
            if let onDelete {
                SidebarRowAction(symbol: "trash", help: "Удалить", action: onDelete)
            }
        }
    }

    @ViewBuilder
    private var badge: some View {
        switch row.state.activity {
        case .recording:
            Circle()
                .fill(Tokens.Paint.Status.record)
                .frame(width: Tokens.Space.s6, height: Tokens.Space.s6)
                .accessibilityLabel("Идёт запись")
        case .rests:
            // Nothing at all. There was a ⚠ here, then a ring — and a ring is a
            // stroked shape sitting in the slot the row's *buttons* live in, which
            // is the interface lying about what can be pressed (PR-013). Then the
            // simpler question: take the mark away, does the row lose anything?
            // It does not — the quiet line already says «Аудио удалено» in words
            // (PR-005). The badge slot is for what the text *cannot* say.
            EmptyView()
        case .none, .processing, .queued, .deletedUndoable:
            // Working already says so, in words and in motion; a deleted row
            // spends the slot on «Вернуть». Queued is the same quiet — the
            // subtitle carries the wait, the badge slot stays empty.
            EmptyView()
        }
    }

    private var titleLine: some View {
        // Working: shimmer on the whole line + typewriter on the phase half.
        // Metal colorEffect on `Text` is a no-op — `sidebarSweep` keeps the
        // gradient path for the rail.
        Group {
            if isWorking {
                workingParagraph.sidebarSweep()
            } else {
                paragraph
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var paragraph: some View {
        SidebarMeetingParagraph(row: row, isSelected: row.state.isSelected)
    }

    private var workingParagraph: some View {
        Text(workingAttributed)
            .typoBlock(Tokens.Sidebar.Typo.meetingTitle)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Title static; phase line soft-typewritten so a new status arrives.
    private var workingAttributed: AttributedString {
        var title = AttributedString(row.title)
        title.foregroundColor = titleColor
        let status = statusTypewriter.displayed
        guard !status.isEmpty else { return title }
        if !row.title.isEmpty {
            var space = AttributedString(" ")
            space.foregroundColor = previewColor
            title.append(space)
        }
        title.append(SoftTypewriter.paint(
            status,
            color: previewColor,
            progress: statusTypewriter.progress,
            softness: Tokens.Sidebar.StatusReveal.softChars
        ))
        return title
    }
}

/// One of the two icons a meeting row reveals under the pointer.
///
/// No fill and no frame of its own — the row is already washed, and a button
/// chrome inside a hovered row makes two rectangles where the comps draw one.
struct SidebarRowAction: View {
    let symbol: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: Tokens.Sidebar.rowActionIconSize, weight: .regular))
                .foregroundStyle(hovering ? Tokens.Sidebar.meetingTitle : Tokens.Sidebar.chromeIcon)
                .frame(width: Tokens.Sidebar.rowActionSlot, height: Tokens.Sidebar.rowActionSlot)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.Motion.hover), value: hovering)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// «Вернуть» on a row whose deletion has not landed yet.
///
/// A word, in the meta line's own 11 pt, weighted up so it out-reads the time
/// beside it. Deliberately not a filled pill: the offer belongs to this row, and
/// a button with its own background inside a list row reads as a second list.
struct SidebarRowRestore: View {
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text("Вернуть")
                .typo(Tokens.Sidebar.Typo.meta)
                .foregroundStyle(hovering ? Tokens.Sidebar.meetingTitle : Tokens.Sidebar.navLabelSelected)
                .padding(.horizontal, Tokens.Space.s4)
                .frame(height: Tokens.Sidebar.rowActionSlot)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.Motion.hover), value: hovering)
        .help("Вернуть удалённую запись")
        .accessibilityLabel("Вернуть удалённую запись")
    }
}

/// Where the rail's header row sits, in window coordinates.
///
/// Exists so a test can hold the rail to the one thing a screenshot of it can
/// never prove: that it starts at the *top of a real window*. Every gallery
/// board is captured in a borderless window, which has no titlebar and therefore
/// no safe-area inset — the surface where this goes wrong is structurally
/// invisible to the tool that photographs everything else.
public struct SidebarHeaderMidYKey: PreferenceKey {
    public static let defaultValue: CGFloat? = nil
    public static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = value ?? nextValue()
    }
}

// MARK: - Traffic lights

/// Where the window's own close / minimise / zoom buttons go.
///
/// AppKit puts them where it likes; the rail's 48 pt header wants them at
/// (24, 18), (44, 18), (64, 18) — Figma 31:4584. The arithmetic is here rather
/// than inside `SceneWindowChrome` because that file lives in the executable
/// target, where no test can reach it, and "the buttons are four points low" is
/// exactly the kind of thing that is only noticed months later in a screenshot.
///
/// The flip is the whole trick: titlebar coordinates grow *up* from the bottom
/// of the container, and the design measures down from the top of the window.
public enum SidebarTrafficLightLayout {

    /// Origin for the button at `index`, in its container's coordinates.
    public static func origin(
        index: Int,
        containerHeight: CGFloat,
        buttonHeight: CGFloat,
        leading: CGFloat = Tokens.Sidebar.trafficLightLeading,
        spacing: CGFloat = Tokens.Sidebar.trafficLightSpacing,
        top: CGFloat = Tokens.Sidebar.trafficLightTop
    ) -> CGPoint {
        CGPoint(
            x: leading + CGFloat(index) * spacing,
            y: containerHeight - top - buttonHeight
        )
    }

    /// Where the discs end up measured from the top of the window — the number
    /// the comps actually state.
    public static func centerYFromWindowTop(
        buttonHeight: CGFloat = Tokens.Sidebar.trafficLightDiameter,
        top: CGFloat = Tokens.Sidebar.trafficLightTop
    ) -> CGFloat {
        top + buttonHeight / 2
    }
}

// MARK: - The meeting line

/// One `Text`, two colours: the meeting's name, then what it is about (or what is
/// being done to it). Built as an `AttributedString` rather than two views so the
/// quiet half keeps flowing on the loud half's last line — the comps wrap
/// mid-sentence, and an `HStack` of two labels cannot do that.
///
/// Its own view because the rail is not the only thing that draws it: the ⌥Tab
/// switcher is another view of the same list, and a second copy of this rule is a
/// second place for the two halves to drift apart.
public struct SidebarMeetingParagraph: View {
    private let row: SidebarMeetingRowModel
    private let isSelected: Bool

    /// `isSelected` is passed rather than read off `row.state`: in the rail it
    /// means «панель показывает эту встречу», and in the switcher it means «сюда
    /// попадёшь, если отпустить ⌥» — the same ink, two different questions.
    public init(row: SidebarMeetingRowModel, isSelected: Bool) {
        self.row = row
        self.isSelected = isSelected
    }

    /// The rail's rule for the two inks. Static so the switcher's rows and the
    /// rail's working row read it instead of restating it.
    public static func inks(
        for state: SidebarRowState,
        isSelected: Bool
    ) -> (title: Color, preview: Color) {
        let working = state.activity.isInFlight
        // A deleted meeting reads like a working one — quiet. It is on its way
        // out, and the loud thing in the row has to be «Вернуть».
        let deleted = state.activity == .deletedUndoable
        let title = (working || deleted)
            ? Tokens.Sidebar.meetingPreview
            : Tokens.Sidebar.meetingTitle
        if working { return (title, Tokens.Sidebar.meetingPreview) }
        return (title, isSelected ? Tokens.Sidebar.meetingTitle : Tokens.Sidebar.meetingPreview)
    }

    public var body: some View {
        Text(attributed)
            .typoBlock(Tokens.Sidebar.Typo.meetingTitle)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var attributed: AttributedString {
        let inks = Self.inks(for: row.state, isSelected: isSelected)
        var title = AttributedString(row.title)
        title.foregroundColor = inks.title
        guard !row.preview.isEmpty else { return title }
        var preview = AttributedString((row.title.isEmpty ? "" : " ") + row.preview)
        preview.foregroundColor = inks.preview
        title.append(preview)
        return title
    }
}

// MARK: - Chrome button

/// The collapse toggle: 32 × 32, rounded 8, glyph at 40 % — quieter than any
/// `IconButton` prominence, because it sits next to the traffic lights and must
/// not compete with them.
public struct SidebarChromeButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    public init(symbol: String, help: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.action = action
    }

    /// Figma's own disc colours, for `SidebarTrafficLights.drawn`.
    static let discColors: [Color] = [
        Color(red: 1.0, green: 75.0 / 255.0, blue: 89.0 / 255.0),
        Color(red: 1.0, green: 198.0 / 255.0, blue: 0),
        Color(red: 0, green: 202.0 / 255.0, blue: 72.0 / 255.0),
    ]

    public var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                // 12, not 13: the comps' `sidebar.left` inks 14 × 11, which is
                // what this size draws. 13 is a point taller and reads as a
                // second button next to the traffic lights.
                .font(.system(size: Tokens.Sidebar.chromeIconSize, weight: .regular))
                .foregroundStyle(hovering ? Tokens.Paint.Text.primary : Tokens.Sidebar.chromeIcon)
                .frame(width: Tokens.Sidebar.toggleSide, height: Tokens.Sidebar.toggleSide)
                .background(
                    hovering ? Tokens.Sidebar.rowHover : .clear,
                    in: RoundedRectangle(cornerRadius: Tokens.Sidebar.rowRadius, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: Tokens.Sidebar.rowRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.Motion.hover), value: hovering)
        .help(help)
    }
}

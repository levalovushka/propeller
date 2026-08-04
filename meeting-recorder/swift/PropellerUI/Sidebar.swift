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

    /// What kind of control the row actually is.
    ///
    /// Settings needs its own case because opening the Settings scene is not
    /// something a closure can do. `NSApp.sendAction(showSettingsWindow:)` is
    /// the obvious way and it silently does nothing from a menu-bar app that is
    /// currently `.accessory` — which is exactly the state Propeller is in when
    /// the window is open. `SettingsLink` is the only API that works, and it is
    /// a *view*, so the row has to be built as one.
    public enum Role: Equatable, Sendable {
        case action
        case settings
    }

    public let id: String
    /// SF Symbol, named by the comps.
    public let symbol: String
    public let title: String
    public let role: Role
    /// Revealed on hover. The comps reserve the slot and paint it transparent.
    public let shortcut: String?
    public let isSelected: Bool
    /// A *forced* hover pose, OR-ed with the live pointer. Only the state
    /// gallery sets it — a still frame has no pointer, and a second "looks
    /// hovered" flag inside the view would let the gallery draw something the
    /// app cannot produce.
    public let isHovered: Bool

    public init(
        id: String,
        symbol: String,
        title: String,
        role: Role = .action,
        shortcut: String? = nil,
        isSelected: Bool = false,
        isHovered: Bool = false
    ) {
        self.id = id
        self.symbol = symbol
        self.title = title
        self.role = role
        self.shortcut = shortcut
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

    public init(
        id: String,
        meta: String,
        title: String,
        preview: String,
        state: SidebarRowState
    ) {
        self.id = id
        self.meta = meta
        self.title = title
        self.preview = preview
        self.state = state
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

    public init(
        nav: [SidebarNavItem],
        groups: [SidebarMeetingGroup],
        emptyMessage: String? = nil
    ) {
        self.nav = nav
        self.groups = groups
        self.emptyMessage = emptyMessage
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
    /// Bring back a meeting whose deletion is still undoable. Absent means the
    /// rows don't offer it.
    private let onRestoreMeeting: ((String) -> Void)?

    public init(
        model: SidebarModel,
        trafficLights: SidebarTrafficLights = .system,
        onNav: @escaping (String) -> Void = { _ in },
        onSelectMeeting: @escaping (String) -> Void = { _ in },
        onDeleteMeeting: ((String) -> Void)? = nil,
        onRestoreMeeting: ((String) -> Void)? = nil,
        onToggle: (() -> Void)? = nil
    ) {
        self.model = model
        self.trafficLights = trafficLights
        self.onNav = onNav
        self.onSelectMeeting = onSelectMeeting
        self.onDeleteMeeting = onDeleteMeeting
        self.onRestoreMeeting = onRestoreMeeting
        self.onToggle = onToggle
    }

    /// There is no toast layer. Everything the app has to say about a meeting is
    /// said by that meeting's own row — a deletion offering «Вернуть», a failure
    /// showing its mark — and everything it has to say about recording is said by
    /// the row that starts one. A bar that floated over the list said things
    /// nobody could act on, and one of them managed to blame the user for the
    /// app's own crash.
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

    private var header: some View {
        HStack(spacing: 0) {
            trafficLightSlot
            Spacer(minLength: Tokens.Space.s8)
            if let onToggle {
                SidebarChromeButton(symbol: "sidebar.left", help: "Скрыть список", action: onToggle)
            }
        }
        .padding(Tokens.Space.s12)
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
            .padding(.leading, Tokens.Sidebar.trafficLightLeading - Tokens.Space.s12)
        }
    }

    // MARK: Body (Frame 123) — px 12, py 10, gap 12

    /// The body's 12 pt inset is applied per block rather than to the whole
    /// column, so the scroll view can run the full width of the rail.
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
        // Top only: the list runs to the window edge and softens itself with an
        // alpha mask. A bottom inset here would leave a hard clip floating above
        // the bezel — the thing the mask is meant to erase.
        .padding(.top, Tokens.Sidebar.bodyVPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: Tokens.Sidebar.groupGap) {
                    ForEach(model.groups) { group in
                        VStack(alignment: .leading, spacing: 0) {
                            if let header = group.header {
                                Text(header)
                                    .typoBlock(Tokens.Sidebar.Typo.sectionHeader)
                                    .foregroundStyle(Tokens.Sidebar.sectionHeader)
                                    .padding(.horizontal, Tokens.Sidebar.meetingHPadding)
                                    .padding(.bottom, Tokens.Sidebar.sectionHeaderBottomGap)
                            }
                            ForEach(group.rows) { row in
                                SidebarMeetingRow(
                                    row: row,
                                    action: { onSelectMeeting(row.id) },
                                    onDelete: onDeleteMeeting.map { delete in { delete(row.id) } },
                                    onRestore: onRestoreMeeting.map { restore in { restore(row.id) } }
                                )
                            }
                        }
                    }
                }
                .padding(.horizontal, Tokens.Sidebar.bodyHPadding)
                // Room to scroll the last row clear of the fade, so it does not
                // sit permanently half-transparent at the end of the list.
                .padding(.bottom, Tokens.Sidebar.listEdgeFade)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            // Alpha mask, not a painted gradient: black keeps ink, clear drops
            // it. The rail's own wash shows through whichever shade the glass
            // is wearing that day.
            .mask {
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(
                        colors: [.black, .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: Tokens.Sidebar.listEdgeFade)
                }
            }
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
        item.isSelected ? Tokens.Sidebar.navLabelSelected : Tokens.Sidebar.navLabel
    }

    private var fill: Color {
        if item.isSelected { return Tokens.Sidebar.rowSelected }
        return isHovered ? Tokens.Sidebar.rowHover : .clear
    }

    public var body: some View {
        control
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: Tokens.Motion.hover), value: hovering)
            .animation(.easeOut(duration: Tokens.Motion.hover), value: item.isSelected)
    }

    /// Same chrome, two different controls underneath. The Settings scene can
    /// only be opened by `SettingsLink`, so that row is a link wearing the row's
    /// clothes rather than a button that calls something.
    @ViewBuilder
    private var control: some View {
        switch item.role {
        case .action:
            Button(action: action) { label }
        case .settings:
            SettingsLink { label }
        }
    }

    private var label: some View {
        HStack(spacing: Tokens.Sidebar.navRowGap) {
            Image(systemName: item.symbol)
                .font(.system(size: Tokens.Sidebar.navIconSize, weight: .regular))
                .frame(width: Tokens.Sidebar.navIconSide, height: Tokens.Sidebar.navIconSide)

            Text(item.title)
                .typo(Tokens.Sidebar.Typo.navLabel)
                .lineLimit(1)
                .padding(.horizontal, Tokens.Sidebar.navLabelInset)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let shortcut = item.shortcut {
                // The comps reserve this slot and paint it transparent, so
                // the row's width never moves; showing it under the pointer
                // is the only way the reservation earns its keep.
                Text(shortcut)
                    .typo(Tokens.Sidebar.Typo.meta)
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
}

// MARK: - Meeting row (meetingitem)

/// px 12 / py 10, rounded 8, two lines 4 pt apart: the time, then the title and
/// its preview run together as one wrapping paragraph.
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
    /// «Показать в Finder» used to live here too. It is a thing you do to a
    /// meeting *occasionally*, from the card's «ещё» menu where it still is —
    /// and two icons appearing under the pointer made the row's quiet slot busy
    /// for the one action that is not routine.
    let onDelete: (() -> Void)?
    /// Present only while the deletion can still be taken back.
    let onRestore: (() -> Void)?

    @State private var hovering = false

    public init(
        row: SidebarMeetingRowModel,
        action: @escaping () -> Void,
        onDelete: (() -> Void)? = nil,
        onRestore: (() -> Void)? = nil
    ) {
        self.row = row
        self.action = action
        self.onDelete = onDelete
        self.onRestore = onRestore
    }

    private var isHovered: Bool { hovering || row.state.isHovered }
    private var isWorking: Bool { row.state.activity == .processing }
    private var isDeleted: Bool { row.state.activity == .deletedUndoable }

    private var fill: Color {
        if row.state.isSelected { return Tokens.Sidebar.rowSelected }
        return isHovered ? Tokens.Sidebar.rowHover : .clear
    }

    private var titleColor: Color {
        // A deleted meeting reads like a working one — quiet. It is on its way
        // out, and the loud thing in the row has to be «Вернуть».
        (isWorking || isDeleted) ? Tokens.Sidebar.meetingPreview : Tokens.Sidebar.meetingTitle
    }

    private var previewColor: Color {
        if isWorking { return Tokens.Sidebar.meetingPreview }
        return row.state.isSelected ? Tokens.Sidebar.meetingTitle : Tokens.Sidebar.meetingPreview
    }

    public var body: some View {
        // A deleted row is not clickable: there is nothing to open, and a body
        // that restored on any click would undo deletions people meant.
        Button(action: isDeleted ? {} : action) {
            VStack(alignment: .leading, spacing: Tokens.Sidebar.meetingLineGap) {
                metaLine
                titleLine
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
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.Motion.hover), value: hovering)
        .animation(.easeOut(duration: Tokens.Motion.hover), value: row.state)
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
        case .none, .processing, .deletedUndoable:
            // Working already says so, in words and in motion; a deleted row
            // spends the slot on «Вернуть».
            EmptyView()
        }
    }

    private var titleLine: some View {
        paragraph
            .overlay {
                if isWorking {
                    SidebarSweep().mask(paragraph)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One `Text`, two colours. Built as an `AttributedString` rather than two
    /// views so the preview keeps flowing on the title's last line — the comps
    /// wrap mid-sentence, and an `HStack` of two labels cannot do that.
    private var paragraph: some View {
        Text(attributed)
            .typoBlock(Tokens.Sidebar.Typo.meetingTitle)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var attributed: AttributedString {
        var title = AttributedString(row.title)
        title.foregroundColor = titleColor
        guard !row.preview.isEmpty else { return title }
        var preview = AttributedString((row.title.isEmpty ? "" : " ") + row.preview)
        preview.foregroundColor = previewColor
        title.append(preview)
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
                .typo(Tokens.Sidebar.Typo.meta.weight(.medium))
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

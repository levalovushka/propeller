import SwiftUI
import AppKit
import PropellerPure

/// # The content pane — Figma 31:4624
///
/// What the rail points at: a 48 pt header carrying the meeting's identity and
/// the three things you can do to it, then two columns — what the meeting *was*
/// on the left, what you wrote during it on the right.
///
/// Both columns flex. The summary takes what it can up to a readable measure and
/// the notes take the rest, so the same pane works at 800 pt and at 520 without
/// a breakpoint. Pure presentation, like the rail: it takes text and hands back
/// callbacks, which is what lets the gallery draw it with no meeting on disk.

// MARK: - Header

/// Constants of the header's name field. Outside the view because a generic
/// type cannot hold stored statics.
private enum HeaderTitle {
    /// Room for the caret past the last glyph, so it is not clipped at the edge.
    static let caretRoom: CGFloat = 4
    static let untitled = "Без названия"
}

/// The meeting's name and the actions you can take on it.
///
/// One line, 14 / 18 — the same face as a meeting row's title. Clicking the
/// name places the caret where you clicked; Enter saves and leaves, Escape
/// leaves the name as it was, clicking away saves. The date lives on the rail,
/// so it is not repeated here.
public struct MeetingPaneHeader<MoreMenu: View>: View {
    /// Which meeting the name belongs to. The header outlives the meeting it is
    /// showing — the pane keeps one of these and swaps the text underneath it —
    /// so a rename has to name its own meeting rather than trust «the selected
    /// one» to still be the one that was typed into.
    private let meetingID: String
    private let title: String
    private let onRename: ((_ meetingID: String, _ newTitle: String) -> Void)?
    private let share: Share?
    /// The ellipsis is a *menu*, not a button — «ещё» has no single action, and
    /// a closure would only be able to open one somewhere else.
    private let moreMenu: () -> MoreMenu
    private let hasMoreMenu: Bool

    /// Opens the system share sheet from the header's quiet icon cluster.
    public struct Share {
        public let title: String
        public let handler: () -> Void
        public init(_ title: String, handler: @escaping () -> Void) {
            self.title = title
            self.handler = handler
        }
    }

    public init(
        meetingID: String,
        title: String,
        onRename: ((_ meetingID: String, _ newTitle: String) -> Void)? = nil,
        share: Share? = nil,
        hasMoreMenu: Bool = true,
        @ViewBuilder moreMenu: @escaping () -> MoreMenu
    ) {
        self.meetingID = meetingID
        self.title = title
        self.onRename = onRename
        self.share = share
        self.moreMenu = moreMenu
        self.hasMoreMenu = hasMoreMenu
    }

    public var body: some View {
        HStack(spacing: 0) {
            MeetingPaneIdentity(meetingID: meetingID, title: title, onRename: onRename)
            Spacer(minLength: Tokens.Space.s8)
            actions
        }
        .frame(height: Tokens.Pane.headerHeight)
    }

    private var actions: some View {
        HStack(spacing: Tokens.Pane.headerActionsGap) {
            if hasMoreMenu {
                Menu {
                    moreMenu()
                } label: {
                    PaneIconLabel(symbol: "ellipsis")
                }
                // `.borderlessButton` draws its own control over the label, so
                // the hover chrome never showed and the ellipsis read as decoration
                // beside a real button. `.button` + `.plain` hands the whole
                // appearance back to the label.
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .help("Ещё")
            }
            if let share {
                PaneIconButton(
                    symbol: "arrowshape.turn.up.right.fill",
                    help: share.title,
                    action: share.handler
                )
            }
        }
        .padding(.horizontal, Tokens.Pane.headerActionsPadding)
        .frame(height: Tokens.Pane.headerHeight)
        .fixedSize()
    }
}

/// The meeting's name, editable in place.
///
/// Its own view because two headers carry it: the one over a finished meeting
/// and the one over the meeting being recorded. A recording is a meeting from
/// the first second — it has a name, and that name is renamed the same way,
/// with the same pencil in the same place.
struct MeetingPaneIdentity: View {
    let meetingID: String
    let title: String
    let onRename: ((_ meetingID: String, _ newTitle: String) -> Void)?

    /// A name being typed, and the meeting it is being typed into.
    ///
    /// `original` travels with it because that is what "did it change" has to be
    /// asked against: a rename latches the title as manual and blocks the model
    /// from ever naming that meeting again, so re-saving the identical string is
    /// not the no-op it looks like.
    private struct Edit: Equatable {
        let meetingID: String
        let original: String
        var draft: String
    }

    @State private var edit: Edit?
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        identity
            // Picking another meeting mid-edit saves into the meeting you were
            // editing and shows the one you picked. It used to hand your text to
            // the meeting you had just moved to, which is a rename nobody asked
            // for in one place and a lost one in the other.
            .onChange(of: meetingID) { _, _ in
                commit()
                focused = false
            }
            // The same save for when the header is *replaced* rather than handed a
            // new meeting: the pane swaps its whole subject on a switch now, so
            // this view is destroyed and the `onChange` above never runs. The edit
            // carries the id it was typed into, so a commit on the way out lands in
            // the right meeting — and `commit` is a no-op when nothing was typed.
            .onDisappear { commit() }
    }

    private var identity: some View {
        HStack(spacing: Tokens.Space.s4) {
            titleField
            editHint
        }
        .padding(.horizontal, Tokens.Pane.headerHPadding)
        .padding(.vertical, Tokens.Pane.headerVPadding)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // A cap, not a width — and minWidth 0 so the pane can go narrow without
        // the title claiming more room than the actions leave it.
        .frame(minWidth: 0, maxWidth: Tokens.Pane.headerTitleWidth, alignment: .leading)
        .animation(.easeOut(duration: Tokens.Motion.hover), value: hovering)
        .animation(.easeOut(duration: Tokens.Motion.hover), value: focused)
    }

    private var titleField: some View {
        TextField(HeaderTitle.untitled, text: text)
            .textFieldStyle(.plain)
            .typoBlock(Tokens.Pane.Typo.headerTitle)
            .foregroundStyle(Tokens.Pane.title)
            .lineLimit(1)
            .focused($focused)
            .disabled(onRename == nil)
            // Return saves *and* leaves. Left focused, AppKit answers Return by
            // selecting the whole field — the save had happened, and the only
            // thing you could see was your name going blue.
            .onSubmit {
                commit()
                focused = false
            }
            .onExitCommand { cancel() }
            .onChange(of: focused) { _, isFocused in
                if isFocused { begin() } else { commit() }
            }
            // As wide as the name, no wider: the pencil belongs at the end of
            // the title, not at the far edge of a 430 pt block. minWidth 0 so a
            // long name yields to the actions instead of shoving them off.
            .frame(minWidth: 0, maxWidth: titleWidth, alignment: .leading)
            .mask { GeometryReader { geo in edgeFade(given: geo.size.width) } }
    }

    /// The affordance, right beside the name: a pencil while you are looking at
    /// it, the Return key while you are typing — at that moment the question is
    /// no longer «can this be edited» but «how do I keep what I typed».
    @ViewBuilder
    private var editHint: some View {
        if onRename != nil {
            Image(systemName: focused ? "return" : "pencil")
                .font(.system(size: Tokens.Pane.headerIconSize, weight: .regular))
                .foregroundStyle(Tokens.Pane.buttonIcon)
                .opacity(hovering || focused ? 1 : 0)
                // A hint, not a button. Clicking it would take focus off the
                // field, which already saves — and a control that looks like it
                // does something else is worse than no control.
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// What the field shows: the name being typed, or the meeting's own.
    ///
    /// Reading through to `title` is what lets an outside rename — the model
    /// naming a meeting the moment its summary lands — appear without a flag to
    /// guard it, and *not* appear over something half-typed.
    private var text: Binding<String> {
        Binding(
            get: { edit?.draft ?? title },
            set: { typed in
                begin()
                edit?.draft = typed
            }
        )
    }

    /// Measured in the face the field actually draws with, so the pencil lands
    /// against the name at any length.
    private var titleWidth: CGFloat {
        let shown = edit?.draft ?? title
        let string = shown.isEmpty ? HeaderTitle.untitled : shown
        let width = (string as NSString).size(
            withAttributes: [.font: Tokens.Pane.Typo.headerTitle.nsFont]
        ).width
        return ceil(width) + HeaderTitle.caretRoom
    }

    /// A name longer than its room meets the actions with a fade rather than a
    /// cut — and only then. Faded unconditionally, the last letters of every
    /// short name would go pale for no reason.
    private func edgeFade(given width: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.black
            if width < titleWidth {
                LinearGradient(
                    colors: [.black, .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: Tokens.Pane.titleEdgeFade)
            }
        }
    }

    private func begin() {
        guard onRename != nil, edit == nil else { return }
        edit = Edit(meetingID: meetingID, original: title, draft: title)
    }

    /// Escape gives the meeting its name back — there is no undo up here, so
    /// the one key that means «forget it» has to actually forget it.
    private func cancel() {
        edit = nil
        focused = false
    }

    private func commit() {
        guard let edit else { return }
        self.edit = nil
        let trimmed = edit.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // A meeting with no name is a meeting you cannot find again: an empty
        // field keeps the name it had.
        guard !trimmed.isEmpty, trimmed != edit.original else { return }
        onRename?(edit.meetingID, trimmed)
    }
}

extension MeetingPaneHeader where MoreMenu == EmptyView {
    /// A header with no «ещё» menu — the gallery, and any pane whose meeting
    /// has nothing more to offer.
    public init(
        meetingID: String,
        title: String,
        onRename: ((_ meetingID: String, _ newTitle: String) -> Void)? = nil,
        share: Share? = nil
    ) {
        self.init(
            meetingID: meetingID, title: title,
            onRename: onRename, share: share,
            hasMoreMenu: false,
            moreMenu: { EmptyView() }
        )
    }
}

/// The label of the ellipsis `Menu`.
///
/// It carries the same hover chrome as `PaneIconButton` on purpose: it sits
/// immediately beside one, and a control that lights up next to one that does
/// not reads as broken rather than as a different kind of control.
struct PaneIconLabel: View {
    let symbol: String

    @State private var hovering = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: Tokens.Pane.headerIconSize, weight: .regular))
            .foregroundStyle(hovering ? Tokens.Paint.Text.primary : Tokens.Pane.buttonIcon)
            .frame(width: Tokens.Pane.headerButtonSide, height: Tokens.Pane.headerButtonSide)
            .background(
                hovering ? Tokens.Sidebar.rowHover : .clear,
                in: RoundedRectangle(cornerRadius: Tokens.Pane.headerButtonRadius, style: .continuous)
            )
            .contentShape(
                RoundedRectangle(cornerRadius: Tokens.Pane.headerButtonRadius, style: .continuous)
            )
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: Tokens.Motion.hover), value: hovering)
    }
}

/// 32 × 32, rounded 8, glyph at 40 % — the header's quiet actions.
struct PaneIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: Tokens.Pane.headerIconSize, weight: .regular))
                .foregroundStyle(hovering ? Tokens.Paint.Text.primary : Tokens.Pane.buttonIcon)
                .frame(width: Tokens.Pane.headerButtonSide, height: Tokens.Pane.headerButtonSide)
                .background(
                    hovering ? Tokens.Sidebar.rowHover : .clear,
                    in: RoundedRectangle(cornerRadius: Tokens.Pane.headerButtonRadius, style: .continuous)
                )
                .contentShape(
                    RoundedRectangle(cornerRadius: Tokens.Pane.headerButtonRadius, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.Motion.hover), value: hovering)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Presents the system share sheet from the button that asked for it.
///
/// `NSSharingServicePicker` needs a real view to hang off — a share sheet that
/// appears in the corner of the screen instead of under the button is the kind
/// of thing that looks broken even when it works. So the button keeps an
/// invisible AppKit anchor at its own position.
public struct ShareAnchor: NSViewRepresentable {
    private let items: () -> [Any]
    @Binding private var isPresented: Bool

    public init(isPresented: Binding<Bool>, items: @escaping () -> [Any]) {
        self._isPresented = isPresented
        self.items = items
    }

    public func makeNSView(context: Context) -> NSView { NSView() }

    public func updateNSView(_ view: NSView, context: Context) {
        guard isPresented else { return }
        DispatchQueue.main.async {
            isPresented = false
            let payload = items()
            guard !payload.isEmpty, view.window != nil else { return }
            let picker = NSSharingServicePicker(items: payload)
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        }
    }
}

// MARK: - Summary column

/// The summary the pane draws — and edits. `SummaryDocument` is where the
/// markdown's surprises are handled, and the reason it round-trips.
public typealias MeetingSummary = SummaryDocument

/// The summary, as a text you can put a caret into.
///
/// There is no read mode and no edit mode: one surface, always the same
/// typography, and the caret appears wherever it was clicked. A mode would
/// re-flow the column under the pointer — the 20 pt lead collapsing into
/// monospaced markdown is exactly what the pre-redesign screen did, and what
/// made editing a summary something you did on purpose rather than by reflex.
public struct MeetingSummaryColumn: View {
    private let summary: MeetingSummary
    /// Shown instead of the summary when there is not one yet — a meeting is
    /// readable long before the model has finished with it.
    private let placeholder: String?
    /// nil — nowhere to save it, so nothing to type into: the gallery, and any
    /// pane whose meeting has no recap file behind it.
    private let onChange: ((MeetingSummary) -> Void)?
    private let onRewrite: ((SummaryRewrite, String) -> Void)?
    @ObservedObject private var controller: SummaryEditorController

    @State private var height: CGFloat = 0
    /// Ширина/высота колонки и ширина панели — чтобы панель не уезжала за край.
    @State private var columnWidth: CGFloat = 0
    @State private var columnHeight: CGFloat = 0
    @State private var barWidth: CGFloat = 0

    public init(
        summary: MeetingSummary,
        placeholder: String? = nil,
        controller: SummaryEditorController,
        onChange: ((MeetingSummary) -> Void)? = nil,
        onRewrite: ((SummaryRewrite, String) -> Void)? = nil
    ) {
        self.summary = summary
        self.placeholder = placeholder
        self.controller = controller
        self.onChange = onChange
        self.onRewrite = onRewrite
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Pane.summaryBlockGap) {
            if let placeholder, summary.isEmpty {
                Text(placeholder)
                    .typoBlock(Tokens.Pane.Typo.body)
                    .foregroundStyle(Tokens.Pane.placeholder)
            } else {
                editor
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Tokens.Pane.summaryHPadding)
        .padding(.top, Tokens.Pane.summaryVPadding)
        .padding(.bottom, Tokens.Pane.summaryBottomPadding)
        // The measure is capped for readability and then *centred* in whatever
        // room the column has. Pinned left, a wide window leaves the text
        // against one edge with a field of empty beside it.
        .frame(maxWidth: Tokens.Pane.summaryMaxWidth + Tokens.Pane.summaryHPadding * 2)
        .frame(maxWidth: .infinity)
    }

    private var editor: some View {
        SummaryEditor(
            document: summary,
            // Editable while the typewriter runs: `shouldChangeText` rejects
            // programmatic replace when `isEditable` is false, which left the
            // dismissed fragment stuck at alpha 0 and put nothing on the undo
            // stack. User typing is swallowed in `SummaryTextView` instead.
            isEditable: onChange != nil && !controller.isRewriting,
            controller: controller,
            height: $height,
            onChange: { onChange?($0) }
        )
        .frame(height: height)
        .overlay(alignment: .topLeading) { shimmer }
        .overlay(alignment: .topLeading) { actionBar }
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        columnWidth = geo.size.width
                        columnHeight = geo.size.height
                    }
                    .onChange(of: geo.size.width) { _, new in columnWidth = new }
                    .onChange(of: geo.size.height) { _, new in columnHeight = new }
            }
        }
    }

    /// The fragment the model is being asked about, shimmering.
    ///
    /// Glyph silhouette + band-only Metal (`sidebarSweepBand`): outside the
    /// diagonal the overlay is clear, so the editor letters stay put; inside
    /// it they light up. Geometry from `rewriteTarget`, not `selection` — the
    /// wash is gone the moment the model starts.
    @ViewBuilder
    private var shimmer: some View {
        if controller.isRewriting,
           let target = controller.rewriteTarget,
           let glyphs = target.glyphs {
            Image(nsImage: glyphs)
                .resizable()
                .sidebarSweepBand()
                .frame(width: target.bounds.width, height: target.bounds.height)
                .offset(x: target.bounds.minX, y: target.bounds.minY)
                .allowsHitTesting(false)
        }
    }

    /// Under the last line of the selection, kept inside the column: a bar half
    /// off the edge is a bar with half its actions unreachable.
    ///
    /// It does not travel. Selecting somewhere else replaces the bar — `.id` on
    /// the selection's range — so the old one fades out where it stood and the
    /// new one fades in where it belongs. Animating the offset instead made a
    /// control slide across the text under the pointer, which is the app moving
    /// something nobody asked it to move. While the model thinks, the bar is
    /// gone — the shimmer is the only signal left.
    @ViewBuilder
    private var actionBar: some View {
        if let selection = controller.selection, onChange != nil, !controller.isRewriting {
            // Hosted in AppKit so the click does not resign the text view —
            // selection and ⌘Z target stay where the person left them.
            SummaryActionBarHost(
                selection: selection,
                onKind: { controller.setKind($0) },
                onBold: { controller.toggleBold() },
                onItalic: { controller.toggleItalic() },
                onRewrite: onRewrite.map { handler in
                    { (rewrite: SummaryRewrite) in
                        controller.pinRewriteTarget(selection)
                        handler(rewrite, selection.text)
                    }
                },
                onMeasuredWidth: { barWidth = $0 }
            )
            .fixedSize()
            .offset(
                x: clampedX(for: selection),
                y: clampedY(for: selection)
            )
            .id(selection.range)
            .transition(AnyTransition.asymmetric(
                insertion: .opacity.animation(
                    .easeOut(duration: Tokens.Pane.Bar.fadeIn)
                        .delay(Tokens.Pane.Bar.fadeInDelay)
                ),
                removal: .opacity.animation(.easeIn(duration: Tokens.Pane.Bar.fadeOut))
            ))
        }
    }

    /// The bar starts under the selection and stops at the column's edge —
    /// `SummaryBarPlacement`, where a test can reach the arithmetic.
    private func clampedX(for selection: SummaryEditorController.Selection) -> CGFloat {
        SummaryBarPlacement.x(
            anchor: selection.anchor.x,
            // Before the first layout the bar has no width yet. Its height is
            // the one number that is certainly not zero, and one frame at the
            // wrong x beats one frame at zero.
            barWidth: barWidth > 0 ? barWidth : Tokens.Pane.Bar.height,
            columnWidth: columnWidth
        )
    }

    /// Under the selection when there is room; above it when the last line
    /// would push the bar past the column's bottom.
    private func clampedY(for selection: SummaryEditorController.Selection) -> CGFloat {
        SummaryBarPlacement.y(
            selectionTop: selection.bounds.minY,
            selectionBottom: selection.anchor.y,
            barHeight: Tokens.Pane.Bar.height,
            columnHeight: columnHeight > 0 ? columnHeight : height,
            gap: Tokens.Pane.Bar.anchorGap
        )
    }

}

// MARK: - Notes column

public struct MeetingNote: Identifiable, Equatable, Sendable {
    public let id: String
    public let text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

/// What you wrote while it was happening, and a place to write more.
///
/// Every entry is a plate — the rail's meeting row, in the other column: same
/// fill, same corner, same insets. Before them the column was text on a
/// background, and two short notes in a row read as one paragraph with a
/// strange line break in it. Where one ends is a thing the eye should not have
/// to work out from the meaning.
public struct MeetingNotesColumn: View {
    private let notes: [MeetingNote]
    private let composer: MeetingPaneBody.NoteComposer?
    /// Raised by the collapsed button: the notes were *asked* for, so the
    /// composer takes the caret the moment it exists. Lowered as soon as it is
    /// honoured — a request left standing steals the caret on every re-layout.
    private let focusRequest: Binding<Bool>?
    /// Puts the column away. Absent in the gallery, where there is no window to
    /// shrink — the header then carries its title and nothing else.
    private let onCollapse: (() -> Void)?

    @FocusState private var composerFocused: Bool

    public init(
        notes: [MeetingNote],
        composer: MeetingPaneBody.NoteComposer? = nil,
        focusRequest: Binding<Bool>? = nil,
        onCollapse: (() -> Void)? = nil
    ) {
        self.notes = notes
        self.composer = composer
        self.focusRequest = focusRequest
        self.onCollapse = onCollapse
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Pane.noteGap) {
            header
            if let composer {
                NoteComposerRow(composer: composer, focused: $composerFocused)
            }
            ForEach(notes) { note in
                NoteRow(text: note.text, style: Tokens.Pane.Typo.note, colour: Tokens.Pane.body)
            }
        }
        .padding(.horizontal, Tokens.Pane.notesHPadding)
        .padding(.vertical, Tokens.Pane.notesVPadding)
        .frame(minWidth: Tokens.Pane.notesMinWidth, alignment: .leading)
        // `onAppear`, not only `onChange`: the column does not exist yet when
        // the request is made — the window is still growing — so the change it
        // would listen for happens before there is anything to listen with.
        .onAppear { claimFocus() }
        .onChange(of: focusRequest?.wrappedValue ?? false) { _, _ in claimFocus() }
    }

    /// Says what the column is, and holds the one control that can take it
    /// away. The button sits hard against the column's inset, which is the
    /// pane's inset too — so it stands in the same vertical line as «поделиться»
    /// in the header above and as the folded button that replaces this column.
    private var header: some View {
        HStack(spacing: 0) {
            Text("Заметки")
                .typoBlock(Tokens.Pane.Typo.notesHeader)
                .foregroundStyle(Tokens.Pane.placeholder)
                .padding(.leading, Tokens.Pane.notesHeaderLeadingInset)
            Spacer(minLength: Tokens.Space.s8)
            if let onCollapse {
                PaneIconButton(
                    symbol: "chevron.right.2",
                    help: "Скрыть заметки — окно станет уже",
                    action: onCollapse
                )
            }
        }
        .frame(maxWidth: .infinity, minHeight: Tokens.Pane.notesHeaderHeight)
    }

    private func claimFocus() {
        guard focusRequest?.wrappedValue == true else { return }
        DispatchQueue.main.async {
            focusRequest?.wrappedValue = false
            composerFocused = true
        }
    }
}

/// The row you type into. Sits above the notes, like the comps' `empty-writing`.
private struct NoteComposerRow: View {
    let composer: MeetingPaneBody.NoteComposer
    /// Held by the column, bound here: focus belongs to the field itself, and
    /// `.focused` on the wrapper is a coin toss about which descendant it means.
    @FocusState.Binding var focused: Bool

    var body: some View {
        TextField(composer.placeholder, text: composer.text, axis: .vertical)
            .textFieldStyle(.plain)
            .focused($focused)
            .typoBlock(Tokens.Pane.Typo.note)
            .foregroundStyle(Tokens.Pane.body)
            .lineLimit(1...6)
            .onSubmit(composer.onCommit)
            .notePlate()
    }
}

private struct NoteRow: View {
    let text: String
    let style: Tokens.Typography.Style
    let colour: Color

    var body: some View {
        Text(text)
            .typoBlock(style)
            .foregroundStyle(colour)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .notePlate()
    }
}

private extension View {
    /// One note's plate. The composer wears it too: what you are writing and
    /// what you wrote are the same kind of thing, and a field that looks unlike
    /// its own output reads as a search box.
    func notePlate() -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Tokens.Pane.noteHPadding)
            .padding(.vertical, Tokens.Pane.noteVPadding)
            .background(
                Tokens.Pane.notePlateFill,
                in: RoundedRectangle(cornerRadius: Tokens.Pane.noteRadius, style: .continuous)
            )
    }
}

// MARK: - Transcript column

/// One remark: who, when, and what they said — Figma 32:5278.
///
/// Read-only. The transcript is a record of what was captured, and an editable
/// record is one you can no longer trust to be what was captured.
public struct MeetingTranscriptColumn: View {
    public struct Turn: Identifiable, Equatable, Sendable {
        public let id: String
        public let speaker: String
        public let time: String
        public let text: String

        public init(id: String, speaker: String, time: String, text: String) {
            self.id = id
            self.speaker = speaker
            self.time = time
            self.text = text
        }
    }

    private let turns: [Turn]
    private let emptyMessage: String
    private let disclosure: String?

    /// `disclosure` states what this transcript is *not* — «спикеры не разделены»
    /// when there was no clustering. Set in the same tone as the rest of the
    /// column, above the first remark, because it describes everything below it.
    /// It is not a warning: nothing failed, the depth is simply the depth
    /// (`design/no-dead-ends.md` §7).
    ///
    /// Only about *this column*. Why the meeting stopped where it did belongs to
    /// the thing that is missing — the summary column's own placeholder — and
    /// carrying both here made one line out of two different thoughts.
    public init(
        turns: [Turn],
        emptyMessage: String = "Расшифровки пока нет",
        disclosure: String? = nil
    ) {
        self.turns = turns
        self.emptyMessage = emptyMessage
        self.disclosure = disclosure
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Pane.transcriptTurnGap) {
            if turns.isEmpty {
                Text(emptyMessage)
                    .typoBlock(Tokens.Pane.Typo.body)
                    .foregroundStyle(Tokens.Pane.placeholder)
            }
            if let disclosure, !turns.isEmpty {
                Text(disclosure)
                    .typoBlock(Tokens.Pane.Typo.transcriptMeta)
                    .foregroundStyle(Tokens.Pane.meta)
            }
            ForEach(turns) { turn in
                VStack(alignment: .leading, spacing: Tokens.Pane.transcriptLineGap) {
                    HStack(spacing: Tokens.Pane.transcriptMetaGap) {
                        Text(turn.speaker)
                            .typoBlock(Tokens.Pane.Typo.transcriptMeta)
                            .lineLimit(1)
                        Text(turn.time)
                            .typoBlock(Tokens.Pane.Typo.transcriptMeta, monospacedDigit: true)
                            .frame(width: Tokens.Pane.transcriptTimeWidth, alignment: .leading)
                    }
                    .foregroundStyle(Tokens.Pane.meta)
                    Text(turn.text)
                        .typoBlock(Tokens.Pane.Typo.transcriptBody)
                        .foregroundStyle(Tokens.Pane.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .multilineTextAlignment(.leading)
        .padding(.horizontal, Tokens.Pane.summaryHPadding)
        .padding(.vertical, Tokens.Pane.summaryVPadding)
        .frame(maxWidth: Tokens.Pane.summaryMaxWidth + Tokens.Pane.summaryHPadding * 2)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - The two columns together

/// Which of the two the left column is showing.
///
/// The comps put this switch in the action bar; the bar is not built yet, so it
/// lives in the header's «ещё» menu until it is.
public enum MeetingPaneMode: String, CaseIterable, Equatable, Sendable {
    case summary, transcript

    public var title: String {
        switch self {
        case .summary:    return "Саммари"
        case .transcript: return "Транскрипт"
        }
    }
}

/// The pane's body: the meeting on the left, your notes on the right.
public struct MeetingPaneBody: View {
    private let mode: MeetingPaneMode
    private let summary: MeetingSummary
    private let turns: [MeetingTranscriptColumn.Turn]
    private let notes: [MeetingNote]
    private let composer: NoteComposer?
    /// Что стоит в колонке саммари — решено `SummaryColumnContent`, не здесь.
    private let summaryContent: SummaryColumnContent
    /// Откуда взяты реплики: живая строка или готовая расшифровка. Отличать их
    /// надо ради замены — момент, когда проход по файлу вытесняет живой текст,
    /// это смена содержания, а не перерисовка.
    private let transcriptSource: TranscriptSource
    private let transcriptDisclosure: String?
    /// What the collapsed notes button asks for: room. The pane cannot make
    /// any — its width is the window's — so it hands the request up.
    private let onRevealNotes: (() -> Void)?
    /// The same request the other way round: give the room back.
    private let onHideNotes: (() -> Void)?
    /// Их убрали руками, а не по нехватке места.
    private let notesHidden: Bool
    /// Set by whoever answers that request, cleared by the composer once it has
    /// the caret. See `MeetingNotesColumn.focusRequest`.
    private let notesFocusRequest: Binding<Bool>?
    /// Left column width held while the window grows for the notes. See
    /// `PaneColumns.pinnedLeftWidth`.
    private let pinnedLeftWidth: Binding<CGFloat?>?
    /// The summary's caret and what the action bar does to it. Owned above the
    /// pane, because the pane is rebuilt on every keystroke in the notes.
    private let summaryController: SummaryEditorController
    /// nil where a summary cannot be saved: the gallery, and a meeting with no
    /// recap file to write into.
    private let onSummaryChange: ((MeetingSummary) -> Void)?
    private let onSummaryRewrite: ((SummaryRewrite, String) -> Void)?

    /// The «Добавьте заметку…» row, when notes can be written.
    public struct NoteComposer {
        public let placeholder: String
        public let text: Binding<String>
        public let onCommit: () -> Void

        public init(placeholder: String = "Добавьте заметку…",
                    text: Binding<String>,
                    onCommit: @escaping () -> Void) {
            self.placeholder = placeholder
            self.text = text
            self.onCommit = onCommit
        }
    }

    /// Чей текст сейчас в колонке транскрипта.
    public enum TranscriptSource: String, Equatable, Sendable {
        /// Встреча идёт или только что кончилась: то, что услышал живой слой.
        case live
        /// Проход по файлу закончен — это он.
        case stored
    }

    public init(
        mode: MeetingPaneMode = .summary,
        summary: MeetingSummary,
        turns: [MeetingTranscriptColumn.Turn] = [],
        notes: [MeetingNote],
        composer: NoteComposer? = nil,
        summaryContent: SummaryColumnContent = .summary,
        transcriptSource: TranscriptSource = .stored,
        transcriptDisclosure: String? = nil,
        onRevealNotes: (() -> Void)? = nil,
        onHideNotes: (() -> Void)? = nil,
        notesHidden: Bool = false,
        notesFocusRequest: Binding<Bool>? = nil,
        pinnedLeftWidth: Binding<CGFloat?>? = nil,
        summaryController: SummaryEditorController = SummaryEditorController(),
        onSummaryChange: ((MeetingSummary) -> Void)? = nil,
        onSummaryRewrite: ((SummaryRewrite, String) -> Void)? = nil
    ) {
        self.mode = mode
        self.summary = summary
        self.turns = turns
        self.notes = notes
        self.composer = composer
        self.summaryContent = summaryContent
        self.transcriptSource = transcriptSource
        self.transcriptDisclosure = transcriptDisclosure
        self.onRevealNotes = onRevealNotes
        self.onHideNotes = onHideNotes
        self.notesHidden = notesHidden
        self.notesFocusRequest = notesFocusRequest
        self.pinnedLeftWidth = pinnedLeftWidth
        self.summaryController = summaryController
        self.onSummaryChange = onSummaryChange
        self.onSummaryRewrite = onSummaryRewrite
    }

    public var body: some View {
        PaneColumns(
            notes: notes,
            composer: composer,
            onRevealNotes: onRevealNotes,
            onHideNotes: onHideNotes,
            notesHidden: notesHidden,
            notesFocusRequest: notesFocusRequest,
            pinnedLeftWidth: pinnedLeftWidth
        ) {
            // Смена того, что стоит в колонке, — не перерисовка, а смена
            // содержания: старое уходит, новое приходит на его место. Ключ
            // описывает *что* показано, а не какая это встреча, — иначе колонка
            // мигала бы на каждом переходе по списку.
            ZStack(alignment: .top) {
                leftColumn
                    .id(columnKey)
                    // По очереди, а не крест-накрест: два текста, проступающие
                    // друг сквозь друга, читаются хуже, чем подмена в один
                    // кадр, — ради которой всё и затевалось. Старое уходит,
                    // и только на освободившееся место приходит новое.
                    .transition(
                        .asymmetric(
                            insertion: .opacity.animation(
                                .easeOut(duration: Tokens.Pane.columnSwapIn)
                                    .delay(Tokens.Pane.columnSwapOut)
                            ),
                            removal: .opacity.animation(
                                .easeIn(duration: Tokens.Pane.columnSwapOut)
                            )
                        )
                    )
            }
            .animation(.default, value: columnKey)
        }
    }

    /// Что сейчас в левой колонке. Меняется — играет замена.
    private var columnKey: String {
        switch mode {
        case .transcript: return "transcript-\(transcriptSource.rawValue)"
        case .summary:
            switch summaryContent {
            case .summary:            return "summary"
            case .transcript:         return "summary-transcript-\(transcriptSource.rawValue)"
            case .nothing(let text):  return "summary-nothing-\(text)"
            }
        }
    }

    @ViewBuilder
    private var leftColumn: some View {
        switch mode {
        case .summary:
            switch summaryContent {
            case .summary:
                MeetingSummaryColumn(
                    summary: summary,
                    placeholder: nil,
                    controller: summaryController,
                    onChange: onSummaryChange,
                    onRewrite: onSummaryRewrite
                )
            case .transcript:
                // Саммари ещё пишется. До тех пор колонка показывает то, что
                // человек и читал минуту назад, — расшифровку.
                MeetingTranscriptColumn(turns: turns, disclosure: transcriptDisclosure)
            case .nothing(let text):
                MeetingSummaryColumn(
                    summary: .empty,
                    placeholder: text,
                    controller: summaryController,
                    onChange: onSummaryChange,
                    onRewrite: onSummaryRewrite
                )
            }
        case .transcript:
            MeetingTranscriptColumn(turns: turns, disclosure: transcriptDisclosure)
        }
    }
}

/// Две колонки пане́ли: встреча слева, заметки справа.
///
/// Одна на все состояния встречи — готовую и идущую. Заметки во время записи не
/// «похожи» на заметки готовой встречи, а буквально они же: тот же композер, тот
/// же список, те же правила схлопывания в кнопку. Разница между экранами ровно в
/// левой колонке, поэтому только она и параметризована.
struct PaneColumns<Left: View>: View {
    let notes: [MeetingNote]
    let composer: MeetingPaneBody.NoteComposer?
    let onRevealNotes: (() -> Void)?
    /// Убирает колонку по просьбе человека, а не по нехватке места. Nil там, где
    /// окна нет и сужать нечего.
    var onHideNotes: (() -> Void)? = nil
    /// Их убрали руками. Ширина этого сказать не может: на панели в 1200 pt
    /// места вдоволь, а колонка всё равно должна уйти.
    var notesHidden: Bool = false
    let notesFocusRequest: Binding<Bool>?
    /// Left width held while the window grows for a notes reveal. Nil outside
    /// that animation — ordinary split rules apply.
    var pinnedLeftWidth: Binding<CGFloat?>? = nil
    /// Отпечаток растущего содержимого левой колонки. Меняется — колонка
    /// доезжает до низа. Нужен живому транскрипту: строка, которая появляется
    /// ниже края окна, не показана. Nil у всего остального: саммари и готовый
    /// транскрипт не растут, и уезжать им некуда.
    var follow: String? = nil
    @ViewBuilder let left: () -> Left

    /// Пустышка в конце колонки — то, к чему доезжают.
    private static var bottomAnchor: String { "pane-columns-bottom" }

    var body: some View {
        // The split is decided from the pane's real width, not from a
        // breakpoint: the notes hold their column while the summary can keep its
        // 520, and collapse to a button the moment it cannot. During a reveal
        // the left width is pinned so the summary does not stretch and snap.
        GeometryReader { geo in
            let split = WindowReveal.paneSplit(
                width: geo.size.width,
                pinnedLeft: pinnedLeftWidth?.wrappedValue,
                hidden: notesHidden,
                summaryMin: Tokens.Pane.summaryMinWidth,
                notesMin: Tokens.Pane.notesMinWidth,
                notesMax: Tokens.Pane.notesMaxWidth,
                collapsedSlot: Tokens.Pane.notesCollapsedSide,
                openAt: Tokens.Pane.notesCollapseBelow
            )
            // Notes stay put while the summary scrolls: they sit beside the
            // scroll view, not inside it. Their own scroll covers a long list.
            HStack(alignment: .top, spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(spacing: 0) {
                            left()
                            Color.clear
                                .frame(height: 1)
                                .id(Self.bottomAnchor)
                        }
                        .frame(width: split.left)
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: follow) { _, _ in
                        guard follow != nil else { return }
                        withAnimation(.easeOut(duration: Tokens.Pane.followScroll)) {
                            proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                        }
                    }
                }
                .frame(width: split.left)
                if split.open {
                    ScrollView(.vertical) {
                        MeetingNotesColumn(
                            notes: notes,
                            composer: composer,
                            focusRequest: notesFocusRequest,
                            onCollapse: onHideNotes
                        )
                        .frame(width: split.notes)
                    }
                    .frame(width: split.notes)
                } else {
                    CollapsedNotesButton(count: notes.count, onReveal: onRevealNotes)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onChange(of: geo.size.width) { _, width in
                clearPinIfSettled(paneWidth: width)
            }
        }
    }

    /// Drop the pin once the ordinary split would keep the same left width —
    /// the animation has arrived, and pinning further would freeze the summary
    /// against later resizes.
    private func clearPinIfSettled(paneWidth: CGFloat) {
        guard let pinned = pinnedLeftWidth?.wrappedValue else { return }
        let natural = WindowReveal.paneSplit(
            width: paneWidth,
            pinnedLeft: nil,
            hidden: notesHidden,
            summaryMin: Tokens.Pane.summaryMinWidth,
            notesMin: Tokens.Pane.notesMinWidth,
            notesMax: Tokens.Pane.notesMaxWidth,
            collapsedSlot: Tokens.Pane.notesCollapsedSide,
            openAt: Tokens.Pane.notesCollapseBelow
        )
        guard natural.open == !notesHidden, abs(natural.left - pinned) < 1 else { return }
        pinnedLeftWidth?.wrappedValue = nil
    }
}

/// The notes, with nowhere to be — `notes-block` state `*-hidden`.
///
/// Shown rather than dropped: a column that vanishes silently at a certain
/// window width looks like the notes were lost. And pressed rather than merely
/// looked at: the button says the notes are here, so it has to be able to
/// produce them. It cannot make room itself — `onReveal` widens the window, and
/// the composer takes the caret on the other side, so one click ends with a
/// cursor in an empty note.
struct CollapsedNotesButton: View {
    let count: Int
    /// Absent in the gallery, where there is no window to grow. The button then
    /// stays what it was: a marker that the notes are somewhere.
    var onReveal: (() -> Void)?

    @State private var hovering = false

    var body: some View {
        Button { onReveal?() } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: Tokens.Pane.headerIconSize, weight: .regular))
                .foregroundStyle(hovering ? Tokens.Paint.Text.primary : Tokens.Pane.buttonIcon)
                .frame(width: Tokens.Pane.headerButtonSide, height: Tokens.Pane.headerButtonSide)
                .background(
                    hovering ? Tokens.Sidebar.rowHover : .clear,
                    in: RoundedRectangle(
                        cornerRadius: Tokens.Pane.headerButtonRadius, style: .continuous
                    )
                )
        }
        .buttonStyle(.plain)
        .disabled(onReveal == nil)
        // Прижата к правому краю тем же отступом, что и кластер шапки, а не
        // отцентрована в своём слоте: по центру она стояла на 26 pt от края
        // окна против 24 pt у «поделиться» прямо над ней, и две иконки в одном
        // столбце расходились на два пункта — ровно столько, чтобы это было
        // видно и нечем было объяснить.
        .padding(.trailing, Tokens.Pane.headerActionsPadding)
        .frame(
            width: Tokens.Pane.notesCollapsedSide,
            height: Tokens.Pane.notesCollapsedSide,
            alignment: .trailing
        )
        .onHover { hovering = $0 && onReveal != nil }
        .animation(.easeOut(duration: Tokens.Motion.hover), value: hovering)
        .help(hint)
        .accessibilityLabel("Заметки")
    }

    /// Says what the click does, because widening the window is a big enough
    /// consequence to warn about and too useful to hide behind a resize.
    private var hint: String {
        guard onReveal != nil else {
            return count == 0 ? "Заметок нет" : "Заметок: \(count) — окно слишком узкое"
        }
        return count == 0
            ? "Написать заметку — окно станет шире"
            : "Заметок: \(count) — окно станет шире"
    }
}

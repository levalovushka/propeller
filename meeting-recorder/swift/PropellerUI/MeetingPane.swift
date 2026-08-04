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

/// The meeting's name, when it happened, who was in it, and the three actions.
///
/// Deliberately quiet — 11 pt, the same as the rail's chrome. This row sits in
/// the window's titlebar, and a titlebar that shouts competes with the summary
/// two centimetres below it, which is the thing actually worth reading.
public struct MeetingPaneHeader<MoreMenu: View>: View {
    private let title: String
    private let time: String
    private let participants: String?
    private let onParticipants: (() -> Void)?
    private let onCopy: (() -> Void)?
    private let share: Share?
    /// The ellipsis is a *menu*, not a button — «ещё» has no single action, and
    /// a closure would only be able to open one somewhere else.
    private let moreMenu: () -> MoreMenu
    private let hasMoreMenu: Bool

    /// The one filled button in the header.
    public struct Share {
        public let title: String
        public let handler: () -> Void
        public init(_ title: String, handler: @escaping () -> Void) {
            self.title = title
            self.handler = handler
        }
    }

    public init(
        title: String,
        time: String,
        participants: String? = nil,
        onParticipants: (() -> Void)? = nil,
        onCopy: (() -> Void)? = nil,
        share: Share? = nil,
        hasMoreMenu: Bool = true,
        @ViewBuilder moreMenu: @escaping () -> MoreMenu
    ) {
        self.title = title
        self.time = time
        self.participants = participants
        self.onParticipants = onParticipants
        self.onCopy = onCopy
        self.share = share
        self.moreMenu = moreMenu
        self.hasMoreMenu = hasMoreMenu
    }

    public var body: some View {
        HStack(spacing: 0) {
            identity
            Spacer(minLength: Tokens.Space.s8)
            actions
        }
        .frame(height: Tokens.Pane.headerHeight)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .typoBlock(Tokens.Pane.Typo.headerTitle)
                .foregroundStyle(Tokens.Pane.title)
                .lineLimit(1)
            HStack(spacing: Tokens.Pane.headerMetaGap) {
                Text(time)
                    .typoBlock(Tokens.Pane.Typo.headerTitle)
                    .foregroundStyle(Tokens.Pane.meta)
                    .lineLimit(1)
                if let participants {
                    participantsButton(participants)
                }
            }
        }
        .padding(.horizontal, Tokens.Pane.headerHPadding)
        .padding(.vertical, Tokens.Pane.headerVPadding)
        // A cap, not a width. The comps give this block 430 at 800 pt of pane
        // and 250 at 601 — it takes what is left after the actions, which keep
        // their intrinsic size. Fixed at 430, «Поделиться» is the thing that
        // gets truncated instead.
        .frame(maxWidth: Tokens.Pane.headerTitleWidth, alignment: .leading)
    }

    @ViewBuilder
    private func participantsButton(_ text: String) -> some View {
        let label = HStack(spacing: Tokens.Pane.headerChevronGap) {
            Text(text)
                .typoBlock(Tokens.Pane.Typo.headerTitle)
                .lineLimit(1)
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .regular))
        }
        .foregroundStyle(Tokens.Pane.meta)

        if let onParticipants {
            Button(action: onParticipants) { label }
                .buttonStyle(.plain)
        } else {
            label
        }
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
            if let onCopy {
                PaneIconButton(symbol: "document.on.clipboard", help: "Скопировать", action: onCopy)
            }
            if let share {
                PaneShareButton(title: share.title, action: share.handler)
            }
        }
        .padding(.horizontal, Tokens.Pane.headerActionsPadding)
        .frame(height: Tokens.Pane.headerHeight)
        .fixedSize()
    }
}

extension MeetingPaneHeader where MoreMenu == EmptyView {
    /// A header with no «ещё» menu — the gallery, and any pane whose meeting
    /// has nothing more to offer.
    public init(
        title: String,
        time: String,
        participants: String? = nil,
        onParticipants: (() -> Void)? = nil,
        onCopy: (() -> Void)? = nil,
        share: Share? = nil
    ) {
        self.init(
            title: title, time: time, participants: participants,
            onParticipants: onParticipants, onCopy: onCopy, share: share,
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

/// Same shape as the rail's row action, because it is the same idea: the one
/// filled thing in a row of quiet ones.
struct PaneShareButton: View {
    let title: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .typo(Tokens.Pane.Typo.shareLabel)
                .foregroundStyle(Tokens.Pane.shareLabel)
                .lineLimit(1)
                .padding(.horizontal, Tokens.Space.s2)
                .padding(.horizontal, Tokens.Pane.shareHPadding)
                .frame(height: Tokens.Pane.headerButtonSide)
                .background(
                    hovering ? Tokens.Pane.shareHoverFill : Tokens.Pane.shareFill,
                    in: RoundedRectangle(cornerRadius: Tokens.Pane.shareRadius, style: .continuous)
                )
                .contentShape(
                    RoundedRectangle(cornerRadius: Tokens.Pane.shareRadius, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.Motion.hover), value: hovering)
    }
}

// MARK: - Summary column

/// The summary the pane draws — parsed from the recap by
/// `RecapPresentation`, which is where the markdown's surprises are handled.
public typealias MeetingSummary = RecapPresentation.Summary

public struct MeetingSummaryColumn: View {
    private let summary: MeetingSummary
    /// Shown instead of the summary when there is not one yet — a meeting is
    /// readable long before the model has finished with it.
    private let placeholder: String?

    public init(summary: MeetingSummary, placeholder: String? = nil) {
        self.summary = summary
        self.placeholder = placeholder
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Pane.summaryBlockGap) {
            if let placeholder, summary.isEmpty {
                Text(placeholder)
                    .typoBlock(Tokens.Pane.Typo.body)
                    .foregroundStyle(Tokens.Pane.placeholder)
            }
            VStack(alignment: .leading, spacing: Tokens.Pane.summaryLineGap) {
                if !summary.lead.isEmpty {
                    Text(summary.lead)
                        .typoBlock(Tokens.Pane.Typo.lead)
                        .tracking(Tokens.Pane.Typo.leadTracking)
                }
                if !summary.body.isEmpty {
                    Text(summary.body)
                        .typoBlock(Tokens.Pane.Typo.body)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(summary.sections) { section in
                VStack(alignment: .leading, spacing: Tokens.Pane.summaryLineGap) {
                    Text(section.title)
                        .typoBlock(Tokens.Pane.Typo.sectionTitle)
                        .tracking(Tokens.Pane.Typo.sectionTracking)
                    VStack(alignment: .leading, spacing: Tokens.Pane.bulletGap) {
                        ForEach(section.blocks) { block in
                            switch block {
                            case .bullet(_, let lead, let text):
                                BulletRow(lead: lead, text: text)
                            case .paragraph(_, let text):
                                Text(text)
                                    .typoBlock(Tokens.Pane.Typo.body)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .foregroundStyle(Tokens.Pane.body)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, Tokens.Pane.summaryHPadding)
        .padding(.vertical, Tokens.Pane.summaryVPadding)
        // The measure is capped for readability and then *centred* in whatever
        // room the column has. Pinned left, a wide window leaves the text
        // against one edge with a field of empty beside it.
        .frame(maxWidth: Tokens.Pane.summaryMaxWidth + Tokens.Pane.summaryHPadding * 2)
        .frame(maxWidth: .infinity)
    }
}

/// A disc, then a paragraph that hangs off it.
///
/// The indent is on the *paragraph*, not on the first line, so wrapped lines
/// align under the text rather than under the bullet — which is the difference
/// between a list and a stack of sentences with dots.
private struct BulletRow: View {
    let lead: String?
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("•")
                .typoBlock(Tokens.Pane.Typo.body)
                .frame(width: Tokens.Pane.bulletIndent, alignment: .leading)
            Text(attributed)
                .typoBlock(Tokens.Pane.Typo.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Bold lead-in and the rest as one paragraph — two `Text`s would break the
    /// line after the colon whatever the width.
    private var attributed: AttributedString {
        guard let lead, !lead.isEmpty else {
            return AttributedString(text)
        }
        var head = AttributedString(lead)
        head.font = Tokens.Pane.Typo.sectionTitle.font
        var tail = AttributedString(text)
        tail.font = Tokens.Pane.Typo.body.font
        head.append(tail)
        return head
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
public struct MeetingNotesColumn: View {
    private let notes: [MeetingNote]
    private let composer: MeetingPaneBody.NoteComposer?

    public init(notes: [MeetingNote], composer: MeetingPaneBody.NoteComposer? = nil) {
        self.notes = notes
        self.composer = composer
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let composer {
                NoteComposerRow(composer: composer)
            }
            ForEach(notes) { note in
                NoteRow(text: note.text, style: Tokens.Pane.Typo.note, colour: Tokens.Pane.body)
            }
        }
        .padding(.horizontal, Tokens.Pane.notesHPadding)
        .padding(.vertical, Tokens.Pane.notesVPadding)
        .frame(minWidth: Tokens.Pane.notesMinWidth, alignment: .leading)
    }
}

/// The row you type into. Sits above the notes, like the comps' `empty-writing`.
private struct NoteComposerRow: View {
    let composer: MeetingPaneBody.NoteComposer

    var body: some View {
        TextField(composer.placeholder, text: composer.text, axis: .vertical)
            .textFieldStyle(.plain)
            .typoBlock(Tokens.Pane.Typo.note)
            .foregroundStyle(Tokens.Pane.body)
            .lineLimit(1...6)
            .onSubmit(composer.onCommit)
            .padding(.horizontal, Tokens.Pane.noteHPadding)
            .padding(.vertical, Tokens.Pane.noteVPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Tokens.Pane.noteHPadding)
            .padding(.vertical, Tokens.Pane.noteVPadding)
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
    private let summaryPlaceholder: String
    private let transcriptDisclosure: String?

    /// The «Добавьте заметку...» row, when notes can be written.
    public struct NoteComposer {
        public let placeholder: String
        public let text: Binding<String>
        public let onCommit: () -> Void

        public init(placeholder: String = "Добавьте заметку...",
                    text: Binding<String>,
                    onCommit: @escaping () -> Void) {
            self.placeholder = placeholder
            self.text = text
            self.onCommit = onCommit
        }
    }

    public init(
        mode: MeetingPaneMode = .summary,
        summary: MeetingSummary,
        turns: [MeetingTranscriptColumn.Turn] = [],
        notes: [MeetingNote],
        composer: NoteComposer? = nil,
        summaryPlaceholder: String = "Саммари пока нет",
        transcriptDisclosure: String? = nil
    ) {
        self.mode = mode
        self.summary = summary
        self.turns = turns
        self.notes = notes
        self.composer = composer
        self.summaryPlaceholder = summaryPlaceholder
        self.transcriptDisclosure = transcriptDisclosure
    }

    public var body: some View {
        // The split is decided from the pane's real width, not from a
        // breakpoint: the notes hold their column while the summary can keep its
        // 520, and collapse to a button the moment it cannot.
        GeometryReader { geo in
            let roomForNotes = geo.size.width >= Tokens.Pane.notesCollapseBelow
            // The notes take the leftover, but only between their floor and
            // their ceiling. Everything past the ceiling belongs to the summary,
            // which centres its measure in it.
            let notesWidth = min(
                Tokens.Pane.notesMaxWidth,
                max(Tokens.Pane.notesMinWidth, geo.size.width - Tokens.Pane.summaryMinWidth)
            )
            let collapsedWidth = max(0, geo.size.width - Tokens.Pane.notesCollapsedSide)
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    leftColumn
                        .frame(width: roomForNotes ? geo.size.width - notesWidth : collapsedWidth)
                    if roomForNotes {
                        MeetingNotesColumn(notes: notes, composer: composer)
                            .frame(width: notesWidth)
                    } else {
                        CollapsedNotesButton(count: notes.count)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    @ViewBuilder
    private var leftColumn: some View {
        switch mode {
        case .summary:
            MeetingSummaryColumn(
                summary: summary,
                placeholder: summary.isEmpty ? summaryPlaceholder : nil
            )
        case .transcript:
            MeetingTranscriptColumn(turns: turns, disclosure: transcriptDisclosure)
        }
    }
}

/// The notes, with nowhere to be — `notes-block` state `*-hidden`.
///
/// Shown rather than dropped: a column that vanishes silently at a certain
/// window width looks like the notes were lost.
struct CollapsedNotesButton: View {
    let count: Int

    @State private var hovering = false

    var body: some View {
        Image(systemName: "bubble.left.fill")
            .font(.system(size: Tokens.Pane.headerIconSize, weight: .regular))
            .foregroundStyle(hovering ? Tokens.Paint.Text.primary : Tokens.Pane.buttonIcon)
            .frame(width: Tokens.Pane.headerButtonSide, height: Tokens.Pane.headerButtonSide)
            .background(
                hovering ? Tokens.Sidebar.rowHover : .clear,
                in: RoundedRectangle(cornerRadius: Tokens.Pane.noteRadius, style: .continuous)
            )
            .frame(width: Tokens.Pane.notesCollapsedSide, height: Tokens.Pane.notesCollapsedSide)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: Tokens.Motion.hover), value: hovering)
            .help(count == 0 ? "Заметок нет" : "Заметок: \(count) — окно слишком узкое")
            .accessibilityLabel("Заметки")
    }
}

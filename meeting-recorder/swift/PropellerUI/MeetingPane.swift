import SwiftUI
import AppKit
import PropellerPure

/// # The content pane — Figma 31:4624
///
/// What the rail points at: a 48 pt header carrying the meeting's identity and
/// the three things you can do to it, then one column — what the meeting *was*.
///
/// One, not two. Notes had a column of their own here, and it cost a third of
/// the window to hold a list nobody added to after the meeting ended. A note
/// written during it now stands in the transcript on its own second; a note
/// after it is part of the summary. Pure presentation, like the rail: it takes
/// text and hands back callbacks, which is what lets the gallery draw it with no
/// meeting on disk.

// MARK: - Header

/// Constants of the header's name field. Outside the view because a generic
/// type cannot hold stored statics.
private enum HeaderTitle {
    /// Room for the caret past the last glyph, so it is not clipped at the edge.
    static let caretRoom: CGFloat = 4
    static let untitled = "Без названия"
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
    /// Во что одето имя. Машина коммита у обоих одна — а она и есть всё
    /// сложное здесь, — расходится только вёрстка: полоса над идущей записью
    /// и тело панели готовой встречи.
    var look: Look = .paneHeader

    struct Look {
        let typo: Tokens.Typography.Style
        let maxWidth: CGFloat
        let hPadding: CGFloat
        let vPadding: CGFloat
        /// Высота бокса, если она названа макетом, а не выведена из шрифта.
        /// `renderedLineHeight` считает по потолкам асцендера и десцендера
        /// отдельно и на 22 pt промахивается: макет даёт 24, SF рисует 26, и
        /// всё, что ниже имени, уезжает на эти два. То же решение, что у
        /// заголовка страницы настроек (`SettingsKit`).
        var boxHeight: CGFloat?

        /// Полоса 48 над идущей записью — 14/18 в поле 430.
        static let paneHeader = Look(
            typo: Tokens.Pane.Typo.headerTitle,
            maxWidth: Tokens.Pane.headerTitleWidth,
            hPadding: Tokens.Pane.headerHPadding,
            vPadding: Tokens.Pane.headerVPadding,
            boxHeight: nil
        )
        /// Имя в теле готовой встречи — 22/24 без полей: их уже дала колонка.
        static let body = Look(
            typo: Tokens.Pane.Typo.paneTitle,
            maxWidth: .infinity,
            hPadding: 0,
            vPadding: 0,
            boxHeight: Tokens.Pane.Typo.paneTitle.lineHeight
        )
    }

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
        .padding(.horizontal, look.hPadding)
        .padding(.vertical, look.vPadding)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // A cap, not a width — and minWidth 0 so the pane can go narrow without
        // the title claiming more room than the actions leave it.
        .frame(minWidth: 0, maxWidth: look.maxWidth, alignment: .leading)
        .frame(height: look.boxHeight, alignment: .leading)
        .animation(.easeOut(duration: Tokens.Motion.hover), value: hovering)
        .animation(.easeOut(duration: Tokens.Motion.hover), value: focused)
    }

    private var titleField: some View {
        TextField(HeaderTitle.untitled, text: text)
            .textFieldStyle(.plain)
            .typoBlock(look.typo)
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
            withAttributes: [.font: look.typo.nsFont]
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

/// Копирование саммари: знак, который на секунду становится галочкой.
///
/// Подтверждение живёт **на самой кнопке**, а не всплывает плашкой: в этом
/// приложении нет тостов (`principles.md` §2), и состояние принадлежит
/// предмету, который его нажал. Человек и так смотрит на кнопку в момент
/// нажатия — там же ему и отвечают.
///
/// Ловушка, уже разобранная в чёлке (`NotchSurface.glyph`): замена знака идёт
/// заменой всего дерева, а такая замена — не транзакция, и `.transition` при
/// ней просто не включается, знак моргает. Поэтому смена делается своей
/// `withAnimation`, и только тогда `blurReplace` отрабатывает.
struct CopyButton: View {
    let action: () -> Void

    @State private var done = false
    @State private var hovering = false
    /// Отсчёт выдержки. Хранится, чтобы второе нажатие продлевало галочку с
    /// нуля, а не гасило её по расписанию первого.
    @State private var countdown: Task<Void, Never>?

    private var symbol: String {
        done ? Tokens.Pane.copyDoneGlyph : Tokens.Pane.copyGlyph
    }

    var body: some View {
        Button {
            action()
            countdown?.cancel()
            withAnimation(.easeOut(duration: Tokens.Pane.copySwap)) { done = true }
            countdown = Task {
                try? await Task.sleep(for: .seconds(Tokens.Pane.copyConfirmationDwell))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: Tokens.Pane.copySwap)) { done = false }
            }
        } label: {
            ZStack {
                Image(systemName: symbol)
                    .font(.system(size: Tokens.Pane.headerIconSize, weight: .regular))
                    .transition(.blurReplace)
                    .id(symbol)
            }
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
        .help("Скопировать саммари")
        .onDisappear { countdown?.cancel() }
    }
}

/// Дата, число участников, слот проекта — 312:11129.
///
/// Чип, а не строка через точку: каждый факт — свой предмет. Нажимаем из них
/// пока только проект, и ховер есть **ровно** у него: подсветить дату значило
/// бы обещать действие, которого нет.
struct MeetingMetaRow: View {
    let meta: MeetingPane.Meta

    /// Курсор над строкой целиком — им живёт сжатый «плюс».
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Tokens.Pane.Meta.gap) {
            if let date = meta.date {
                MetaChip(symbol: "calendar", text: MeetingMeta.when(date))
            }
            if let people = meta.people,
               let label = MeetingMeta.people(MeetingMeta.count(people.rows)) {
                // Меню, как у проекта рядом: решение владельца 2026-08-27 —
                // список команд остаётся системным везде. Число — длина `rows`,
                // второго счётчика нет.
                MetaMenuChip(symbol: "person.2.fill", text: label, live: true) {
                    ParticipantsMenu(model: people)
                }
            }
            if let projects = meta.projects {
                ForEach(projects.tagged, id: \.id) { project in
                    MetaTagChip(name: project.name) { projects.untag(project.id) }
                }
                // Кандидат стоит в строке сам, а не пунктом меню (297:23241,
                // `plan-projects.md` §3): щелчок по имени заводит проект,
                // щелчок по крестику глушит связку навсегда.
                if let suggestion = projects.suggestion {
                    MetaSuggestionChip(
                        name: suggestion.name,
                        accept: suggestion.accept,
                        dismiss: suggestion.dismiss
                    )
                }
                // Слово «Проект» — только когда о проекте не сказано ничего
                // (312:11142, правило в `MeetingMeta.projectSlotCollapsed`).
                // Иначе один «плюс», и он появляется под курсором: место за
                // ним держится всегда, чтобы строка не дёргалась.
                let collapsed = MeetingMeta.projectSlotCollapsed(
                    tagged: projects.tagged.count, hasSuggestion: projects.suggestion != nil
                )
                MetaMenuChip(
                    symbol: "plus", text: collapsed ? nil : "Проект", quiet: true, live: true
                ) {
                    ForEach(projects.available, id: \.id) { project in
                        Button(project.name) { projects.tag(project.id) }
                    }
                    if !projects.available.isEmpty { Divider() }
                    Button("Новый проект…") { projects.create() }
                }
                .opacity(collapsed && !hovering ? 0 : 1)
                .accessibilityLabel("Добавить проект")
            }
        }
        .frame(height: Tokens.Pane.Meta.height)
        // Курсор ловит вся строка, а не буквы в ней. Без своей формы `HStack`
        // отдаёт наведение детям: зазоры между чипами и — главное — место
        // невидимого «плюса» курсора не замечали вовсе, и он гас ровно тогда,
        // когда мышь шла к нему от помеченного проекта.
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.Motion.hover), value: hovering)
    }
}

/// Помеченный проект: факт и один жест — снять.
///
/// Меню здесь было, и его нет: чтобы снять метку, приходилось щёлкнуть по
/// самому проекту и выбрать пункт, то есть открыть разговор ради одного ответа.
/// Крестик приходит под курсором, **не меняя ширины чипа** — он ложится на
/// имя, растворяя его конец под собой. Ширина, которая прыгает под курсором,
/// сдвигала бы всё, что стоит правее, ровно в тот момент, когда туда целятся.
private struct MetaTagChip: View {
    let name: String
    let remove: () -> Void

    @State private var hovering = false

    var body: some View {
        MetaChip(
            symbol: "folder.fill", text: name, live: true,
            fadingTail: hovering,
            // Ховер считает этот вид, а не сам чип: крестик его накрывает.
            hovered: hovering
        )
            .overlay(alignment: .trailing) {
                if hovering {
                    MetaCross(help: "Снять метку", action: remove)
                }
            }
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: Tokens.Motion.hover), value: hovering)
    }
}

/// Кандидат в проекты — 297:23241.
///
/// Пунктир и есть всё сообщение: это не метка, это вопрос. Щелчок по имени
/// заводит проект и подтягивает прошлые похожие встречи, щелчок по крестику
/// глушит связку навсегда (`plan-projects.md` §3, правило 3). Третий ответ —
/// молчание, и он ничего не стоит: чип висит и не мигает.
private struct MetaSuggestionChip: View {
    let name: String
    let accept: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: Tokens.Pane.Meta.Suggested.gap) {
            Button(action: accept) {
                Text(name)
                    .typo(Tokens.Pane.Typo.metaWide)
                    .foregroundStyle(Tokens.Pane.Meta.label)
                    .padding(.horizontal, Tokens.Pane.Meta.Suggested.namePadding)
                    .frame(height: Tokens.Pane.Meta.height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.press)
            .help("Завести проект «\(name)»")
            MetaCross(help: "Не предлагать", action: dismiss)
        }
        .padding(.horizontal, Tokens.Pane.Meta.Suggested.hPadding)
        .frame(height: Tokens.Pane.Meta.height)
        .overlay(
            RoundedRectangle(
                cornerRadius: Tokens.Pane.Meta.Suggested.radius, style: .continuous
            )
            .strokeBorder(
                Tokens.Pane.Meta.Suggested.border,
                style: StrokeStyle(lineWidth: 1, dash: Tokens.Pane.Meta.Suggested.dash)
            )
        )
    }
}

/// Крестик чипа: «снять метку» и «не предлагать» — один и тот же жест.
private struct MetaCross: View {
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: Tokens.Pane.Meta.crossSize, weight: .regular))
                .foregroundStyle(hovering ? Tokens.Pane.Meta.label : Tokens.Pane.Meta.quiet)
                .frame(width: Tokens.Pane.Meta.crossSide, height: Tokens.Pane.Meta.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.press)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.Motion.hover), value: hovering)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Чип, по которому есть что нажать. Форма — `MetaChip`, поведение — меню:
/// «щёлкнуть по факту» из 312:11129 наконец что-то значит.
private struct MetaMenuChip<Content: View>: View {
    let symbol: String
    let text: String?
    /// Надпись тем же тихим цветом, что и значок: так выглядит слот, в котором
    /// ещё ничего нет.
    var quiet: Bool = false
    /// Ховер. Передаётся, а не выводится из того, что чип в меню: у меню
    /// заведомо есть что открыть, но признак остаётся у вызова — иначе первый
    /// же неактивный чип в меню засветится молча.
    var live: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        Menu {
            content()
        } label: {
            MetaChip(symbol: symbol, text: text, quiet: quiet, live: live)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

private struct MetaChip: View {
    let symbol: String
    /// `nil` — чип из одного значка.
    let text: String?
    /// Надпись тихая, как значок: пустой слот (312:11142) против факта.
    var quiet: Bool = false
    /// Есть ли что нажать. По умолчанию нет — и тогда чип не светится под
    /// курсором вовсе: ховер здесь единственное обещание действия.
    var live: Bool = false
    /// Растворить конец имени: под ним встанет крестик, а ширина чипа останется
    /// прежней.
    var fadingTail: Bool = false
    /// Ховер, посчитанный снаружи. Нужен там, где чип **накрыт** своим же
    /// крестиком: крестик лежит в оверлее — то есть слоем выше, а не внутри, —
    /// и забирает наведение себе. Свой `onHover` тогда честно отвечает «мышь не
    /// на мне», плита гаснет, и чип теряет подсветку ровно в тот момент, когда
    /// человек целится в его крестик. Владелец поймал это на помеченном
    /// проекте, 2026-08-27.
    var hovered: Bool?

    @State private var hovering = false
    private var isHovered: Bool { hovered ?? hovering }

    var body: some View {
        HStack(spacing: Tokens.Pane.Meta.iconGap) {
            Image(systemName: symbol)
                .font(.system(size: Tokens.Pane.Meta.iconSize, weight: .regular))
                .foregroundStyle(Tokens.Pane.Meta.quiet)
            if let text {
                Text(text)
                    .typo(Tokens.Pane.Typo.metaWide)
                    .foregroundStyle(quiet ? Tokens.Pane.Meta.quiet : Tokens.Pane.Meta.label)
            }
        }
        // Маска, а не заливка под крестиком: чип стоит на фоне страницы, и
        // плашка под значком выдала бы прямоугольник там, где макет растворяет
        // текст. Растушёвка в точках, а не в долях, — длина имени на неё не влияет.
        .mask(
            HStack(spacing: 0) {
                Rectangle()
                LinearGradient(
                    colors: [.black, fadingTail ? .clear : .black],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(width: Tokens.Pane.Meta.fadeRamp)
                Rectangle()
                    .fill(fadingTail ? Color.clear : Color.black)
                    .frame(width: Tokens.Pane.Meta.fadeClear)
            }
        )
        .frame(height: Tokens.Pane.Meta.height)
        // Поле не у содержимого, а у плиты: иконка даты обязана встать ровно
        // под именем встречи, иначе левый край головы рвётся. Плита при этом
        // вылезает за колонку на свои 6 — так же, как ховер строки в рельсе,
        // и так же нарисована в макете (312:11138 залит с полем, 312:11134
        // без поля стоит на самой кромке).
        .background(
            (live && isHovered ? Tokens.Pane.Meta.hoverFill : .clear)
                .clipShape(
                    RoundedRectangle(cornerRadius: Tokens.Pane.Meta.radius, style: .continuous)
                )
                .padding(.horizontal, -Tokens.Pane.Meta.hPadding)
        )
        // У мёртвого чипа нет и состояния ховера: подсвечивать нечем, и
        // считать нечего.
        .onHover { if live { hovering = $0 } }
        .animation(.easeOut(duration: Tokens.Motion.hover), value: isHovered)
    }
}

/// «Поделиться» — сплошная белая пилюля, 312:11129.
///
/// Единственная заливка на всей панели, и это сказано осознанно: остальные
/// действия встречи человек находит, когда ищет, а этим он пользуется, когда
/// разговор кончился и его надо кому-то отдать.
struct SharePill: View {
    let title: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .typo(Tokens.Pane.Typo.metaWide)
                .foregroundStyle(Tokens.Paint.Text.primaryInverse)
                .padding(.horizontal, Tokens.Pane.sharePillHPadding)
                .frame(height: Tokens.Pane.headerButtonSide)
                .background(
                    hovering
                        ? Tokens.Paint.Interactive.Primary.hover
                        : Tokens.Paint.Interactive.Primary.rest,
                    in: Capsule(style: .continuous)
                )
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.Motion.hover), value: hovering)
        .help(title)
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
        .buttonStyle(.press)
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
        VStack(alignment: .leading, spacing: Tokens.Pane.summarySectionGap) {
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
        .padding(.top, Tokens.Pane.titleGap)
        .padding(.bottom, Tokens.Pane.summaryBottomPadding)
        // The measure is capped for readability and then *centred* in whatever
        // room the column has. Pinned left, a wide window leaves the text
        // against one edge with a field of empty beside it.
        .frame(maxWidth: Tokens.Pane.paneMeasure)
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
                removal: .opacity.animation(.easeOut(duration: Tokens.Pane.Bar.fadeOut))
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
        /// Начало реплики. Нужно, чтобы заметку можно было поставить между
        /// репликами: у времени реплики есть число, а у метки `12:34` — нет.
        public let startSeconds: Double

        public init(
            id: String,
            speaker: String,
            time: String,
            text: String,
            startSeconds: Double = 0
        ) {
            self.id = id
            self.speaker = speaker
            self.time = time
            self.text = text
            self.startSeconds = startSeconds
        }
    }

    private let turns: [Turn]
    private let notes: [TranscriptNote]
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
        notes: [TranscriptNote] = [],
        emptyMessage: String = "Расшифровки пока нет",
        disclosure: String? = nil
    ) {
        self.turns = turns
        self.notes = notes
        self.emptyMessage = emptyMessage
        self.disclosure = disclosure
    }

    /// Реплики и заметки одной лентой. Правило — `NotePlacement`, одно на эту
    /// колонку и на живую: одна и та же встреча до стопа и после него обязана
    /// быть собрана одинаково.
    private var feed: [NotePlacement.Item] {
        NotePlacement.interleave(
            turnStarts: turns.map(\.startSeconds),
            noteOffsets: notes.map(\.seconds)
        )
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Pane.transcriptTurnGap) {
            // Пусто — это когда нет ни реплик, ни заметок. Встреча, у которой
            // расшифровки не вышло, но которую человек конспектировал руками,
            // не пустая, и говорить ей «расшифровки пока нет» поверх её же
            // заметок значило бы отбирать готовое ради сообщения об отсутствии.
            if turns.isEmpty, notes.isEmpty {
                Text(emptyMessage)
                    .typoBlock(Tokens.Pane.Typo.body)
                    .foregroundStyle(Tokens.Pane.placeholder)
            }
            if let disclosure, !turns.isEmpty {
                Text(disclosure)
                    .typoBlock(Tokens.Pane.Typo.transcriptMeta)
                    .foregroundStyle(Tokens.Pane.meta)
            }
            ForEach(feed, id: \.self) { item in
                switch item {
                case .turn(let index): remark(turns[index])
                case .note(let index): TranscriptNoteRow(note: notes[index])
                }
            }
        }
        .multilineTextAlignment(.leading)
        .padding(.horizontal, Tokens.Pane.summaryHPadding)
        // Сверху — тот же шаг, что у саммари: имя встречи стоит над обеими
        // колонками, и при переключении оно не должно прыгать на восемь точек.
        .padding(.top, Tokens.Pane.titleGap)
        .padding(.bottom, Tokens.Pane.summaryVPadding)
        .frame(maxWidth: Tokens.Pane.paneMeasure)
        .frame(maxWidth: .infinity)
    }

    private func remark(_ turn: Turn) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Pane.transcriptLineGap) {
            HStack(spacing: Tokens.Pane.transcriptMetaGap) {
                Text(turn.speaker)
                    .typoBlock(Tokens.Pane.Typo.transcriptMeta)
                    .lineLimit(1)
                Text(turn.time)
                    .typoBlock(Tokens.Pane.Typo.transcriptMeta, monospacedDigit: true)
                    .lineLimit(1)
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

extension MeetingPaneBody where MoreMenu == EmptyView {
    /// Панель без меню «ещё» — доска галереи и всё, что показывает саммари
    /// само по себе.
    public init(
        identity: MeetingPane.Identity? = nil,
        meta: MeetingPane.Meta? = nil,
        share: MeetingPane.Share? = nil,
        copy: MeetingPane.Copy? = nil,
        mode: MeetingPaneMode = .summary,
        summary: MeetingSummary,
        turns: [MeetingTranscriptColumn.Turn] = [],
        transcriptNotes: [TranscriptNote] = [],
        summaryContent: SummaryColumnContent = .summary,
        transcriptSource: TranscriptSource = .stored,
        transcriptDisclosure: String? = nil,
        summaryController: SummaryEditorController = SummaryEditorController(),
        onSummaryChange: ((MeetingSummary) -> Void)? = nil,
        onSummaryRewrite: ((SummaryRewrite, String) -> Void)? = nil
    ) {
        self.init(
            identity: identity,
            meta: meta,
            share: share,
            copy: copy,
            hasMoreMenu: false,
            mode: mode,
            summary: summary,
            turns: turns,
            transcriptNotes: transcriptNotes,
            summaryContent: summaryContent,
            transcriptSource: transcriptSource,
            transcriptDisclosure: transcriptDisclosure,
            summaryController: summaryController,
            onSummaryChange: onSummaryChange,
            onSummaryRewrite: onSummaryRewrite,
            moreMenu: { EmptyView() }
        )
    }
}

/// Замер панели для тестов геометрии.
///
/// Прибор в продуктовом коде, как `MeetingsChromeMidYKey`: у SwiftUI-вью нет
/// своего `NSView`, и снаружи их не померить, а сканировать растр по яркости на
/// антиалиасинге текста — гадание. Ничего не рисует.
public enum PaneProbe {
    public static let space = "pane"
    public static let meta = "meta"
    public static let title = "title"
    public static let actions = "actions"
    public static let copy = "copy"
    public static let share = "share"
}

public struct PaneProbeKey: PreferenceKey {
    public static var defaultValue: [String: CGRect] { [:] }
    public static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    func paneProbe(_ name: String) -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: PaneProbeKey.self,
                    value: [name: geo.frame(in: .named(PaneProbe.space))]
                )
            }
        )
    }
}

/// Что панель встречи показывает о встрече помимо её текста.
///
/// Отдельным пространством имён, а не вложенными типами: `MeetingPaneBody`
/// параметризована меню «ещё», и вложенный тип у неё был бы разным для панели
/// с меню и без — то есть вызывающему пришлось бы знать generic, чтобы назвать
/// дату встречи.
public enum MeetingPane {

/// Встреча, чьё имя стоит над саммари.
///
/// По id, а не по всей записи: переименование, приехавшее при переключении
/// встреч посреди правки, принадлежит той встрече, в которую его печатали,
/// а она к тому моменту уже не выбрана.
public struct Identity {
    public let meetingID: String
    public let title: String
    public let onRename: ((_ meetingID: String, _ newTitle: String) -> Void)?
    public init(
        meetingID: String,
        title: String,
        onRename: ((_ meetingID: String, _ newTitle: String) -> Void)? = nil
    ) {
        self.meetingID = meetingID
        self.title = title
        self.onRename = onRename
    }
}

/// Факты о встрече над её именем — 312:11129.
public struct Meta {
    public let date: Date?
    /// Кто был и что с этим можно сделать. `nil` — чипа нет вовсе.
    public let people: People?
    /// К каким проектам встреча относится и что с этим можно сделать.
    public let projects: Projects?
    public init(date: Date?, people: People? = nil, projects: Projects? = nil) {
        self.date = date
        self.people = people
        self.projects = projects
    }

    /// Состав встречи: ряды и то, что с ними делают — 285:19438.
    ///
    /// Число в чипе здесь не передаётся: оно **длина** `rows`, и вторым полем
    /// разошлось бы со списком под ним в первый же день (`MeetingMeta.count`).
    public struct People {
        /// Ряды, собранные `MeetingRoster.rows`. Порядок их — оттуда же.
        public let rows: [MeetingRoster.Row]
        /// Кого предложить в «Добавить»: приглашённые этой встречи плюс те, с
        /// кем созванивались раньше (`MeetingRoster.candidates`).
        public let candidates: [String]
        /// Убрать ряд. Владельца не вызывают — у него `isRemovable == false`.
        public let remove: (MeetingRoster.Row) -> Void
        /// Добавить участника — выбранного из предложений или названного руками.
        public let add: (String) -> Void

        public init(
            rows: [MeetingRoster.Row],
            candidates: [String] = [],
            remove: @escaping (MeetingRoster.Row) -> Void = { _ in },
            add: @escaping (String) -> Void = { _ in }
        ) {
            self.rows = rows
            self.candidates = candidates
            self.remove = remove
            self.add = add
        }
    }

    /// Проекты встречи: чем помечена и чем можно пометить.
    ///
    /// Тег — атрибут встречи, родственный названию (`plan-projects.md` §4.1), и
    /// живёт он в той же строке, что дата и состав. Встреча без проекта — норма:
    /// интерфейс не осуждает и ничего не предлагает, кроме тихого «плюса».
    public struct Projects {
        /// Помеченные — `(id, имя)`, в порядке метки.
        public let tagged: [(id: String, name: String)]
        /// Чем ещё можно пометить — то, чего на встрече ещё нет.
        public let available: [(id: String, name: String)]
        public let tag: (String) -> Void
        public let untag: (String) -> Void
        /// Завести проект и сразу пометить им эту встречу.
        public let create: () -> Void
        /// Имя, которое приложение предложило бы завести по этой встрече
        /// (`plan-projects.md` §3), и согласие с ним. `nil` — предлагать нечего,
        /// и это нормальный ответ.
        ///
        /// Пунктирного тега из спеки здесь пока нет: он ждёт макета. Пункт меню —
        /// то же предложение без новых пикселей, и он **тихий**, как и требует
        /// §3: не мигает, не считается, не подсвечивается.
        public let suggestion: (name: String, accept: () -> Void, dismiss: () -> Void)?

        public init(
            tagged: [(id: String, name: String)],
            available: [(id: String, name: String)],
            tag: @escaping (String) -> Void,
            untag: @escaping (String) -> Void,
            create: @escaping () -> Void,
            suggestion: (name: String, accept: () -> Void, dismiss: () -> Void)? = nil
        ) {
            self.tagged = tagged
            self.available = available
            self.tag = tag
            self.untag = untag
            self.create = create
            self.suggestion = suggestion
        }
    }
}

/// Кладёт саммари в буфер обмена — иконкой, без подписи.
///
/// Свой тип, а не `Share` без заголовка: у этих двух разные предметы. Шер
/// выпускает ссылку наружу и потому подписан словом; копирование остаётся
/// на этой машине и потому знак. Общий тип заставил бы объяснять, почему у
/// одного заголовок пустой.
public struct Copy {
    public let handler: () -> Void
    public init(handler: @escaping () -> Void) {
        self.handler = handler
    }
}

/// Поднимает системный шер из угла панели.
public struct Share {
    public let title: String
    public let handler: () -> Void
    public init(_ title: String, handler: @escaping () -> Void) {
        self.title = title
        self.handler = handler
    }
}
}

/// Панель готовой встречи: одна колонка, и в ней всё, что о встрече известно.
///
/// Колонки заметок здесь больше нет. Заметка во время встречи стоит в ленте
/// расшифровки на своей секунде, а после встречи — разделом в саммари, который
/// правится как всё остальное в нём. Отдельный список рядом был третьим местом
/// для одной и той же вещи и стоил трети окна.
public struct MeetingPaneBody<MoreMenu: View>: View {
    /// Имя встречи и то, как её переименовать. `nil` — доска галереи и всё,
    /// что показывает саммари без встречи за ним.
    private let identity: MeetingPane.Identity?
    private let meta: MeetingPane.Meta?
    private let share: MeetingPane.Share?
    private let copy: MeetingPane.Copy?
    /// Троеточие — *меню*, а не кнопка: у «ещё» нет одного действия, и
    /// замыкание умело бы открыть его только где-то в другом месте.
    private let moreMenu: () -> MoreMenu
    private let hasMoreMenu: Bool
    private let mode: MeetingPaneMode
    private let summary: MeetingSummary
    private let turns: [MeetingTranscriptColumn.Turn]
    /// Заметки на своих секундах — для ленты расшифровки. Не то же самое, что
    /// `notes`: там они список сами по себе, здесь стоят среди реплик.
    private let transcriptNotes: [TranscriptNote]
    /// Что стоит в колонке саммари — решено `SummaryColumnContent`, не здесь.
    private let summaryContent: SummaryColumnContent
    /// Откуда взяты реплики: живая строка или готовая расшифровка. Отличать их
    /// надо ради замены — момент, когда проход по файлу вытесняет живой текст,
    /// это смена содержания, а не перерисовка.
    private let transcriptSource: TranscriptSource
    private let transcriptDisclosure: String?
    /// The summary's caret and what the action bar does to it. Owned above the
    /// pane, so the selection survives the pane being rebuilt.
    private let summaryController: SummaryEditorController
    /// nil where a summary cannot be saved: the gallery, and a meeting with no
    /// recap file to write into.
    private let onSummaryChange: ((MeetingSummary) -> Void)?
    private let onSummaryRewrite: ((SummaryRewrite, String) -> Void)?

    /// Чей текст сейчас в колонке транскрипта.
    public enum TranscriptSource: String, Equatable, Sendable {
        /// Встреча идёт или только что кончилась: то, что услышал живой слой.
        case live
        /// Проход по файлу закончен — это он.
        case stored
    }

    public init(
        identity: MeetingPane.Identity? = nil,
        meta: MeetingPane.Meta? = nil,
        share: MeetingPane.Share? = nil,
        copy: MeetingPane.Copy? = nil,
        hasMoreMenu: Bool = true,
        mode: MeetingPaneMode = .summary,
        summary: MeetingSummary,
        turns: [MeetingTranscriptColumn.Turn] = [],
        transcriptNotes: [TranscriptNote] = [],
        summaryContent: SummaryColumnContent = .summary,
        transcriptSource: TranscriptSource = .stored,
        transcriptDisclosure: String? = nil,
        summaryController: SummaryEditorController = SummaryEditorController(),
        onSummaryChange: ((MeetingSummary) -> Void)? = nil,
        onSummaryRewrite: ((SummaryRewrite, String) -> Void)? = nil,
        @ViewBuilder moreMenu: @escaping () -> MoreMenu
    ) {
        self.identity = identity
        self.meta = meta
        self.share = share
        self.copy = copy
        self.hasMoreMenu = hasMoreMenu
        self.moreMenu = moreMenu
        self.mode = mode
        self.summary = summary
        self.turns = turns
        self.transcriptNotes = transcriptNotes
        self.summaryContent = summaryContent
        self.transcriptSource = transcriptSource
        self.transcriptDisclosure = transcriptDisclosure
        self.summaryController = summaryController
        self.onSummaryChange = onSummaryChange
        self.onSummaryRewrite = onSummaryRewrite
    }

    public var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                head
                columns
            }
            // Потолок стоит на содержимом, а `.infinity` под ним центрирует
            // получившийся блок. Наоборот — потолок поверх отступов — уже
            // однажды посадил карточку настроек не туда, где её нарисовали.
            .frame(maxWidth: Tokens.Pane.paneMeasure, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .coordinateSpace(name: PaneProbe.space)
        // Угол принадлежит **окну**, а не блоку текста: кнопки прижаты к правой
        // верхней кромке панели на любой ширине.
        //
        // Макет этот спор не решает и решить не может: в 312:11129 блок 649
        // стоит впритык к правому краю окна (264 рельса + 649 = 913), то есть
        // «кромка блока» и «кромка окна» там — одна и та же линия. 27 августа
        // ревью выбрало блок, в тот же день владелец выбрал окно: кнопка,
        // отъезжающая от угла при расширении окна, читается как потерявшаяся,
        // а не как принадлежащая тексту. Прежний довод (на широком окне
        // «Поделиться» уезжает от имени встречи) остаётся правдой — он просто
        // проиграл: у угла есть свой смысл, и он сильнее соседства.
        //
        // Инсет прежний и живёт внутри кластера (`paneActionsInset`), поэтому
        // кнопка ловит нажатие до самой кромки.
        .overlay(alignment: .topTrailing) { actions }
    }

    /// Имя встречи над саммари — 312:11129. Живёт *выше* смены колонок:
    /// внутри неё заголовок исчезал бы при переключении на транскрипт и мигал
    /// на каждой смене содержания, то есть ровно в тот момент, когда доезжает
    /// саммари.
    @ViewBuilder
    private var head: some View {
        if identity != nil || meta != nil {
            VStack(alignment: .leading, spacing: Tokens.Pane.titleGap) {
                if let meta {
                    MeetingMetaRow(meta: meta)
                        .paneProbe(PaneProbe.meta)
                }
                if let identity {
                    MeetingPaneIdentity(
                        meetingID: identity.meetingID,
                        title: identity.title,
                        onRename: identity.onRename,
                        look: .body
                    )
                    .paneProbe(PaneProbe.title)
                }
            }
            .padding(.horizontal, Tokens.Pane.summaryHPadding)
            .padding(.top, Tokens.Pane.paneTopPadding)
        }
    }

    @ViewBuilder
    private var actions: some View {
        if hasMoreMenu || share != nil || copy != nil {
            HStack(spacing: Tokens.Pane.headerActionsGap) {
                if hasMoreMenu {
                    Menu {
                        moreMenu()
                    } label: {
                        PaneIconLabel(symbol: "ellipsis")
                    }
                    // `.borderlessButton` draws its own control over the label,
                    // so the hover chrome never showed and the ellipsis read as
                    // decoration beside a real button. `.button` + `.plain`
                    // hands the whole appearance back to the label.
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .help("Ещё")
                }
                // Копирование стоит слева от «Поделиться»: слева то, что
                // остаётся на этой машине, справа то, что уходит наружу.
                if let copy {
                    CopyButton(action: copy.handler)
                        .paneProbe(PaneProbe.copy)
                }
                if let share {
                    SharePill(title: share.title, action: share.handler)
                        .paneProbe(PaneProbe.share)
                }
            }
            .padding(Tokens.Pane.paneActionsInset)
            .fixedSize()
            .paneProbe(PaneProbe.actions)
        }
    }

    private var columns: some View {
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
                                .easeOut(duration: Tokens.Pane.columnSwapOut)
                            )
                        )
                    )
            }
            .animation(.default, value: columnKey)
            .frame(maxWidth: .infinity)
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
                MeetingTranscriptColumn(
                    turns: turns, notes: transcriptNotes, disclosure: transcriptDisclosure
                )
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
            // Те же заметки, что и в ветке-заменителе выше. Раньше их тут не
            // было, и написанное человеком на встрече исчезало от переключения
            // колонки — а также в тот момент, когда саммари доезжало и
            // заменитель уходил. Заметка стоит на своей секунде в ленте
            // (`NotePlacement`), то есть именно здесь ей и место; в разделе
            // саммари она есть тоже, и это дубль по решению, а не недосмотр:
            // пропустить написанное хуже, чем показать дважды.
            MeetingTranscriptColumn(
                turns: turns, notes: transcriptNotes, disclosure: transcriptDisclosure
            )
        }
    }
}

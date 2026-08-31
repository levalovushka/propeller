import SwiftUI
import PropellerPure

/// # Из чего собран раздел «Проекты» — Figma `projects` (254:3400)
///
/// Чистая вёрстка: ни `AppState`, ни `Preferences`, ни диска. Всё, что здесь
/// есть, — страница, сетка, карточка, кнопка и плита создания. Что на них
/// написано и что происходит по нажатию — `Sources/Projects/`.
///
/// Числовых литералов здесь нет, кроме строк: всё в `Tokens.Projects`.
///
/// # Что взято, а не написано заново
///
/// - хром страницы (`PanePage`) — тот же, что у настроек: это одна и та же
///   колонка панели с другим содержимым;
/// - меню карточки — системное (`MinimalIconMenu`). Макет рисует свою плиту в
///   220 pt, но по тому же решению, что и у `SettingsMenu`: нарисованное меню
///   теряет клавиатуру и доступность, а видно у него ровно триггер;
/// - плита создания стоит на `SummonedPlate` — стекло, тень и угол у всего, что
///   приложение подняло над собой, одни.

// MARK: - Кнопка действия

/// Кнопка этого экрана — Figma 255:5078.
///
/// Не `SettingsButton`: у той скругление 6 и акцентная заливка правого слота, а
/// здесь 8 и белая. Белая заливка в приложении первая, и она осознанно не
/// синяя: на этом экране акцент один, и синий уже занят тумблерами.
public struct ProjectsActionButton: View {
    public enum Role { case primary, quiet }

    private let title: String
    private let role: Role
    private let enabled: Bool
    private let action: () -> Void

    @State private var hovering = false

    public init(
        _ title: String,
        role: Role = .primary,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.role = role
        self.enabled = enabled
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .typo(Tokens.Projects.Typo.action)
                .foregroundStyle(role == .primary
                    ? Tokens.Projects.actionLabel
                    : Tokens.Projects.quietActionLabel)
                .padding(.horizontal, Tokens.Projects.actionLabelInset)
                .padding(.horizontal, Tokens.Projects.actionHPadding)
                .frame(height: Tokens.Projects.actionHeight)
                .background(
                    role == .primary ? Tokens.Projects.actionFill : .clear,
                    in: RoundedRectangle(cornerRadius: Tokens.Projects.actionRadius, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.press)
        .disabled(!enabled)
        .opacity(enabled ? (hovering ? 0.85 : 1) : 0.4)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.Motion.hover), value: hovering)
        .fixedSize()
    }
}

// MARK: - Карточка

/// Карточка проекта — Figma 255:5082.
///
/// Высота названа (156), а не выведена из текста: карточки стоят сеткой, и ряд
/// ростом по содержимому ломает строй на первом же проекте без описания. Поэтому
/// описание обрезается, а подпись стоит у нижнего края.
public struct ProjectCard<Menu: View>: View {
    private let name: String
    private let about: String
    private let footer: String
    /// Архивный проект стоит в конце сетки приглушённым. Прятать его совсем
    /// нельзя: убрать в архив умеет меню карточки, а вернуть было бы нечем.
    private let dimmed: Bool
    private let open: () -> Void
    private let menu: () -> Menu

    @State private var hovering = false

    public init(
        name: String,
        about: String,
        footer: String,
        dimmed: Bool = false,
        open: @escaping () -> Void,
        @ViewBuilder menu: @escaping () -> Menu
    ) {
        self.name = name
        self.about = about
        self.footer = footer
        self.dimmed = dimmed
        self.open = open
        self.menu = menu
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Tokens.Projects.cardGap) {
                HStack(alignment: .top, spacing: 0) {
                    Text(name)
                        .typo(Tokens.Projects.Typo.title)
                        .foregroundStyle(Tokens.Projects.title)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // Троеточие живёт под курсором: восемь карточек с восемью
                    // многоточиями — это восемь предложений там, где человек
                    // читает названия.
                    //
                    // Потолок стоит **на меню**, а не на ряду. `MinimalIconMenu`
                    // — квадрат в 24, ряд от него становился 24 вместо 16.
                    // Потолок на ряду это чинил только на бумаге: содержимое в
                    // 24 внутри рамки в 16 SwiftUI центрирует, и название
                    // уезжало на 4–5 pt вверх — замерено, кромка карточки 120.0,
                    // верх букв 126.5 при должных ~136. Ограниченное меню
                    // свисает само и название не трогает.
                    menu()
                        .frame(height: Tokens.Projects.Typo.title.lineHeight)
                        .opacity(hovering ? 1 : 0)
                }
                if !about.isEmpty {
                    // Три строки — из макета (255:5089): бокс описания там 42 pt
                    // при строке 14. Не «сколько влезет»: подпись внизу карточки
                    // стоит на своём месте у всех восьми, и описание, которое
                    // дотягивается до неё, съедает строй сетки.
                    Text(about)
                        .typo(Tokens.Projects.Typo.body)
                        .foregroundStyle(Tokens.Projects.quiet)
                        .multilineTextAlignment(.leading)
                        .lineLimit(Tokens.Projects.aboutLines)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            Spacer(minLength: Tokens.Projects.cardGap)
            Text(footer)
                .typo(Tokens.Projects.Typo.body)
                .foregroundStyle(Tokens.Projects.quiet)
                .lineLimit(1)
        }
        .padding(.horizontal, Tokens.Projects.cardHPadding)
        .padding(.vertical, Tokens.Projects.cardVPadding)
        .frame(height: Tokens.Projects.cardHeight, alignment: .topLeading)
        .frame(maxWidth: .infinity)
        .background(
            hovering ? Tokens.Projects.cardHoverFill : Tokens.Projects.cardFill,
            in: RoundedRectangle(cornerRadius: Tokens.Projects.cardRadius, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Projects.cardRadius, style: .continuous))
        .opacity(dimmed ? Tokens.Projects.archivedOpacity : 1)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.Motion.hover), value: hovering)
    }
}

// MARK: - Пусто

/// Панель без единого проекта — Figma 255:5215.
///
/// Ни заголовка раздела, ни панели навигации: пока проектов нет, сортировать
/// нечего, и страница целиком отдана объяснению.
public struct ProjectsEmptyState: View {
    private let create: () -> Void

    public init(create: @escaping () -> Void) {
        self.create = create
    }

    public var body: some View {
        VStack(spacing: Tokens.Projects.Empty.gap) {
            Image(systemName: "folder.fill.badge.plus")
                .font(.system(size: Tokens.Projects.Empty.markSize, weight: .regular))
                .foregroundStyle(Tokens.Projects.title)
            VStack(spacing: Tokens.Projects.Empty.textGap) {
                Text("Объединяйте встречи в проекты")
                    .typo(Tokens.Settings.Typo.page)
                    .foregroundStyle(Tokens.Settings.title)
                Text("""
                Проект это история встреч на определённую тему — \
                по ней видно, как шло дело, где были противоречия \
                и что терялось по пути
                """)
                    .typo(Tokens.Projects.Typo.title)
                    .foregroundStyle(Tokens.Projects.quiet)
            }
            .multilineTextAlignment(.center)
            .frame(width: Tokens.Projects.Empty.measure)
            ProjectsActionButton("Новый проект", action: create)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Tokens.Settings.pageHPadding)
        .padding(.vertical, Tokens.Settings.pageVPadding)
    }
}

// MARK: - Создание

/// Плита «Создайте проект» — Figma 261:9361.
///
/// Это первая модалка приложения, и она заведена решением владельца 2026-08-27:
/// `design/notifications.md` §5 пока разрешает модалку только необратимому
/// действию по клику, канон переписывается под этот случай.
///
/// Второго шага макета («Добавьте встречи», 262:10761) здесь нет: привязка
/// встреч к проекту живёт на экране проекта, и делать её дважды — в мастере и
/// на вкладке — значит заводить два места, где одна и та же правка выглядит
/// по-разному. Поэтому кнопка говорит «Создать», а не «Продолжить».
public struct ProjectComposer: View {
    private let title: String
    private let confirm: String
    @Binding private var name: String
    @Binding private var about: String
    private let submit: () -> Void
    private let cancel: () -> Void

    @FocusState private var nameFocused: Bool

    public init(
        title: String = "Создайте проект",
        confirm: String = "Создать",
        name: Binding<String>,
        about: Binding<String>,
        submit: @escaping () -> Void,
        cancel: @escaping () -> Void
    ) {
        self.title = title
        self.confirm = confirm
        self._name = name
        self._about = about
        self.submit = submit
        self.cancel = cancel
    }

    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Projects.Modal.blockGap) {
                header
                field("Над чем работаете?") {
                    TextField("Дайте проекту название", text: $name)
                        .textFieldStyle(.plain)
                        .focused($nameFocused)
                        .onSubmit { if canSubmit { submit() } }
                        .typo(Tokens.Projects.Typo.action)
                        .foregroundStyle(Tokens.Projects.title)
                        .padding(.horizontal, Tokens.Projects.Modal.fieldHPadding)
                        .frame(height: Tokens.Projects.Modal.fieldHeight)
                        .background(box)
                }
                field("О чём этот проект?") { editor }
                footer
        }
        .padding(Tokens.Projects.Modal.padding)
        .frame(width: Tokens.Projects.Modal.width)
        // Плита, а не стекло `SummonedPlate`. Вызванный инструмент парит над
        // тем, что человек продолжает читать, — модалка это чтение перекрывает,
        // и макет так её и рисует: почти непрозрачная заливка (261:9361).
        // Стекло здесь показывало бы сетку карточек сквозь поле ввода.
        .background(
            RoundedRectangle(cornerRadius: Tokens.Projects.Modal.radius, style: .continuous)
                .fill(Tokens.Projects.Modal.plate)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Projects.Modal.radius, style: .continuous)
                .stroke(Tokens.Projects.Modal.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Projects.Modal.radius, style: .continuous))
        .shadow(color: Tokens.Projects.Modal.shadow, radius: Tokens.Projects.Modal.haloRadius)
        .shadow(color: Tokens.Projects.Modal.shadow,
                radius: Tokens.Projects.Modal.dropRadius,
                y: Tokens.Projects.Modal.dropY)
        .onAppear { nameFocused = true }
    }

    private var header: some View {
        HStack(spacing: Tokens.Projects.cardGap) {
            Text(title)
                .typo(Tokens.Projects.Typo.modalTitle)
                .foregroundStyle(Tokens.Settings.title)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: cancel) {
                Image(systemName: "xmark")
                    .font(.system(size: Tokens.Projects.Typo.title.size, weight: .regular))
                    .foregroundStyle(Tokens.Projects.quiet)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.press)
            .accessibilityLabel("Закрыть")
        }
    }

    private func field<Content: View>(
        _ label: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Projects.Modal.labelGap) {
            Text(label)
                .typo(Tokens.Projects.Typo.label)
                .foregroundStyle(Tokens.Projects.Modal.label)
            content()
        }
    }

    /// Описание с счётчиком. Предел — не подсказка: `0/200` в макете стоит над
    /// полем, которое обрезает, а не над полем, которое ругается.
    private var editor: some View {
        VStack(alignment: .leading, spacing: Tokens.Projects.cardGap) {
            TextEditor(text: Binding(
                get: { about },
                set: { about = String($0.prefix(Tokens.Projects.Modal.aboutLimit)) }
            ))
            .scrollContentBackground(.hidden)
            .textEditorStyle(.plain)
            .typo(Tokens.Projects.Typo.action)
            .foregroundStyle(Tokens.Projects.title)
            // `TextEditor` носит свои внутренние поля (5 pt по горизонтали) и
            // отдать их не умеет. Компенсируются здесь, чтобы набранный текст
            // и подсказка стояли на одной вертикали с полем имени над ними.
            .padding(.horizontal, -Tokens.Projects.Modal.editorInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay(alignment: .topLeading) {
                if about.isEmpty {
                    Text("Опишите проект, цели, контекст — так саммари по проекту будут точнее и содержательнее")
                        .typo(Tokens.Projects.Typo.action)
                        .foregroundStyle(Tokens.Projects.quiet)
                        .allowsHitTesting(false)
                }
            }
            Text("\(about.count)/\(Tokens.Projects.Modal.aboutLimit)")
                .typo(Tokens.Projects.Typo.label)
                .foregroundStyle(Tokens.Projects.Modal.label)
        }
        .padding(.horizontal, Tokens.Projects.Modal.fieldHPadding)
        .padding(.vertical, Tokens.Projects.Modal.fieldVPadding)
        .frame(height: Tokens.Projects.Modal.editorHeight)
        .background(box)
    }

    private var footer: some View {
        HStack(spacing: Tokens.Projects.cardGap) {
            Spacer(minLength: 0)
            ProjectsActionButton("Отменить", role: .quiet, action: cancel)
            ProjectsActionButton(confirm, enabled: canSubmit, action: submit)
        }
    }

    private var box: some View {
        RoundedRectangle(cornerRadius: Tokens.Projects.Modal.fieldRadius, style: .continuous)
            .fill(Tokens.Projects.Modal.fill)
    }
}

// MARK: - Экран проекта

/// Полоса вкладок — Figma 256:7547.
///
/// Не `Picker`: существующий переключатель колонок панели живёт внутри меню
/// «ещё», а здесь вкладки стоят строкой и читаются как места, а не как выбор.
/// Чип тот же, что у меню сортировки, — 32 pt, скругление 8, надпись 12: это
/// один и тот же предмет разной начинки.
public struct ProjectTabBar: View {
    @Binding private var selection: ProjectTab

    public init(selection: Binding<ProjectTab>) {
        self._selection = selection
    }

    public var body: some View {
        HStack(spacing: Tokens.Projects.Screen.tabGap) {
            ForEach(ProjectTab.allCases, id: \.self) { tab in
                Button { selection = tab } label: {
                    Text(tab.title)
                        .typo(Tokens.Projects.Typo.action)
                        .foregroundStyle(tab == selection
                            ? Tokens.Projects.title
                            : Tokens.Projects.quiet)
                        .padding(.horizontal, Tokens.Projects.actionHPadding)
                        .frame(height: Tokens.Projects.actionHeight)
                        .background(
                            tab == selection ? Tokens.Projects.sortFill : .clear,
                            in: RoundedRectangle(
                                cornerRadius: Tokens.Projects.actionRadius, style: .continuous
                            )
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.press)
            }
        }
        .frame(height: Tokens.Projects.actionHeight)
    }
}

/// Строка встречи в списке проекта — Figma 256:8832.
///
/// Сверху тихая строка «название · когда» и длительность справа, снизу — то, о
/// чём встреча была. Порядок именно такой: в списке одного проекта названия
/// повторяются («Дейлик», «Дейлик», «Дейлик»), и различает встречи вторая
/// строка, а не первая.
public struct ProjectMeetingRow: View {
    private let title: String
    private let when: String
    private let duration: String
    private let subject: String
    private let open: () -> Void

    @State private var hovering = false

    public init(
        title: String, when: String, duration: String, subject: String,
        open: @escaping () -> Void
    ) {
        self.title = title
        self.when = when
        self.duration = duration
        self.subject = subject
        self.open = open
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Projects.Screen.rowLineGap) {
            HStack(spacing: Tokens.Projects.Screen.metaGap) {
                Text(title).lineLimit(1)
                if !when.isEmpty {
                    Text("·")
                    Text(when).lineLimit(1)
                }
                Spacer(minLength: Tokens.Projects.Screen.metaGap)
                if !duration.isEmpty { Text(duration) }
            }
            .typo(Tokens.Projects.Typo.body)
            .foregroundStyle(Tokens.Projects.quiet)
            if !subject.isEmpty {
                Text(subject)
                    .typo(Tokens.Projects.Typo.title)
                    .foregroundStyle(Tokens.Settings.title)
                    .frame(maxWidth: Tokens.Projects.Screen.rowMeasure, alignment: .topLeading)
            }
        }
        .padding(.vertical, Tokens.Projects.Screen.rowVPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            hovering ? Tokens.Projects.Screen.rowHoverFill : .clear,
            in: RoundedRectangle(cornerRadius: Tokens.Projects.Screen.rowRadius, style: .continuous)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.Motion.hover), value: hovering)
    }
}

/// Строка человека — Figma 256:7571.
///
/// Значок один на всех и родовой: аватаров у нас нет и взять их неоткуда, а
/// инициал в кружке — обещание портрета, которого никто не сдержит. В макете
/// он такой же.
public struct ProjectPersonRow: View {
    private let name: String
    private let subtitle: String

    public init(name: String, subtitle: String) {
        self.name = name
        self.subtitle = subtitle
    }

    public var body: some View {
        HStack(spacing: Tokens.Projects.Screen.avatarGap) {
            Image(systemName: "person.fill")
                .font(.system(size: Tokens.Projects.Typo.title.size, weight: .regular))
                .foregroundStyle(Tokens.Projects.quiet)
                .frame(width: Tokens.Projects.Screen.avatarSide,
                       height: Tokens.Projects.Screen.avatarSide)
                .background(
                    Tokens.Projects.Screen.avatarFill,
                    in: RoundedRectangle(
                        cornerRadius: Tokens.Projects.Screen.avatarRadius, style: .continuous
                    )
                )
            VStack(alignment: .leading, spacing: Tokens.Projects.Screen.rowLineGap) {
                Text(name)
                    .typo(Tokens.Projects.Typo.title)
                    .foregroundStyle(Tokens.Settings.title)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .typo(Tokens.Projects.Typo.body)
                        .foregroundStyle(Tokens.Projects.quiet)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Tokens.Projects.Screen.rowVPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Решения и задачи

/// Пункт конспекта на экране проекта — Figma 297:25131 (задача) и 297:25207
/// (решение).
///
/// Один компонент на оба, и теперь без единой разницы в маркере: у обоих
/// кружок, и кружок этот **маркер списка, а не состояние** (решение владельца
/// 2026-08-27). Квадрат-чекбокс у задачи снят: он был единственным, что
/// ставило галочку, и ставил он её прямо в файл встречи. Задачи с созвона —
/// не наш таск-трекер (VISION §4, MISSION §6), а строка, которую человек
/// прочитает.
public struct ProjectAtomRow: View {
    private let done: Bool
    private let text: String
    private let assignee: String?
    private let people: [String]
    private let dropAssignee: (() -> Void)?
    private let setAssignee: ((String) -> Void)?
    private let edit: ((String) -> Void)?
    private let remove: () -> Void

    @State private var hovering = false
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    public init(
        done: Bool,
        text: String,
        assignee: String?,
        people: [String] = [],
        dropAssignee: (() -> Void)? = nil,
        setAssignee: ((String) -> Void)? = nil,
        edit: ((String) -> Void)? = nil,
        remove: @escaping () -> Void
    ) {
        self.done = done
        self.text = text
        self.assignee = assignee
        self.people = people
        self.dropAssignee = dropAssignee
        self.setAssignee = setAssignee
        self.edit = edit
        self.remove = remove
    }

    public var body: some View {
        HStack(alignment: .top, spacing: Tokens.Projects.Atom.markerGap) {
            markerGlyph
            VStack(alignment: .leading, spacing: Tokens.Projects.Atom.chipGap) {
                if editing {
                    field
                } else {
                    Text(text)
                        .typo(Tokens.Projects.Typo.title)
                        .foregroundStyle(done ? Tokens.Projects.Atom.doneText : Tokens.Projects.title)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                if let assignee {
                    chip(assignee)
                        .opacity(done ? Tokens.Projects.Atom.doneChipOpacity : 1)
                // Сделанной задаче ответственного не предлагают: спрашивать, кто
                // это сделает, у того, что уже сделано, — вопрос без адресата.
                // Так же и в макете (297:25158 — чип есть, кнопки нет).
                } else if let setAssignee, !done, !people.isEmpty {
                    addAssignee(setAssignee)
                }
            }
            .padding(.trailing, Tokens.Projects.Atom.textInset)
            // Действия живут под курсором: у пятнадцати пунктов подряд
            // пятнадцать корзин — это пятнадцать предложений удалить там, где
            // читают.
            HStack(spacing: Tokens.Projects.Atom.actionGap) {
                if edit != nil {
                    action("square.and.pencil", "Править пункт") {
                        draft = text
                        editing = true
                        focused = true
                    }
                }
                action("trash", "Удалить пункт", do: remove)
            }
            .opacity(hovering ? 1 : 0)
            // Кнопка с нулевой прозрачностью в SwiftUI всё ещё ловит нажатие.
            // Для «удалить» это значит удаление по клику в пустое место строки,
            // за которой не следили мышью.
            .allowsHitTesting(hovering)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.Motion.hover), value: hovering)
    }

    /// Кружок — и только он. Не кнопка: нажимать не на что, а значок, который
    /// выглядит нажимаемым и ничего не делает, — тупик (`design/no-dead-ends.md`).
    private var markerGlyph: some View {
        Image(systemName: "circle")
            .font(.system(size: Tokens.Projects.Typo.title.size, weight: .regular))
            .foregroundStyle(Tokens.Projects.quiet)
            .frame(width: Tokens.Projects.Atom.markerSide,
                   height: Tokens.Projects.Atom.markerSide)
            .contentShape(Rectangle())
    }

    /// Правка формулировки прямо в строке. Поле растёт вниз, а не уезжает
    /// вбок: пункт бывает в четыре строки, и править его в однострочном окне
    /// значило бы править вслепую.
    private var field: some View {
        TextField("", text: $draft, axis: .vertical)
            .textFieldStyle(.plain)
            .focused($focused)
            .typo(Tokens.Projects.Typo.title)
            .foregroundStyle(Tokens.Settings.title)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .onSubmit(commit)
            .onExitCommand(perform: cancel)
    }

    private func action(
        _ symbol: String, _ label: String, do run: @escaping () -> Void
    ) -> some View {
        Button(action: run) {
            Image(systemName: symbol)
                .font(.system(size: Tokens.Projects.Typo.title.size, weight: .regular))
                .foregroundStyle(Tokens.Projects.quiet)
                .frame(width: Tokens.Projects.Atom.markerSide,
                       height: Tokens.Projects.Atom.markerSide)
                .contentShape(Rectangle())
        }
        .buttonStyle(.press)
        .accessibilityLabel(label)
    }

    /// Пустая правка — отказ, а не удаление: удаляют корзиной, и подменять её
    /// стёртым текстом значило бы прятать необратимое за опечаткой.
    private func commit() {
        // Перенос строки складывается в пробел, а не отвергается: пункт — одна
        // строка файла, и вставленный из письма абзац должен доехать, а не
        // молча не сохраниться.
        let flat = draft.split(whereSeparator: \.isNewline).joined(separator: " ")
        let trimmed = flat.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, trimmed != text { edit?(trimmed) }
        cancel()
    }

    private func cancel() {
        editing = false
        focused = false
        draft = ""
    }

    private func chip(_ name: String) -> some View {
        HStack(spacing: Tokens.Projects.Atom.Chip.gap) {
            Text(name)
                .foregroundStyle(Tokens.Projects.title)
            if let dropAssignee {
                Button(action: dropAssignee) {
                    Image(systemName: "xmark")
                        .font(.system(size: Tokens.Projects.Typo.action.size, weight: .regular))
                        .foregroundStyle(Tokens.Projects.quiet)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.press)
                .accessibilityLabel("Снять ответственного")
            }
        }
        .typo(Tokens.Projects.Typo.action)
        .padding(.horizontal, Tokens.Projects.Atom.Chip.hPadding)
        .frame(height: Tokens.Projects.Atom.Chip.height)
        .background(
            Tokens.Projects.Atom.Chip.fill,
            in: RoundedRectangle(cornerRadius: Tokens.Projects.Atom.Chip.radius, style: .continuous)
        )
    }

    /// Предлагаются только те, кого проект уже знает по своим встречам.
    ///
    /// Не поле для ввода: ответственный вне состава — то, что
    /// `RecapLint.assigneesOutsideRoster` считает дефектом конспекта, и заводить
    /// экран, который его производит, значило бы спорить с собственной
    /// проверкой. Пустой состав — кнопки нет вовсе: предлагать выбор из ничего
    /// хуже, чем не предлагать.
    private func addAssignee(_ set: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(people, id: \.self) { name in
                Button(name) { set(name) }
            }
        } label: {
            HStack(spacing: Tokens.Projects.Atom.AddAssignee.gap) {
                Image(systemName: "plus")
                    .font(.system(size: Tokens.Projects.Typo.action.size, weight: .regular))
                Text("Добавить ответственного")
                    .padding(.horizontal, Tokens.Projects.Atom.AddAssignee.labelInset)
            }
            .typo(Tokens.Projects.Typo.action)
            .foregroundStyle(Tokens.Projects.quiet)
            .padding(.horizontal, Tokens.Projects.Atom.AddAssignee.hPadding)
            .frame(height: Tokens.Projects.Atom.AddAssignee.height)
            .overlay(
                RoundedRectangle(
                    cornerRadius: Tokens.Projects.Atom.AddAssignee.radius, style: .continuous
                )
                .strokeBorder(Tokens.Projects.Atom.AddAssignee.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// Последняя строка карточки — Figma 297:25164 / 312:11329.
///
/// Плюс и «Добавить…», обе половины тихие. Поле появляется по нажатию и
/// исчезает по `Esc` или по пустому вводу: строка ввода, стоящая всегда, — это
/// приглашение, а карточка пунктов ничего не просит.
public struct ProjectAtomAddRow: View {
    private let add: (String) -> Void

    @State private var typing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    public init(add: @escaping (String) -> Void) {
        self.add = add
    }

    public var body: some View {
        HStack(alignment: .top, spacing: Tokens.Projects.Atom.addGap) {
            // Плюс той же тишины, что и надпись (40 %, 297:25164): это одна
            // строка, а не значок при подписи. Стояли 30 и 40 — разъезжались.
            Image(systemName: "plus")
                .font(.system(size: Tokens.Projects.Typo.title.size, weight: .regular))
                .foregroundStyle(Tokens.Projects.quiet)
                .frame(width: Tokens.Projects.Atom.markerSide,
                       height: Tokens.Projects.Typo.title.lineHeight)
            if typing {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand(perform: dismiss)
                    .typo(Tokens.Projects.Typo.title)
                    .foregroundStyle(Tokens.Settings.title)
            } else {
                Text("Добавить…")
                    .typo(Tokens.Projects.Typo.title)
                    .foregroundStyle(Tokens.Projects.quiet)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !typing else { return }
            typing = true
            focused = true
        }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return dismiss() }
        add(trimmed)
        // Поле остаётся открытым и пустым: пункты добавляют пачкой, и закрывать
        // его после каждого значило бы просить ещё один клик на каждую строку.
        text = ""
    }

    private func dismiss() {
        text = ""
        typing = false
        focused = false
    }
}

/// Карточка пунктов одной встречи — Figma 297:25130.
///
/// Строки разделены воздухом, а не линиями: пункт бывает в четыре строки, и
/// волосяная линия между такими читается как таблица.
public struct ProjectAtomCard<Content: View>: View {
    private let content: () -> Content

    public init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Projects.Atom.rowGap) {
            content()
        }
        .padding(Tokens.Projects.Atom.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Tokens.Settings.cardFill,
            in: RoundedRectangle(cornerRadius: Tokens.Projects.Atom.cardRadius, style: .continuous)
        )
    }
}

/// Подпись над карточкой: чья это встреча и когда она была — Figma 256:7303.
public struct ProjectAtomGroupHeader: View {
    private let title: String
    private let when: String

    public init(title: String, when: String) {
        self.title = title
        self.when = when
    }

    public var body: some View {
        HStack(spacing: Tokens.Projects.Screen.metaGap) {
            Text(title).lineLimit(1)
            Spacer(minLength: Tokens.Projects.Screen.metaGap)
            Text(when).lineLimit(1)
        }
        .typo(Tokens.Projects.Typo.groupHeader)
        .foregroundStyle(Tokens.Settings.header)
        .padding(.horizontal, Tokens.Projects.Screen.groupHeaderInset)
    }
}

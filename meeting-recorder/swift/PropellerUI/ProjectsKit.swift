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

// MARK: - Сортировка

/// Триггер выбора порядка — Figma 255:5132. Список системный, по той же причине,
/// по какой он системный у `SettingsMenu`.
public struct ProjectsSortMenu: View {
    @Binding private var selection: ProjectOrder

    public init(selection: Binding<ProjectOrder>) {
        self._selection = selection
    }

    public var body: some View {
        Menu {
            ForEach(ProjectOrder.allCases, id: \.self) { order in
                Button {
                    selection = order
                } label: {
                    if order == selection {
                        Label(order.title, systemImage: "checkmark")
                    } else {
                        Text(order.title)
                    }
                }
            }
        } label: {
            HStack(spacing: Tokens.Projects.cardGap) {
                Text(selection.title)
                    .foregroundStyle(Tokens.Projects.title)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: Tokens.Projects.Typo.action.size, weight: .regular))
                    .foregroundStyle(Tokens.Projects.quiet)
            }
            .typo(Tokens.Projects.Typo.action)
            .padding(.horizontal, Tokens.Projects.actionHPadding)
            .frame(height: Tokens.Projects.actionHeight)
            .background(
                Tokens.Projects.sortFill,
                in: RoundedRectangle(cornerRadius: Tokens.Projects.actionRadius, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
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
    private let open: () -> Void
    private let menu: () -> Menu

    @State private var hovering = false

    public init(
        name: String,
        about: String,
        footer: String,
        open: @escaping () -> Void,
        @ViewBuilder menu: @escaping () -> Menu
    ) {
        self.name = name
        self.about = about
        self.footer = footer
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
                    menu()
                        .opacity(hovering ? 1 : 0)
                }
                // Ряд ростом со строку названия (16), а не со своим меню:
                // `MinimalIconMenu` — квадрат в 24, и без потолка он поднимал
                // шапку карточки на восемь точек, отодвигая описание.
                .frame(height: Tokens.Projects.Typo.title.lineHeight)
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

/// Волосяная линия между строками списка. Между, а не после каждой: последняя
/// строка не отделяется от пустоты под собой.
public struct ProjectRowDivider: View {
    public init() {}

    public var body: some View {
        Rectangle()
            .fill(Tokens.Projects.Screen.divider)
            .frame(height: Tokens.Settings.dividerHeight)
    }
}

/// Строка встречи в проекте — Figma 256:8832.
public struct ProjectMeetingRow: View {
    private let meta: String
    private let subtitle: String
    private let open: () -> Void

    @State private var hovering = false

    public init(meta: String, subtitle: String, open: @escaping () -> Void) {
        self.meta = meta
        self.subtitle = subtitle
        self.open = open
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Projects.Screen.rowLineGap) {
            Text(meta)
                .typo(Tokens.Projects.Typo.body)
                .foregroundStyle(Tokens.Projects.quiet)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .typo(Tokens.Projects.Typo.title)
                    .foregroundStyle(Tokens.Projects.title)
                    .lineLimit(Tokens.Projects.Screen.meetingLines)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .padding(.vertical, Tokens.Projects.Screen.rowVPadding)
        .padding(.horizontal, Tokens.Projects.Screen.meetingInset)
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
/// Кружок с инициалом, а не аватар: картинок у нас нет и взять их неоткуда, а
/// пустой серый круг на каждой строке — это обещание фотографии, которого никто
/// не сдержит.
public struct ProjectPersonRow: View {
    private let name: String
    private let subtitle: String

    public init(name: String, subtitle: String) {
        self.name = name
        self.subtitle = subtitle
    }

    private var initial: String {
        String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
    }

    public var body: some View {
        HStack(spacing: Tokens.Projects.Screen.avatarGap) {
            Text(initial)
                .typo(Tokens.Projects.Typo.title)
                .foregroundStyle(Tokens.Projects.quiet)
                .frame(width: Tokens.Projects.Screen.avatarSide,
                       height: Tokens.Projects.Screen.avatarSide)
                .background(Tokens.Projects.Screen.avatarFill, in: Circle())
            VStack(alignment: .leading, spacing: Tokens.Projects.Screen.rowLineGap) {
                Text(name)
                    .typo(Tokens.Projects.Typo.title)
                    .foregroundStyle(Tokens.Projects.title)
                    .lineLimit(1)
                Text(subtitle)
                    .typo(Tokens.Projects.Typo.body)
                    .foregroundStyle(Tokens.Projects.quiet)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Tokens.Projects.Screen.rowVPadding)
        .padding(.horizontal, Tokens.Projects.Screen.personInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

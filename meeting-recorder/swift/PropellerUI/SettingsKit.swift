import SwiftUI

/// # Настройки — состояние правой панели
///
/// Раньше это было отдельное окно с пятью вкладками, и вкладка — довольно
/// сильное утверждение: «эти пять наборов настолько разные, что показывать их
/// вместе нельзя». Их там полторы страницы. Теперь настройки живут там же, где
/// всё остальное в этом приложении, — в правой панели, — и открываются той же
/// строкой рельса, что и любая встреча.
///
/// Отсюда и мерка: колонка настроек — это **та же** колонка, что колонка
/// саммари, с теми же полями и тем же потолком. Панель не меняет ширину, когда
/// в ней меняется содержимое.
///
/// Чистая презентация, как рельс и панель: набор берёт строки и биндинги и
/// отдаёт замыкания. Ничего из `AppState`, `Preferences` и `UserDefaults` здесь
/// нет — это в `Sources/SettingsPane.swift`, где ему и место.
///
/// Числа — в `Tokens.Settings`. В компоненте не должно быть литерала, кроме строки.

// MARK: - Header

/// Шапка панели с настройками — та же 48 pt строка, что у встречи.
///
/// Ни переименования, ни «ещё», ни «поделиться»: у настроек нет имени, которое
/// можно поменять, и нечем поделиться. Остаётся название экрана — и оно стоит
/// ровно там же, где стояло бы название встречи.
public struct SettingsPaneHeader: View {
    private let title: String

    public init(title: String = "Настройки") {
        self.title = title
    }

    public var body: some View {
        HStack(spacing: 0) {
            Text(title)
                .typoBlock(Tokens.Pane.Typo.headerTitle)
                .foregroundStyle(Tokens.Pane.title)
                .lineLimit(1)
                .padding(.horizontal, Tokens.Pane.headerHPadding)
                .padding(.vertical, Tokens.Pane.headerVPadding)
            Spacer(minLength: Tokens.Space.s8)
        }
        .frame(height: Tokens.Pane.headerHeight)
    }
}

// MARK: - Column

/// Колонка настроек: скролл, поля саммари, центрирование в остатке.
public struct SettingsColumn<Content: View>: View {
    @ViewBuilder private let content: () -> Content

    public init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    public var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: Tokens.Settings.groupGap) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Tokens.Settings.hPadding)
            .padding(.top, Tokens.Settings.topPadding)
            .padding(.bottom, Tokens.Settings.bottomPadding)
            // Мера, а не контейнер, и дальше центрирование — ровно как у
            // саммари: прижатая к левому краю широкого окна колонка оставляет
            // рядом поле пустоты.
            .frame(maxWidth: Tokens.Settings.maxWidth + Tokens.Settings.hPadding * 2)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
    }
}

// MARK: - Group

/// Группа ячеек: тихий заголовок и плашка под ним, ячейки внутри разделены
/// волосяной линией.
///
/// Плашка — та же, что у строки встречи под ховером (`Tokens.Settings.plate*`),
/// и это единственное, чем группа отличается от дня в рельсе: у встреч плашку
/// зажигает указатель, здесь она горит всегда, потому что держит вместе строки,
/// которые иначе ничем не связаны.
///
/// Строки берутся **списком**, а не одним `ViewBuilder`-деревом: разделитель
/// ставится *между* ячейками, а сколько их и где границы — из склеенного `some
/// View` не узнать. `if` внутри блока даёт ноль строк, а не пустую ячейку с
/// разделителем вокруг неё.
public struct SettingsGroup: View {
    private let title: String
    private let rows: [AnyView]

    public init(_ title: String, @SettingsRows rows: () -> [AnyView]) {
        self.title = title
        self.rows = rows()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .typoBlock(Tokens.Settings.Typo.header)
                .foregroundStyle(Tokens.Settings.header)
                .padding(.leading, Tokens.Settings.headerLeadingInset)
                .padding(.bottom, Tokens.Settings.headerBottomGap)
            plate
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var plate: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows.indices, id: \.self) { index in
                if index > 0 { SettingsDivider() }
                rows[index]
            }
        }
        .padding(.horizontal, Tokens.Settings.plateHPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Tokens.Settings.plateFill,
            in: RoundedRectangle(cornerRadius: Tokens.Settings.plateRadius, style: .continuous)
        )
    }
}

/// Собирает ячейки группы в список. `if` даёт ноль строк, а не пустую.
@resultBuilder
public enum SettingsRows {
    public static func buildExpression<V: View>(_ view: V) -> [AnyView] { [AnyView(view)] }
    public static func buildBlock(_ parts: [AnyView]...) -> [AnyView] { parts.flatMap { $0 } }
    public static func buildOptional(_ part: [AnyView]?) -> [AnyView] { part ?? [] }
    public static func buildEither(first: [AnyView]) -> [AnyView] { first }
    public static func buildEither(second: [AnyView]) -> [AnyView] { second }
    public static func buildArray(_ parts: [[AnyView]]) -> [AnyView] { parts.flatMap { $0 } }
}

/// Волосяная линия между ячейками — на 2× ровно один пиксель, как у рельса.
struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(Tokens.Settings.divider)
            .frame(height: 0.5)
            .frame(maxWidth: .infinity)
    }
}

// MARK: - Cells

/// Ячейка: слева то, что настраивается, справа — чем.
///
/// Вторая строка — под заголовком, а не под всей ячейкой: она объясняет именно
/// эту настройку, и прочитать её надо до того, как рука дошла до выключателя.
public struct SettingsCell<Control: View>: View {
    private let title: String
    private let subtitle: String?
    @ViewBuilder private let control: () -> Control

    public init(
        _ title: String,
        subtitle: String? = nil,
        @ViewBuilder control: @escaping () -> Control
    ) {
        self.title = title
        self.subtitle = subtitle
        self.control = control
    }

    public var body: some View {
        HStack(alignment: .center, spacing: Tokens.Settings.cellGap) {
            SettingsCellHead(title: title, subtitle: subtitle)
            // Никакого `fixedSize` на управлении: в узкой панели длинное
            // показание должно ужаться само, а не выдавить заголовок за край.
            // Кнопки и списки держат ширину своим содержимым.
            control()
                .frame(minHeight: Tokens.Settings.controlHeight)
        }
        .padding(.vertical, Tokens.Settings.cellVPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension SettingsCell where Control == EmptyView {
    /// Ячейка без управления — то, что настройки просто сообщают: какой движок
    /// расшифровывает, какая стоит версия. Строка остаётся строкой настроек, а
    /// не превращается в абзац посреди списка.
    public init(_ title: String, subtitle: String? = nil) {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }
}

/// Ячейка, у которой элемент управления стоит **под** заголовком: поле пути,
/// словарь, промпт. Всё, что шире реплики и не помещается в правый столбец.
public struct SettingsStack<Content: View>: View {
    private let title: String
    private let subtitle: String?
    @ViewBuilder private let content: () -> Content

    public init(
        _ title: String,
        subtitle: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Settings.stackGap) {
            SettingsCellHead(title: title, subtitle: subtitle)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, Tokens.Settings.cellVPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Заголовок ячейки и его тихая вторая строка — одна и та же пара в обоих видах.
struct SettingsCellHead: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Settings.cellLineGap) {
            Text(title)
                .typoBlock(Tokens.Settings.Typo.title)
                .foregroundStyle(Tokens.Settings.title)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle {
                Text(subtitle)
                    .typoBlock(Tokens.Settings.Typo.subtitle)
                    .foregroundStyle(Tokens.Settings.subtitle)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Controls

/// То, что настройка сообщает, а не спрашивает: версия, движок, объём на диске.
public struct SettingsValue: View {
    private let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .typo(Tokens.Settings.Typo.value)
            .foregroundStyle(Tokens.Settings.value)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(height: Tokens.Settings.controlHeight, alignment: .trailing)
    }
}

/// Галочка справа — «это уже сделано, трогать нечего».
///
/// Не плашка и не бейдж: по канону студии (PR-005) статус разводится с текстом
/// расстоянием и типографикой, а не рамкой. Стоит там же, где стояло бы
/// управление, потому что она его и заменяет.
public struct SettingsCheck: View {
    public init() {}

    public var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: Tokens.Settings.Typo.value.size, weight: .medium))
            .foregroundStyle(Tokens.Paint.Status.accent)
            .frame(height: Tokens.Settings.controlHeight)
            .accessibilityLabel("Подключено")
    }
}

/// Выключатель. Тот же, что на установочной плашке, — системный, потому что
/// системный выключатель в macOS человек узнаёт быстрее любого нарисованного.
public struct SettingsSwitch: View {
    @Binding private var isOn: Bool

    public init(isOn: Binding<Bool>) {
        self._isOn = isOn
    }

    public var body: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.regular)
            .tint(Tokens.Paint.Status.accent)
            .frame(height: Tokens.Settings.controlHeight)
    }
}

/// Кнопка настроек — пилюля установочной плашки. Никакой второй кнопочной
/// системы в приложении заводить не надо.
public struct SettingsButton: View {
    private let title: String
    private let enabled: Bool
    private let action: () -> Void

    @State private var hovering = false

    public init(_ title: String, enabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.enabled = enabled
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .typo(Tokens.Settings.Typo.button)
                .foregroundStyle(enabled ? Tokens.Settings.buttonLabel : Tokens.Paint.Text.disabled)
                .lineLimit(1)
                // Кнопку не сжимают: её ширина — её слово.
                .fixedSize()
                .padding(.horizontal, Tokens.Settings.buttonHPadding)
                .frame(height: Tokens.Settings.buttonHeight)
                .background(
                    hovering && enabled
                        ? Tokens.Settings.buttonHoverFill
                        : Tokens.Settings.buttonFill,
                    in: RoundedRectangle(cornerRadius: Tokens.Settings.buttonRadius, style: .continuous)
                )
                .contentShape(
                    RoundedRectangle(cornerRadius: Tokens.Settings.buttonRadius, style: .continuous)
                )
        }
        .buttonStyle(.press)
        .disabled(!enabled)
        .onHover { hovering = $0 && enabled }
        .animation(.easeOut(duration: Tokens.Motion.hover), value: hovering)
    }
}

/// Однострочное поле — путь, модель, ключ.
///
/// Своя рамка, а не `.roundedBorder`: системная рисуется белой плашкой с
/// системным скруглением и над стеклом читается как вырезанное окно.
public struct SettingsField: View {
    private let placeholder: String
    @Binding private var text: String
    private let isSecure: Bool

    public init(_ placeholder: String, text: Binding<String>, secure: Bool = false) {
        self.placeholder = placeholder
        self._text = text
        self.isSecure = secure
    }

    public var body: some View {
        field
            .textFieldStyle(.plain)
            .typo(Tokens.Settings.Typo.field)
            .foregroundStyle(Tokens.Settings.title)
            .lineLimit(1)
            .padding(.horizontal, Tokens.Settings.fieldHPadding)
            .frame(height: Tokens.Settings.fieldHeight)
            .background(
                Tokens.Settings.fieldFill,
                in: RoundedRectangle(cornerRadius: Tokens.Settings.fieldRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.Settings.fieldRadius, style: .continuous)
                    .strokeBorder(Tokens.Settings.fieldBorder, lineWidth: 0.5)
            }
    }

    @ViewBuilder
    private var field: some View {
        if isSecure {
            SecureField(placeholder, text: $text)
        } else {
            TextField(placeholder, text: $text)
        }
    }
}

/// Готовая команда: показать и дать скопировать.
///
/// Поле, а не строка текста, потому что содержимое чужое — его вставляют в
/// терминал целиком, и оправа говорит «это не абзац, это значение». Читать его
/// не обязательно: команда длиннее поля и обрезается, а целиком уезжает в буфер
/// по кнопке. Обрезается **с хвоста** — начало (`claude mcp add`) отвечает на
/// «что это», конец лишь повторяет путь, который человек и так знает.
///
/// Правки не принимает намеренно: менять в ней нечего, а курсор в поле обещал
/// бы обратное.
public struct SettingsCommand: View {
    private let command: String
    private let onCopy: () -> Void

    /// Живёт полторы секунды после нажатия. Единственный ответ на «скопировалось
    /// ли»: буфер обмена ничего не показывает сам, а без ответа человек жмёт
    /// второй раз и не знает, стало ли лучше.
    @State private var copied = false
    @State private var hovering = false

    public init(_ command: String, onCopy: @escaping () -> Void) {
        self.command = command
        self.onCopy = onCopy
    }

    public var body: some View {
        HStack(spacing: Tokens.Settings.commandGlyphGap) {
            Text(command)
                .typo(Tokens.Settings.Typo.field)
                .foregroundStyle(Tokens.Settings.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: copy) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: Tokens.Settings.commandGlyphSize, weight: .regular))
                    .foregroundStyle(
                        copied ? Tokens.Settings.commandCopied : Tokens.Settings.buttonLabel
                    )
                    .frame(width: Tokens.Space.s16, height: Tokens.Space.s16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.press)
            .accessibilityLabel("Скопировать команду")
        }
        .padding(.horizontal, Tokens.Settings.fieldHPadding)
        .frame(width: Tokens.Settings.commandWidth, height: Tokens.Settings.fieldHeight)
        .background(
            Tokens.Settings.fieldFill,
            in: RoundedRectangle(cornerRadius: Tokens.Settings.fieldRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Settings.fieldRadius, style: .continuous)
                .strokeBorder(
                    hovering ? Tokens.Settings.buttonHoverFill : Tokens.Settings.fieldBorder,
                    lineWidth: 0.5
                )
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.Motion.hover), value: copied)
    }

    private func copy() {
        onCopy()
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}

/// Многострочное поле — промпт. Та же оправа, что у однострочного.
public struct SettingsEditor: View {
    @Binding private var text: String

    public init(text: Binding<String>) {
        self._text = text
    }

    public var body: some View {
        TextEditor(text: $text)
            .scrollContentBackground(.hidden)
            .typo(Tokens.Settings.Typo.field)
            .foregroundStyle(Tokens.Settings.title)
            .padding(.horizontal, Tokens.Settings.fieldHPadding - Tokens.Space.s4)
            .padding(.vertical, Tokens.Space.s6)
            .frame(height: Tokens.Settings.editorHeight)
            .background(
                Tokens.Settings.fieldFill,
                in: RoundedRectangle(cornerRadius: Tokens.Settings.fieldRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.Settings.fieldRadius, style: .continuous)
                    .strokeBorder(Tokens.Settings.fieldBorder, lineWidth: 0.5)
            }
    }
}

import SwiftUI
import AppKit

/// # Чем настройку настраивают — правый слот ячейки
///
/// Десять контролов одной высоты (`Tokens.Settings.controlHeight`). Высота
/// общая не для красоты: строки настроек стоят друг под другом, и контрол на
/// две точки выше соседнего шатает всю карточку.
///
/// Живут отдельно от `SettingsKit` намеренно — тот про то, как страница
/// устроена, а это про то, чем её трогают. Второе понадобится и вне настроек.

// MARK: - Выключатель

/// 40 × 24 с бегунком 20 — Figma 254:1998.
///
/// Свой, а не системный `Toggle(.switch)`: системный на macOS 26 рисуется своей
/// высотой и своим радиусом, и в ряду с полем 32 pt он стоял на другой линии.
public struct SettingsSwitch: View {
    @Binding private var isOn: Bool
    private let isEnabled: Bool

    public init(isOn: Binding<Bool>, enabled: Bool = true) {
        self._isOn = isOn
        self.isEnabled = enabled
    }

    public var body: some View {
        Button {
            isOn.toggle()
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                RoundedRectangle(cornerRadius: Tokens.Settings.Switch.radius, style: .continuous)
                    .fill(isOn ? Tokens.Settings.Switch.onFill : Tokens.Settings.Switch.offFill)
                Circle()
                    .fill(Tokens.Settings.Switch.knobFill)
                    .frame(
                        width: Tokens.Settings.Switch.knob,
                        height: Tokens.Settings.Switch.knob
                    )
                    .padding(Tokens.Settings.Switch.padding)
            }
            .frame(width: Tokens.Settings.Switch.width, height: Tokens.Settings.Switch.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .animation(.easeOut(duration: Tokens.Motion.hover), value: isOn)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

// MARK: - Выбор из нескольких

/// Кнопка с шевроном, за которой список — Figma 254:1949.
///
/// Список системный (`Menu`), а не нарисованный по макету. Осознанно: у
/// системного есть клавиатура, поиск набором, правильное место на краю экрана и
/// вся доступность, а отличается он от макета скруглением и шириной. Нарисовать
/// его — значит написать всё это заново и потерять половину. Триггер при этом
/// ровно из макета, и видно как раз его.
public struct SettingsMenu<Value: Hashable>: View {
    public struct Option: Identifiable {
        public let value: Value
        public let title: String
        public var id: Value { value }

        public init(_ value: Value, _ title: String) {
            self.value = value
            self.title = title
        }
    }

    @Binding private var selection: Value
    private let options: [Option]

    public init(selection: Binding<Value>, options: [Option]) {
        self._selection = selection
        self.options = options
    }

    private var currentTitle: String {
        options.first { $0.value == selection }?.title ?? ""
    }

    public var body: some View {
        Menu {
            ForEach(options) { option in
                Button {
                    selection = option.value
                } label: {
                    // Галочка своя: `Picker` внутри `Menu` рисует её сам, но
                    // тогда заголовок кнопки перестаёт быть нашим.
                    if option.value == selection {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            HStack(spacing: Tokens.Settings.controlGap) {
                Text(currentTitle)
                    .foregroundStyle(Tokens.Settings.value)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: Tokens.Settings.Typo.control.size, weight: .regular))
                    .foregroundStyle(Tokens.Settings.controlHint)
            }
            .typo(Tokens.Settings.Typo.control)
            .padding(.horizontal, Tokens.Settings.controlHPadding)
            .frame(height: Tokens.Settings.controlHeight)
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.Settings.controlRadius, style: .continuous)
                    .stroke(Tokens.Settings.fieldBorder, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        // `.borderlessButton` перерисовывает ярлык по-своему: съедает отступы и
        // ставит свою стрелку слева от текста. `.button` + `.plain` отдаёт
        // ярлык нам целиком, а список оставляет системным.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: - Поля

/// Обычное поле правого слота — Figma 254:1931.
///
/// Крестик появляется, только когда есть что стирать: пустое поле с крестиком
/// предлагает действие, которое ничего не сделает.
public struct SettingsField: View {
    private let placeholder: String
    @Binding private var text: String
    private let secure: Bool
    private let width: CGFloat?

    @FocusState private var focused: Bool

    public init(
        _ placeholder: String,
        text: Binding<String>,
        secure: Bool = false,
        width: CGFloat? = nil
    ) {
        self.placeholder = placeholder
        self._text = text
        self.secure = secure
        self.width = width
    }

    public var body: some View {
        HStack(spacing: Tokens.Settings.controlGap) {
            Group {
                if secure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.plain)
            .focused($focused)
            .typo(Tokens.Settings.Typo.control)
            .foregroundStyle(Tokens.Settings.value)
            .frame(maxWidth: .infinity, alignment: .leading)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: Tokens.Settings.Typo.control.size, weight: .regular))
                        .foregroundStyle(Tokens.Settings.controlHint)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.press)
                .accessibilityLabel("Очистить")
            }
        }
        .padding(.horizontal, Tokens.Settings.controlHPadding)
        .frame(width: width ?? Tokens.Settings.fieldWidth, height: Tokens.Settings.controlHeight)
        .background(
            Tokens.Settings.fieldFill,
            in: RoundedRectangle(cornerRadius: Tokens.Settings.controlRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Settings.controlRadius, style: .continuous)
                .stroke(Tokens.Settings.fieldBorder, lineWidth: 1)
        )
        .onTapGesture { focused = true }
    }
}

/// Готовая команда и кнопка «скопировать» — Figma 254:3023.
///
/// Только для чтения: набирать её руками незачем, а поправить в ней можно
/// только сломать.
public struct SettingsCommandField: View {
    private let command: String
    private let onCopy: () -> Void

    @State private var copied = false

    public init(_ command: String, onCopy: @escaping () -> Void) {
        self.command = command
        self.onCopy = onCopy
    }

    public var body: some View {
        HStack(spacing: Tokens.Settings.controlGap) {
            Text(command)
                .typo(Tokens.Settings.Typo.control)
                .foregroundStyle(Tokens.Settings.controlHint)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                onCopy()
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.confirmSeconds) {
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: Tokens.Settings.Typo.control.size, weight: .regular))
                    .foregroundStyle(copied ? Tokens.Settings.buttonAccentFill : Tokens.Settings.controlHint)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.press)
            .accessibilityLabel("Скопировать команду")
        }
        .padding(.horizontal, Tokens.Settings.controlHPadding)
        .frame(width: Tokens.Settings.fieldWidth, height: Tokens.Settings.controlHeight)
        .background(
            Tokens.Settings.fieldFill,
            in: RoundedRectangle(cornerRadius: Tokens.Settings.controlRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Settings.controlRadius, style: .continuous)
                .stroke(Tokens.Settings.fieldBorder, lineWidth: 1)
        )
        .help(command)
    }

    /// Полторы секунды: достаточно, чтобы галочку заметили, мало, чтобы принять
    /// её за состояние строки.
    private static let confirmSeconds: Double = 1.5
}

// MARK: - Кнопки и отметки

/// Кнопка правого слота — Figma 254:2156.
public struct SettingsButton: View {
    private let title: String
    private let symbol: String?
    private let role: Role
    private let enabled: Bool
    private let action: () -> Void

    @State private var hovering = false

    public enum Role { case normal, prominent, destructive }

    public init(
        _ title: String,
        symbol: String? = nil,
        role: Role = .normal,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.symbol = symbol
        self.role = role
        self.enabled = enabled
        self.action = action
    }

    private var label: Color {
        switch role {
        case .normal:      return Tokens.Settings.buttonLabel
        case .prominent:   return Tokens.Settings.buttonAccentLabel
        case .destructive: return Tokens.Settings.destructive
        }
    }

    private var fill: Color {
        switch role {
        case .prominent: return Tokens.Settings.buttonAccentFill
        case .normal, .destructive:
            return hovering ? Tokens.Settings.buttonHoverFill : Tokens.Settings.buttonFill
        }
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: Tokens.Settings.Tag.hPadding) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: Tokens.Settings.Typo.control.size, weight: .regular))
                }
                Text(title)
            }
            .typo(Tokens.Settings.Typo.control)
            .foregroundStyle(label)
            // Кнопка с иконкой поджата: у неё внутри уже есть воздух между
            // глифом и словом (`p-[8px] gap-[6px]`, 284:16769).
            .padding(.horizontal, symbol == nil
                ? Tokens.Settings.controlHPadding
                : Tokens.Settings.Tag.hPadding + Tokens.Space.s2)
            .frame(height: Tokens.Settings.controlHeight)
            .background(
                fill,
                in: RoundedRectangle(cornerRadius: Tokens.Settings.controlRadius, style: .continuous)
            )
            .opacity(role == .prominent && hovering ? 0.85 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.press)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.Motion.hover), value: hovering)
        .fixedSize()
    }
}

/// «Сделано» — Figma 254:3048. Тихая: акцент принадлежит несделанному.
public struct SettingsCheck: View {
    public init() {}

    public var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: Tokens.Settings.Typo.title.size, weight: .regular))
            .foregroundStyle(Tokens.Settings.check)
            .frame(height: Tokens.Settings.controlHeight)
            .accessibilityLabel("Подключено")
    }
}

/// То, что настройка сообщает, а не спрашивает: версия, объём.
public struct SettingsValue: View {
    private let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .typo(Tokens.Settings.Typo.control)
            .foregroundStyle(Tokens.Settings.controlHint)
            .frame(height: Tokens.Settings.controlHeight)
    }
}

// MARK: - Теги

/// Личный словарь — Figma 254:2171.
///
/// Слова, а не строка через запятую. Строка была одним полем, в котором нельзя
/// увидеть, где кончается одно слово и начинается другое, и нельзя убрать одно
/// не перечитав все.
public struct SettingsTagField: View {
    private let tags: [String]
    private let addTitle: String
    private let onRemove: (String) -> Void
    private let onAdd: (String) -> Void

    @State private var adding = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    public init(
        tags: [String],
        addTitle: String = "Добавить",
        onRemove: @escaping (String) -> Void,
        onAdd: @escaping (String) -> Void
    ) {
        self.tags = tags
        self.addTitle = addTitle
        self.onRemove = onRemove
        self.onAdd = onAdd
    }

    public var body: some View {
        FlowLayout(spacing: Tokens.Settings.Tag.listGap, lineSpacing: Tokens.Settings.Tag.listGap) {
            ForEach(tags, id: \.self) { tag in
                tagChip(tag)
            }
            if adding {
                draftChip
            } else {
                addChip
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tagChip(_ tag: String) -> some View {
        HStack(spacing: Tokens.Settings.Tag.gap) {
            Text(tag)
                .foregroundStyle(Tokens.Settings.title)
            Button {
                onRemove(tag)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: Tokens.Settings.Typo.control.size, weight: .regular))
                    .foregroundStyle(Tokens.Settings.controlHint)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.press)
            .accessibilityLabel("Убрать «\(tag)»")
        }
        .typo(Tokens.Settings.Typo.control)
        .padding(.horizontal, Tokens.Settings.Tag.hPadding)
        .frame(height: Tokens.Settings.Tag.height)
        .background(
            Tokens.Settings.Tag.fill,
            in: RoundedRectangle(cornerRadius: Tokens.Settings.Tag.radius, style: .continuous)
        )
    }

    private var addChip: some View {
        Button {
            adding = true
            focused = true
        } label: {
            HStack(spacing: Tokens.Settings.Tag.gap) {
                Image(systemName: "plus")
                    .font(.system(size: Tokens.Settings.Typo.control.size, weight: .regular))
                Text(addTitle)
            }
            .typo(Tokens.Settings.Typo.control)
            .foregroundStyle(Tokens.Settings.controlHint)
            .padding(.horizontal, Tokens.Settings.Tag.hPadding)
            .frame(height: Tokens.Settings.Tag.height)
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.Settings.Tag.radius, style: .continuous)
                    .stroke(Tokens.Settings.Tag.addBorder, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.press)
    }

    private var draftChip: some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .focused($focused)
            .typo(Tokens.Settings.Typo.control)
            .foregroundStyle(Tokens.Settings.title)
            .frame(width: Tokens.Settings.fieldWidth / 2, height: Tokens.Settings.Tag.height)
            .padding(.horizontal, Tokens.Settings.Tag.hPadding)
            .background(
                Tokens.Settings.Tag.fill,
                in: RoundedRectangle(cornerRadius: Tokens.Settings.Tag.radius, style: .continuous)
            )
            .onSubmit(commit)
            // Уход фокуса — тоже подтверждение: слово, набранное и оставленное,
            // человек считает добавленным.
            .onChange(of: focused) { _, hasFocus in
                if !hasFocus { commit() }
            }
    }

    private func commit() {
        let word = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        adding = false
        guard !word.isEmpty else { return }
        onAdd(word)
    }
}

// MARK: - Длинный текст

/// Промпт — Figma 254:2213. Во всю ширину карточки, без рамки: это документ, а
/// не значение, и рамка вокруг документа делает его полем ввода на 80 pt.
public struct SettingsEditor: View {
    @Binding private var text: String

    public init(text: Binding<String>) {
        self._text = text
    }

    public var body: some View {
        TextEditor(text: $text)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .typoBlock(Tokens.Settings.Typo.body)
            .foregroundStyle(Tokens.Settings.title)
            .frame(minHeight: Tokens.Settings.Typo.body.lineHeight)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

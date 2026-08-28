import SwiftUI
import AppKit

/// # Из чего собран экран настроек — Figma `settings` (254:3399)
///
/// Чистая вёрстка и ничего больше: ни `AppState`, ни `Preferences`, ни
/// `UserDefaults`. Всё, что здесь есть, — заголовок, карточка, ячейка и то, чем
/// ячейку настраивают. Содержимое живёт в `Sources/Settings/`.
///
/// Числовых литералов здесь нет вовсе, кроме строк: всё в `Tokens.Settings`.
///
/// # Словарь
///
/// ```
/// SettingsPage("Основные") {
///     SettingsCard {
///         SettingsCell("Ваше имя", subtitle: "Для подписи в саммари") {
///             SettingsField("Константин", text: $name)
///         }
///     }
///     SettingsGroup("Запуск") {
///         SettingsCell("Запускать при входе") { SettingsSwitch(isOn: $login) }
///     }
/// }
/// ```
///
/// Одно правило устройства: **ячейки приходят списком, а не деревом вьюх**
/// (`SettingsRows`). Разделитель обязан стоять *между* ячейками, а не после
/// каждой, и `if` в списке обязан давать ноль строк, а не пустую строку с
/// разделителем вокруг неё. Дерево `ViewBuilder` этого не умеет — оно отдаёт
/// один непрозрачный `View`, у которого не спросишь, сколько в нём детей.

// MARK: - Страница

/// Страница правой панели: заголовок и всё, что под ним.
///
/// Заведена не ради обобщения — ради того, чтобы второй такой экран не завёл
/// вторых отступов. Раздел «Проекты» стоит в той же колонке, с тем же полем 36,
/// тем же 28 сверху и тем же заголовком 17 / 24; разъехаться им можно только
/// молча, и только если чисел два комплекта.
public struct PanePage<Content: View>: View {
    private let title: String
    private let titleGap: CGFloat
    private let content: () -> Content

    /// `titleGap` — расстояние от заголовка до содержимого. У настроек это общий
    /// шаг страницы (20); у проекта заголовок и описание под ним — одна мысль в
    /// два голоса, и макет ставит их на 10 (256:7646 → 256:7029).
    public init(
        _ title: String,
        titleGap: CGFloat = Tokens.Settings.blockGap,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.titleGap = titleGap
        self.content = content
    }

    public var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: titleGap) {
                // Только заголовок. Правый слот здесь был — в нём стояло меню
                // проекта (256:7648); снят 2026-08-28: действия над открытой
                // сущностью живут в полосе над панелью, одним местом на все
                // маршруты, а два места для одного меню и были той самой
                // неразберихой наверху.
                Text(title)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .typo(Tokens.Settings.Typo.page)
                    .foregroundStyle(Tokens.Settings.title)
                    // Высота названа, а не выведена из шрифта. Макет даёт
                    // заголовку бокс 24 (254:1413); `typoBlock` на этом кегле
                    // отдаёт 23 — `renderedLineHeight` считает по потолкам
                    // асцендера и десцендера отдельно и на 17 pt промахивается
                    // на точку. Замерено, не оценено: тест стилей.
                    .frame(height: Tokens.Settings.Typo.page.lineHeight, alignment: .leading)
                content()
            }
            // Потолок стоит на **содержимом**, а поля снаружи него. Если
            // накрыть потолком уже отступленный блок, то на ширине макета (649)
            // 640 меньше 649 — потолок срабатывает, блок центрируется, и
            // карточка садится на 40.5 вместо 36. Проверено пиксельно.
            //
            // Число саммарийное, и это не совпадение: настройки и саммари —
            // одна и та же колонка панели с разным содержимым.
            .frame(maxWidth: Tokens.Settings.maxWidth, alignment: .leading)
            .padding(.horizontal, Tokens.Settings.pageHPadding)
            .padding(.vertical, Tokens.Settings.pageVPadding)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// Раздел настроек целиком. Имя оставлено: на него ссылается словарь в шапке
/// файла и семь страниц в `Sources/Settings/`.
public struct SettingsPage<Content: View>: View {
    private let title: String
    private let content: () -> Content

    public init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    public var body: some View {
        PanePage(title) { content() }
    }
}

// MARK: - Группа и карточка

/// Тихий заголовок над карточкой, с необязательным действием справа.
///
/// Действие — то, что относится ко всей группе и ни к одной её строке
/// («Вернуть как было» у промпта, 254:2253). Строчного действия здесь не
/// бывает: у строки для этого есть правый слот.
public struct SettingsGroupTitle: View {
    private let title: String
    private let actionTitle: String?
    private let actionSymbol: String?
    private let action: (() -> Void)?

    public init(
        _ title: String,
        actionTitle: String? = nil,
        actionSymbol: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.actionTitle = actionTitle
        self.actionSymbol = actionSymbol
        self.action = action
    }

    public var body: some View {
        HStack(spacing: Tokens.Settings.cellGap) {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle, let action {
                Button(action: action) {
                    HStack(spacing: Tokens.Settings.Tag.gap) {
                        Text(actionTitle)
                        if let actionSymbol {
                            Image(systemName: actionSymbol)
                                .font(.system(size: Tokens.Settings.Typo.header.size, weight: .regular))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.press)
            }
        }
        .typo(Tokens.Settings.Typo.header)
        .foregroundStyle(Tokens.Settings.header)
        .padding(.horizontal, Tokens.Settings.headerLeadingInset)
    }
}

/// Карточка: ячейки и волосяные линии между ними.
public struct SettingsCard: View {
    private let rows: [AnyView]
    private let hPadding: CGFloat

    public init(@SettingsRows rows: () -> [AnyView]) {
        self.rows = rows()
        self.hPadding = Tokens.Settings.cardHPadding
    }

    /// Для тех, у кого список уже собран — `SettingsGroup` ниже, и списки на
    /// экране проекта. `hPadding` у последних свой: у списка встреч макет даёт
    /// 16 (256:8831), у списка людей — 14 (256:7570), потому что слева там
    /// стоит кружок и поле считается от него.
    public init(hPadding: CGFloat = Tokens.Settings.cardHPadding, rows: [AnyView]) {
        self.rows = rows
        self.hPadding = hPadding
    }

    public var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 { SettingsDivider() }
                row
            }
        }
        .padding(.horizontal, hPadding)
        .padding(.vertical, Tokens.Settings.cardVPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Tokens.Settings.cardFill,
            in: RoundedRectangle(cornerRadius: Tokens.Settings.cardRadius, style: .continuous)
        )
    }
}

/// Заголовок группы и её карточка одним блоком — так они и стоят везде.
public struct SettingsGroup: View {
    private let title: String
    private let actionTitle: String?
    private let actionSymbol: String?
    private let action: (() -> Void)?
    private let rows: [AnyView]

    public init(
        _ title: String,
        actionTitle: String? = nil,
        actionSymbol: String? = nil,
        action: (() -> Void)? = nil,
        @SettingsRows rows: () -> [AnyView]
    ) {
        self.title = title
        self.actionTitle = actionTitle
        self.actionSymbol = actionSymbol
        self.action = action
        self.rows = rows()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Settings.headerBottomGap) {
            SettingsGroupTitle(
                title, actionTitle: actionTitle, actionSymbol: actionSymbol, action: action
            )
            SettingsCard(rows: rows)
        }
    }
}

@resultBuilder
public enum SettingsRows {
    public static func buildExpression<V: View>(_ view: V) -> [AnyView] { [AnyView(view)] }
    public static func buildBlock(_ parts: [AnyView]...) -> [AnyView] { parts.flatMap { $0 } }
    public static func buildOptional(_ part: [AnyView]?) -> [AnyView] { part ?? [] }
    public static func buildEither(first: [AnyView]) -> [AnyView] { first }
    public static func buildEither(second: [AnyView]) -> [AnyView] { second }
    public static func buildArray(_ parts: [[AnyView]]) -> [AnyView] { parts.flatMap { $0 } }
}

struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(Tokens.Settings.divider)
            // Честная точка, а не волосок. В рельсе граница — 0.5 (там линия
            // отделяет две поверхности, и волоска хватает); здесь линия делит
            // строки внутри одной карточки, макет даёт ей `h-px` (254:1935), и
            // на волоске карточка читалась сплошным полем. Решение владельца
            // 2026-08-26.
            .frame(height: Tokens.Settings.dividerHeight)
            .frame(maxWidth: .infinity)
    }
}

// MARK: - Ячейка

/// Что настраивается — слева, чем настраивают — справа.
public struct SettingsCell<Control: View>: View {
    private let title: String
    private let subtitle: String?
    private let tone: SettingsSubtitleTone
    private let control: () -> Control

    public init(
        _ title: String,
        subtitle: String? = nil,
        tone: SettingsSubtitleTone = .help,
        @ViewBuilder control: @escaping () -> Control
    ) {
        self.title = title
        self.subtitle = subtitle
        self.tone = tone
        self.control = control
    }

    public var body: some View {
        HStack(spacing: Tokens.Settings.cellGap) {
            SettingsCellHead(title: title, subtitle: subtitle, tone: tone)
                .frame(maxWidth: .infinity, alignment: .leading)
            // Контрол не растягиваем: правый край карточки держат сами контролы,
            // а они одной высоты и своей ширины.
            control()
        }
        .padding(.vertical, Tokens.Settings.cellVPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension SettingsCell where Control == EmptyView {
    public init(_ title: String, subtitle: String? = nil, tone: SettingsSubtitleTone = .help) {
        self.init(title, subtitle: subtitle, tone: tone) { EmptyView() }
    }
}

/// Ячейка, у которой содержимое стоит **под** заголовком, а не справа: промпт,
/// теги словаря. Правого слота у неё нет — там нечему уместиться.
public struct SettingsWideCell<Content: View>: View {
    private let title: String
    private let subtitle: String?
    private let tone: SettingsSubtitleTone
    private let content: () -> Content

    public init(
        _ title: String,
        subtitle: String? = nil,
        tone: SettingsSubtitleTone = .help,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.tone = tone
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Settings.stackGap) {
            if !title.isEmpty || subtitle != nil {
                SettingsCellHead(title: title, subtitle: subtitle, tone: tone)
            }
            content()
        }
        .padding(.vertical, Tokens.Settings.cellVPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Род второй строки. Пять смыслов, и до 2026-08-20 все пять красились одним
/// цветом — поэтому «Не запущен» читалось как справка, то есть отказ прятался
/// ровно там, где его ищут (`design/settings.md` §5.9).
public enum SettingsSubtitleTone: Equatable, Sendable {
    /// Пояснение: зачем это и что изменится.
    case help
    /// Значение: путь, объём, версия. Одна строка, обрезка серединой.
    case value
    /// Идёт работа: качается модель, проверяем сервис.
    case progress
    /// Переживаемый отказ: разрешения нет, сервис не отвечает.
    case warning
    /// Отказ системы: не получилось то, что мы сами делали.
    case failure

    var color: Color {
        switch self {
        case .help:     return Tokens.Settings.subtitle
        case .value:    return Tokens.Settings.subtitleValue
        case .progress: return Tokens.Settings.subtitleProgress
        case .warning:  return Tokens.Settings.subtitleWarning
        case .failure:  return Tokens.Settings.subtitleFailure
        }
    }

    /// Путь обязан остаться одной строкой: развернувшись на три, он делает
    /// ячейку выше всех остальных и перестаёт читаться как значение.
    var singleLine: Bool { self == .value }
}

struct SettingsCellHead: View {
    let title: String
    let subtitle: String?
    let tone: SettingsSubtitleTone

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Settings.cellLineGap) {
            if !title.isEmpty {
                Text(title)
                    .typoBlock(Tokens.Settings.Typo.title)
                    .foregroundStyle(Tokens.Settings.title)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .typoBlock(Tokens.Settings.Typo.subtitle)
                    .foregroundStyle(tone.color)
                    .lineLimit(tone.singleLine ? 1 : nil)
                    .truncationMode(tone.singleLine ? .middle : .tail)
                    .fixedSize(horizontal: false, vertical: !tone.singleLine)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

import SwiftUI
import AppKit

/// Two control sizes across the whole app: sm = 32, md = 36.
public enum DSSize {
    case sm, md
    public var dim: CGFloat { self == .sm ? 32 : 36 }
}

/// Four prominence levels shared by pill and icon buttons. Each resolves a fill
/// and a foreground for the current hover state.
/// - primary / secondary / ghost: semantic interactive fills.
/// - minimal: never fills — content only brightens (Propeller-specific).
public enum ButtonProminence {
    case primary, secondary, ghost, minimal

    public func fill(hovering: Bool) -> Color {
        switch self {
        case .primary:   return hovering ? Tokens.Paint.Interactive.Primary.hover : Tokens.Paint.Interactive.Primary.rest
        case .secondary: return hovering ? Tokens.Paint.Interactive.Secondary.hover : Tokens.Paint.Interactive.Secondary.rest
        case .ghost:     return hovering ? Tokens.Paint.Interactive.Ghost.hover : Tokens.Paint.Interactive.Ghost.rest
        case .minimal:   return .clear
        }
    }

    public func foreground(hovering: Bool) -> Color {
        switch self {
        case .primary:   return Tokens.Paint.Text.primaryInverse
        case .secondary: return Tokens.Paint.Text.primary
        case .ghost:     return hovering ? Tokens.Paint.Text.secondary : Tokens.Paint.Text.tertiary
        case .minimal:   return hovering
            ? Tokens.Paint.Interactive.Minimal.hover
            : Tokens.Paint.Interactive.Minimal.rest
        }
    }

    public var disabledForeground: Color {
        switch self {
        case .primary, .secondary, .ghost:
            return Tokens.Paint.Text.disabled
        case .minimal:
            return Tokens.Paint.Interactive.Minimal.disabled
        }
    }
}

/// Кнопка отвечает пальцу раньше, чем на нажатие успевает ответить приложение.
///
/// До этого стиля единственным откликом на нажатие была подсветка наведения,
/// которая к моменту нажатия уже горит: клик по «Сгенерировать» и клик мимо неё
/// выглядели одинаково, пока не приходил результат, — а он приходит не всегда и
/// не сразу. Просадка на 4 % говорит «нажалось» в тот же кадр и ничего не
/// обещает про то, что будет дальше.
///
/// Уходит быстрее, чем возвращается. Палец уже знает, что нажал, и ждать
/// подтверждения ему незачем; а вот возврат в покой на скорости нажатия
/// читается как отскок.
public struct PressStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? Tokens.Motion.pressScale : 1)
            .animation(
                .easeOut(
                    duration: configuration.isPressed
                        ? Tokens.Motion.press
                        : Tokens.Motion.release
                ),
                value: configuration.isPressed
            )
    }
}

/// Кнопка, которая на нажатие не отвечает ничем.
///
/// `.plain` — не «никакого оформления»: на macOS он приглушает ярлык, пока
/// кнопка нажата. Строке встречи это лишнее. В ней и так три чернила и заливка,
/// которые меняются от наведения, выделения и стадии конвейера, — четвёртая
/// перекраска, живущая доли секунды, читается как рябь, а не как ответ.
/// Подтверждение нажатия там даёт не строка, а панель, которая меняется.
public struct QuietStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

extension ButtonStyle where Self == QuietStyle {
    /// `.buttonStyle(.quiet)` — для строк списка. Мишени-действия берут
    /// `.press`.
    public static var quiet: QuietStyle { QuietStyle() }
}

extension ButtonStyle where Self == PressStyle {
    /// `.buttonStyle(.press)` — то же «ничего не рисует», что и `.plain`, плюс
    /// отклик на нажатие. Для мишеней-действий; строки списка его не берут —
    /// см. `SidebarMeetingRow`.
    public static var press: PressStyle { PressStyle() }
}

/// Square icon button (always 1:1, circular). Shares the four prominences and two
/// sizes. Default is the ghost language (back chevron); pass `.minimal` for the
/// quietest icons. The app-wide primitive for iconic actions.
public struct IconButton: View {
    let systemName: String
    var prominence: ButtonProminence = .ghost
    var size: DSSize = .sm
    var iconSize: CGFloat = 15
    var weight: Font.Weight = .regular
    var enabled: Bool = true
    var action: () -> Void

    @State private var hovering = false

    public init(
        systemName: String,
        prominence: ButtonProminence = .ghost,
        size: DSSize = .sm,
        iconSize: CGFloat = 15,
        weight: Font.Weight = .regular,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.systemName = systemName
        self.prominence = prominence
        self.size = size
        self.iconSize = iconSize
        self.weight = weight
        self.enabled = enabled
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: iconSize, weight: weight))
                .foregroundStyle(
                    enabled
                        ? prominence.foreground(hovering: hovering)
                        : prominence.disabledForeground
                )
                .frame(width: size.dim, height: size.dim)
                .background(
                    enabled ? prominence.fill(hovering: hovering) : .clear,
                    in: Circle()
                )
                .contentShape(Circle())
        }
        .buttonStyle(.press)
        .disabled(!enabled)
        .onHover { if enabled { hovering = $0 } else { hovering = false } }
        .animation(.easeOut(duration: Tokens.Motion.hover), value: hovering)
    }
}

/// Icon-only chrome for `Menu` labels (no nested `Button`).
/// Same opacity ramp as `ButtonProminence.minimal`.
public struct MinimalIconGlyph: View {
    let systemName: String
    var iconSize: CGFloat = 15
    var weight: Font.Weight = .regular
    /// When true, stay at the brighter end (e.g. active filter).
    var emphasized: Bool = false

    @State private var hovering = false

    public init(
        systemName: String,
        iconSize: CGFloat = 15,
        weight: Font.Weight = .regular,
        emphasized: Bool = false
    ) {
        self.systemName = systemName
        self.iconSize = iconSize
        self.weight = weight
        self.emphasized = emphasized
    }

    public var body: some View {
        Image(systemName: systemName)
            .font(.system(size: iconSize, weight: weight))
            .foregroundStyle(
                ButtonProminence.minimal.foreground(hovering: hovering || emphasized)
            )
            .frame(width: DSSize.sm.dim, height: DSSize.sm.dim)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: Tokens.Motion.hover), value: hovering)
    }
}

/// `Menu` recolors its label with the accent unless `.tint` is locked to the
/// minimal ramp — use this instead of hand-rolled `Menu { } label: { Image… }`.
public struct MinimalIconMenu<Content: View>: View {
    let systemName: String
    var iconSize: CGFloat = 15
    var weight: Font.Weight = .regular
    var emphasized: Bool = false
    var helpText: String? = nil
    @ViewBuilder var menuContent: () -> Content

    @State private var hovering = false

    public init(
        systemName: String,
        iconSize: CGFloat = 15,
        weight: Font.Weight = .regular,
        emphasized: Bool = false,
        help helpText: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.systemName = systemName
        self.iconSize = iconSize
        self.weight = weight
        self.emphasized = emphasized
        self.helpText = helpText
        self.menuContent = content
    }

    public var body: some View {
        Menu(content: menuContent) {
            MinimalIconGlyph(
                systemName: systemName,
                iconSize: iconSize,
                weight: weight,
                emphasized: emphasized || hovering
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(ButtonProminence.minimal.foreground(hovering: hovering || emphasized))
        .frame(width: DSSize.sm.dim, height: DSSize.sm.dim)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.Motion.hover), value: hovering)
        .modifier(OptionalHelp(helpText))
    }
}

// `MinimalIconSettingsLink` — a `SettingsLink` in the minimal ramp — lived here
// until the Settings scene was removed (2026-08-07). Settings are a state of
// the content pane now, so the gear is an ordinary `IconButton`.

private struct OptionalHelp: ViewModifier {
    let text: String?
    init(_ text: String?) { self.text = text }
    func body(content: Content) -> some View {
        if let text { content.help(text) } else { content }
    }
}

/// Shared fill — main window + onboarding. Same stack everywhere:
/// `.thickMaterial` + `Tokens.Glass.fill`. Menu-bar: `tinted: false`.
public struct GlassBackground: View {
    public var material: Material = .thickMaterial
    public var cornerRadius: CGFloat? = nil
    public var tinted: Bool = true
    /// Чем подкрашено стекло. По умолчанию — окном, то есть почти чёрным:
    /// фону положено уходить. Вызванный инструмент передаёт свой
    /// (`Tokens.Glass.summonedFill`) и уходить отказывается.
    public var wash: NSColor = Tokens.Glass.fill

    public init(
        material: Material = .thickMaterial,
        cornerRadius: CGFloat? = nil,
        tinted: Bool = true,
        wash: NSColor = Tokens.Glass.fill
    ) {
        self.material = material
        self.cornerRadius = cornerRadius
        self.tinted = tinted
        self.wash = wash
    }

    public var body: some View {
        ZStack {
            Rectangle().fill(material)
            if tinted {
                Rectangle().fill(Color(nsColor: wash))
            }
        }
    }
}

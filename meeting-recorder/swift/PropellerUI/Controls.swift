import SwiftUI
import AppKit

/// Two control sizes across the whole app: sm = 32, md = 36.
public enum DSSize {
    case sm, md
    public var dim: CGFloat { self == .sm ? 32 : 36 }
}

/// Four prominence levels shared by pill and icon buttons. Each resolves a fill
/// and a foreground for the current hover state.
/// - primary: white fill, black text; dims slightly on hover.
/// - secondary: white-10% fill, white text; lightens to 15%.
/// - ghost: transparent; text 30→70% and a 7% fill appear on hover.
/// - minimal: transparent, never fills; icon/text just goes 30→50% on hover.
public enum ButtonProminence {
    case primary, secondary, ghost, minimal

    public func fill(hovering: Bool) -> Color {
        switch self {
        case .primary:   return .white.opacity(hovering ? 0.88 : 1.0)
        case .secondary: return .white.opacity(hovering ? 0.15 : 0.10)
        case .ghost:     return .white.opacity(hovering ? 0.07 : 0.0)
        case .minimal:   return .clear
        }
    }

    public func foreground(hovering: Bool) -> Color {
        switch self {
        case .primary:   return .black
        case .secondary: return Tokens.Ink.primary
        case .ghost:     return hovering ? Tokens.Ink.secondary : Tokens.Ink.tertiary
        case .minimal:   return .white.opacity(hovering ? 0.5 : 0.3)
        }
    }
}

/// Square icon button (always 1:1, circular). Shares the four prominences and two
/// sizes. Default is the ghost language (back chevron); pass `.minimal` for the
/// quietest icons. The app-wide primitive for iconic actions.
public struct IconButton: View {
    let systemName: String
    var prominence: ButtonProminence = .ghost
    var size: DSSize = .sm
    var iconSize: CGFloat = 15
    var weight: Font.Weight = .semibold
    var enabled: Bool = true
    var action: () -> Void

    @State private var hovering = false

    public init(
        systemName: String,
        prominence: ButtonProminence = .ghost,
        size: DSSize = .sm,
        iconSize: CGFloat = 15,
        weight: Font.Weight = .semibold,
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
                        : Color.white.opacity(0.15)
                )
                .frame(width: size.dim, height: size.dim)
                .background(
                    enabled ? prominence.fill(hovering: hovering) : .clear,
                    in: Circle()
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { if enabled { hovering = $0 } else { hovering = false } }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Icon-only chrome for `Menu` / `SettingsLink` labels (no nested `Button`).
/// Same opacity ramp as `ButtonProminence.minimal`.
public struct MinimalIconGlyph: View {
    let systemName: String
    var iconSize: CGFloat = 15
    var weight: Font.Weight = .medium
    /// When true, stay at the brighter end (e.g. active filter).
    var emphasized: Bool = false

    @State private var hovering = false

    public init(
        systemName: String,
        iconSize: CGFloat = 15,
        weight: Font.Weight = .medium,
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
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// `Menu` recolors its label with the accent unless `.tint` is locked to the
/// minimal ramp — use this instead of hand-rolled `Menu { } label: { Image… }`.
public struct MinimalIconMenu<Content: View>: View {
    let systemName: String
    var iconSize: CGFloat = 15
    var weight: Font.Weight = .medium
    var emphasized: Bool = false
    var helpText: String? = nil
    @ViewBuilder var menuContent: () -> Content

    @State private var hovering = false

    public init(
        systemName: String,
        iconSize: CGFloat = 15,
        weight: Font.Weight = .medium,
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
        .animation(.easeOut(duration: 0.12), value: hovering)
        .modifier(OptionalHelp(helpText))
    }
}

/// `SettingsLink` has the same accent-tint problem as `Menu`.
public struct MinimalIconSettingsLink: View {
    var systemName: String = "gearshape.fill"
    var iconSize: CGFloat = 15
    var weight: Font.Weight = .medium
    var helpText: String? = "Настройки"

    @State private var hovering = false

    public init(
        systemName: String = "gearshape.fill",
        iconSize: CGFloat = 15,
        weight: Font.Weight = .medium,
        help helpText: String? = "Настройки"
    ) {
        self.systemName = systemName
        self.iconSize = iconSize
        self.weight = weight
        self.helpText = helpText
    }

    public var body: some View {
        SettingsLink {
            MinimalIconGlyph(
                systemName: systemName,
                iconSize: iconSize,
                weight: weight,
                emphasized: hovering
            )
        }
        .buttonStyle(.plain)
        .tint(ButtonProminence.minimal.foreground(hovering: hovering))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .modifier(OptionalHelp(helpText))
    }
}

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

    public init(
        material: Material = .thickMaterial,
        cornerRadius: CGFloat? = nil,
        tinted: Bool = true
    ) {
        self.material = material
        self.cornerRadius = cornerRadius
        self.tinted = tinted
    }

    public var body: some View {
        ZStack {
            Rectangle().fill(material)
            if tinted {
                Rectangle().fill(Color(nsColor: Tokens.Glass.fill))
            }
        }
    }
}

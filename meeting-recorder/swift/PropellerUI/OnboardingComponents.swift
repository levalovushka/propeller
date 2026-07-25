import SwiftUI

/// When `true`, the host window already paints system glass — the card skips
/// its own `GlassBackground`.
public struct OnboardingHostProvidesGlassKey: EnvironmentKey {
    public static let defaultValue = false
}

extension EnvironmentValues {
    public var onboardingHostProvidesGlass: Bool {
        get { self[OnboardingHostProvidesGlassKey.self] }
        set { self[OnboardingHostProvidesGlassKey.self] = newValue }
    }
}

/// Centred onboarding plate (Figma 642:2122): flexible middle stack + action row.
/// Optional chrome (back) overlays top-leading at the card inset.
struct OnboardingCard<Chrome: View, Content: View, Actions: View>: View {
    @Environment(\.onboardingHostProvidesGlass) private var hostProvidesGlass
    @ViewBuilder var chrome: () -> Chrome
    @ViewBuilder var content: () -> Content
    @ViewBuilder var actions: () -> Actions

    init(
        @ViewBuilder chrome: @escaping () -> Chrome = { EmptyView() },
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.chrome = chrome
        self.content = content
        self.actions = actions
    }

    var body: some View {
        VStack(spacing: 0) {
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, Tokens.Card.inset)
                .padding(.top, 40)

            actions()
                .padding(Tokens.Card.actionPadding)
        }
        .frame(width: Tokens.Card.width, height: Tokens.Card.height)
        .overlay(alignment: .topLeading) {
            chrome()
                .padding(Tokens.Card.inset)
        }
        .background { if !hostProvidesGlass { GlassBackground() } }
    }
}

public struct PillButton: View {
    public var title: String
    public var kind: ButtonProminence = .secondary
    public var size: DSSize = .md
    public var leadingSymbol: String? = nil
    public var trailingSymbol: String? = nil
    public var action: () -> Void

    @State private var hovering = false

    public init(
        title: String,
        kind: ButtonProminence = .secondary,
        size: DSSize = .md,
        leadingSymbol: String? = nil,
        trailingSymbol: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.kind = kind
        self.size = size
        self.leadingSymbol = leadingSymbol
        self.trailingSymbol = trailingSymbol
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: Tokens.Pill.iconGap) {
                if let leadingSymbol { Image(systemName: leadingSymbol) }
                Text(title)
                if let trailingSymbol { Image(systemName: trailingSymbol) }
            }
            .font(.pillLabel)
            .foregroundStyle(kind.foreground(hovering: hovering))
            .padding(.horizontal, Tokens.Pill.hPadding)
            .padding(.vertical, Tokens.Pill.vPadding)
            .frame(height: size.dim)
            .background(kind.fill(hovering: hovering),
                        in: RoundedRectangle(cornerRadius: Tokens.Pill.radius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Tokens.Pill.radius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Centred progress worm (Figma welcome). Active = 8, neighbours fall off.
struct OnboardingPager: View {
    let count: Int
    let index: Int

    private func size(for i: Int) -> CGFloat {
        switch min(abs(i - index), 2) {
        case 0: return 8
        case 1: return 6
        default: return 4
        }
    }

    private func inkColor(for i: Int) -> Color {
        switch min(abs(i - index), 2) {
        case 0: return Tokens.Ink.primary
        case 1: return Tokens.Ink.secondary
        default: return Tokens.Ink.tertiary
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { i in
                Circle()
                    .fill(inkColor(for: i))
                    .frame(width: size(for: i), height: size(for: i))
            }
        }
        .frame(height: 32)
        .animation(.spring(response: 0.38, dampingFraction: 0.72), value: index)
    }
}

struct OnboardingBackButton: View {
    var action: () -> Void
    var body: some View { IconButton(systemName: "chevron.left", action: action) }
}

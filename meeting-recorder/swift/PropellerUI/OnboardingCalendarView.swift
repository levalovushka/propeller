import SwiftUI

/// Calendar step — Figma 642:2236. Provider chips live in the content stack;
/// the action row is just Skip (or Next once connected).
struct OnboardingCalendarView: View {
    var onNext: () -> Void
    var onSkip: () -> Void
    var onBack: () -> Void
    var onConnect: (Cal) -> Void = { _ in }

    enum Cal: String { case apple = "Apple Calendar", google = "Google Account" }
    @State private var connected: Cal?

    var body: some View {
        OnboardingCard {
            OnboardingBackButton(action: onBack)
        } content: {
            VStack(spacing: Tokens.Card.contentGap) {
                VStack(spacing: Tokens.Card.textGap) {
                    OnboardText.title("Give your meetings\nreal names")
                        .fixedSize(horizontal: false, vertical: true)
                    OnboardText.body("Titles and speakers, from your calendar.\nRead-only, stays on your Mac.")
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: Tokens.Pill.rowGap) {
                    if let connected {
                        PillButton(title: connected.rawValue, kind: .secondary,
                                   leadingSymbol: "checkmark") { disconnect() }
                    } else {
                        PillButton(title: Cal.apple.rawValue, kind: .secondary,
                                   leadingSymbol: "plus") { connect(.apple) }
                        PillButton(title: Cal.google.rawValue, kind: .secondary,
                                   leadingSymbol: "plus") { connect(.google) }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } actions: {
            HStack {
                if connected != nil {
                    PillButton(title: "Next", kind: .primary, action: onNext)
                } else {
                    PillButton(title: "Skip", kind: .ghost, action: onSkip)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func connect(_ cal: Cal) {
        onConnect(cal)
        withAnimation(.easeInOut(duration: 0.2)) { connected = cal }
    }

    private func disconnect() {
        withAnimation(.easeInOut(duration: 0.2)) { connected = nil }
    }
}

#Preview("Calendar") {
    OnboardingCalendarView(onNext: {}, onSkip: {}, onBack: {})
        .background(GlassBackground())
}

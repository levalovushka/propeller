import SwiftUI

/// Final onboarding beat — Figma End 642:2474. Logo + two-tone copy + finish.
struct OnboardingEndView: View {
    var onFinish: () -> Void

    var body: some View {
        OnboardingCard {
            EmptyView()
        } content: {
            VStack(spacing: 28) {
                PropellerMark(size: 48)
                OnboardText.titleTwoTone(
                    "Готово. ",
                    "Дальше можно\nзабыть о Propeller —\nон сам всё сделает."
                )
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } actions: {
            HStack {
                PillButton(title: "Хорошо", kind: .primary, action: onFinish)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

#Preview("End") {
    OnboardingEndView(onFinish: {})
        .background(GlassBackground())
}

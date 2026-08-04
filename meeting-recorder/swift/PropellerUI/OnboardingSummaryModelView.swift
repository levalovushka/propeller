import SwiftUI

/// Onboarding step: say that the summary model is being fetched, and move on.
///
/// **Not a question.** It used to offer «Скачать» / «Позже», which made the app
/// work or not work depending on whether someone understood the fifth screen of
/// an onboarding — and «Позже» had no way back except finding a button in
/// Settings. The model is part of the installation now: it is fetched on launch
/// and repaired whenever it goes missing (`design/no-dead-ends.md` §5), so there
/// is nothing here to decide and nothing to press but «Далее».
///
/// There is no progress bar either, for the reason there never was one: watching
/// 3.4 GB tick up buys nothing, recording works without it, and summaries
/// backfill on their own once the weights land.
struct OnboardingSummaryModelView: View {
    var onNext: () -> Void
    var onBack: () -> Void
    var isReady: Bool
    var errorMessage: String? = nil

    var body: some View {
        OnboardingCard {
            OnboardingBackButton(action: onBack)
        } content: {
            VStack(spacing: 16) {
                OnboardText.titleTwoTone(
                    "Саммари. ",
                    "Одна локальная\nмодель — без облака."
                )
                .fixedSize(horizontal: false, vertical: true)

                Text("Уже качаем в\u{00A0}фоне. Записывать и\u{00A0}расшифровывать\nможно прямо сейчас — саммари появятся,\nкогда модель докачается.")
                    .typo(Tokens.Typography.Label.mdRegular)
                    .foregroundStyle(Tokens.Ink.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if isReady {
                    Label("Модель на месте", systemImage: "checkmark.circle.fill")
                        .typo(Tokens.Typography.Label.mdMedium)
                        .foregroundStyle(.green)
                        .padding(.top, 8)
                }

                if let errorMessage, !errorMessage.isEmpty {
                    Text(errorMessage)
                        .typo(Tokens.Typography.Label.smMedium)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } actions: {
            PillButton(title: "Далее", kind: .primary, action: onNext)
                .frame(maxWidth: .infinity)
        }
    }
}

#Preview("Summary model") {
    OnboardingSummaryModelView(onNext: {}, onBack: {}, isReady: false)
    .background(GlassBackground())
}

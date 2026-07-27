import SwiftUI

/// Onboarding step: offer the local summary model, then get out of the way.
///
/// Both buttons advance immediately. The screen used to hold the user on a
/// progress bar after «Скачать», which bought them nothing — there is no
/// decision left and nothing to react to, so watching 3.4 GB tick up is pure
/// waiting. The download reports into the status bar instead, and recaps
/// backfill on their own once the model lands.
struct OnboardingSummaryModelView: View {
    var onNext: () -> Void
    var onSkip: () -> Void
    var onBack: () -> Void
    /// Starts the download in the background (must not await completion).
    var onStartDownload: () -> Void
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

                Text("Локальная модель для саммари и рекапа.\n\nСкачается в фоне, записывать можно без неё.")
                    .typo(Tokens.Typography.Label.mdRegular)
                    .foregroundStyle(Tokens.Ink.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if isReady {
                    Label("Модель готова", systemImage: "checkmark.circle.fill")
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
            HStack(spacing: 10) {
                if isReady {
                    PillButton(title: "Далее", kind: .primary, action: onNext)
                } else {
                    // Ghost is the tertiary step of the prominence scale: declining
                    // stays a real choice without competing with the recommended one.
                    PillButton(title: "Позже", kind: .ghost, action: onSkip)
                    PillButton(title: "Скачать", kind: .primary, action: {
                        onStartDownload()
                        onNext()
                    })
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

#Preview("Summary model") {
    OnboardingSummaryModelView(
        onNext: {},
        onSkip: {},
        onBack: {},
        onStartDownload: {},
        isReady: false
    )
    .background(GlassBackground())
}

import SwiftUI

/// Onboarding step: start local Ollama + model download without blocking the funnel.
/// User can tap Далее immediately — download continues in the status bar; recaps
/// backfill when the model is ready.
struct OnboardingSummaryModelView: View {
    var onNext: () -> Void
    var onSkip: () -> Void
    var onBack: () -> Void
    /// Starts download in the background (must not await completion).
    var onStartDownload: () -> Void
    var progress: Double?
    var statusMessage: String
    var isReady: Bool
    var errorMessage: String? = nil

    @State private var didStartDownload = false

    private var isDownloading: Bool { progress != nil || didStartDownload && !isReady }

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

                Text("Движок в приложении (~140 МБ). Модель ~5 ГБ скачивается один раз в фоне — можно сразу идти записывать, саммари догонит само.")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Tokens.Ink.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if isDownloading {
                    VStack(spacing: 8) {
                        ProgressView(value: progress ?? 0)
                            .progressViewStyle(.linear)
                            .frame(maxWidth: 260)
                        Text(statusMessage.isEmpty ? "Скачиваем в фоне…" : statusMessage)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Tokens.Ink.secondary)
                            .multilineTextAlignment(.center)
                        if let p = progress {
                            Text("\(Int(p * 100))%")
                                .font(.system(size: 12, weight: .medium).monospacedDigit())
                                .foregroundStyle(Tokens.Ink.tertiary)
                        }
                    }
                    .padding(.top, 8)
                } else if isReady {
                    Label("Модель готова", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.green)
                        .padding(.top, 8)
                }

                if let errorMessage, !errorMessage.isEmpty, !isDownloading {
                    Text(errorMessage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } actions: {
            HStack(spacing: 10) {
                if !isReady && !didStartDownload {
                    PillButton(title: "Позже", kind: .secondary, action: onSkip)
                    PillButton(title: "Скачать", kind: .secondary, action: {
                        didStartDownload = true
                        onStartDownload()
                    })
                }
                // Always allow leaving — download (if started) keeps going in the status bar.
                PillButton(title: "Далее", kind: .primary, action: onNext)
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
        progress: 0.42,
        statusMessage: "Скачиваем модель… 42%",
        isReady: false
    )
    .background(GlassBackground())
}

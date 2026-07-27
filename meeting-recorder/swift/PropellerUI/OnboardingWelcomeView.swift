import SwiftUI

/// Welcome carousel — Figma 642:2122…2180. Centred pager + copy; Next/Skip
/// sit together in the action row.
///
/// Copy is Russian (product decision 2026-07-25: the app ships fully in Russian).
/// Line breaks are hand-placed. The card is 400 wide with a 24 inset → 352pt of
/// text width, so a title line must stay under ~20 characters at 28pt and a body
/// line under ~45 at 14pt. Changing a string means re-checking both limits.
struct OnboardingWelcomeView: View {
    var onSetUp: () -> Void
    var onSkip: () -> Void

    @State private var index = 0

    private struct Slide { let title: String; let body: String }

    private let slides = [
        Slide(title: "Propeller запишет\nвстречу за вас",
              body: "Zoom-звонок начался — запись уже идёт.\nНичего не нужно нажимать."),
        Slide(title: "Транскрипт\nи саммари",
              body: "Работает на вашем Маке: без подписки,\nзаписи не покидают компьютер."),
        // The app has no screenshot capture — the previous copy promised one.
        Slide(title: "Заметки\nпо ходу встречи",
              body: "Поймали мысль — ⌃⌥N, и она в заметках\nвстречи с таймкодом."),
        Slide(title: "Саммари\nготово к отправке",
              body: "Скопируйте итог встречи или сохраните\nв Markdown — и отправьте команде."),
    ]

    private var isLast: Bool { index == slides.count - 1 }

    var body: some View {
        OnboardingCard {
            if index > 0 {
                OnboardingBackButton { advance(by: -1) }
            }
        } content: {
            VStack(spacing: Tokens.Card.contentGap) {
                OnboardingPager(count: slides.count, index: index)

                VStack(spacing: Tokens.Card.textGap) {
                    OnboardText.title(slides[index].title)
                        .fixedSize(horizontal: false, vertical: true)
                        .id("title\(index)")
                    OnboardText.body(slides[index].body)
                        .fixedSize(horizontal: false, vertical: true)
                        .id("body\(index)")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } actions: {
            HStack(spacing: Tokens.Pill.rowGap) {
                if isLast {
                    PillButton(title: "Настроить", kind: .primary,
                               trailingSymbol: "arrow.right", action: onSetUp)
                } else {
                    PillButton(title: "Далее", kind: .secondary) { advance(by: 1) }
                    // Skips the tour, not the setup — the flow routes this
                    // straight to permissions (which stay mandatory).
                    PillButton(title: "Пропустить", kind: .ghost, action: onSkip)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func advance(by delta: Int) {
        let next = min(max(index + delta, 0), slides.count - 1)
        withAnimation(.easeInOut(duration: 0.22)) { index = next }
    }
}

#Preview("Welcome") {
    OnboardingWelcomeView(onSetUp: {}, onSkip: {})
        .background(GlassBackground())
}

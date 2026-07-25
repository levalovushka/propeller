import SwiftUI

/// Welcome carousel — Figma 642:2122…2180. Centred pager + copy; Next/Skip
/// sit together in the action row.
struct OnboardingWelcomeView: View {
    var onSetUp: () -> Void
    var onSkip: () -> Void

    @State private var index = 0

    private struct Slide { let title: String; let body: String }

    private let slides = [
        Slide(title: "Propeller records your\nmeetings for you",
              body: "A Zoom call starts and recording's already\nrunning. Nothing to forget."),
        Slide(title: "Transcripts\nand summaries",
              body: "Runs on your Mac — no subscription,\nand recordings never leave the computer."),
        Slide(title: "Screenshots and\nnotes on the fly",
              body: "Catch a thought or grab the screen mid-meeting —\nit lands in the meeting's notes with a timestamp."),
        Slide(title: "Summary,\nready to go",
              body: "Copy the finished summary or save it\nas Markdown to pass to your team."),
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
                    PillButton(title: "Set up", kind: .primary,
                               trailingSymbol: "arrow.right", action: onSetUp)
                } else {
                    PillButton(title: "Next", kind: .secondary) { advance(by: 1) }
                    PillButton(title: "Skip", kind: .ghost, action: onSkip)
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

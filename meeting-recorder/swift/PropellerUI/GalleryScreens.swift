#if GALLERY
import SwiftUI
import PropellerPure

/// PropellerUI's half of the state gallery.
///
/// # What this is
///
/// The state gallery renders every screen Propeller can show, so they can be
/// looked at side by side, screenshotted, and used as the reference a redesign
/// works from. The catalogue of *which* screens exist lives in
/// `PropellerPure.UIStateCatalog`; this file knows how to *draw* the ones that
/// belong to PropellerUI.
///
/// # Why it lives here rather than in `Sources/`
///
/// The individual onboarding steps are `internal` to this module — only
/// `OnboardingFlowView` is public, and its current step is private `@State`, so
/// there is no way to ask it for "the permissions screen with the microphone
/// granted". Making six views public to serve a debug tool would widen the
/// module's real API for no product reason. Instead the module renders its own
/// screens and hands them out through one function.
///
/// # Why it is behind a flag
///
/// Everything here is compiled only into `./build.sh --gallery`. A shipping
/// build contains none of it. That matters less for these views — they are
/// stateless and harmless — than for the app-side gallery, which can pose the
/// pipeline, but the flag is applied uniformly so there is one rule to remember.
///
/// Screens are pure functions of their id: no shared state, nothing to reset
/// between them, and the exporter can render them in any order.
public enum GalleryScreens {

    /// The screen for `id`, or nil when this module does not own it.
    /// Ids come from `UIStateCatalog` — keep them in sync by construction: a
    /// missing id shows up as a blank frame in the export, not a crash.
    @ViewBuilder
    public static func view(for id: String) -> some View {
        switch id {

        // MARK: Onboarding

        case "onb-01-welcome":
            card { OnboardingWelcomeView(onSetUp: {}, onSkip: {}) }
        case "onb-02-name":
            card { OnboardingNameView(onNext: { _ in }, onBack: {}) }
        case "onb-03-calendar":
            card { OnboardingCalendarView(onNext: {}, onSkip: {}, onBack: {}, calendarGranted: false) }
        case "onb-03-calendar-granted":
            card { OnboardingCalendarView(onNext: {}, onSkip: {}, onBack: {}, calendarGranted: true) }
        case "onb-04-permissions":
            card {
                OnboardingPermissionsView(onNext: {}, onBack: {},
                                          microphoneGranted: false,
                                          notificationsGranted: false)
            }
        case "onb-04-permissions-partial":
            // Partial means *partial*: the microphone granted and notifications
            // not. Both were passed as `true`, so this frame was a duplicate of
            // «всё выдано» and the state it names was never photographed.
            card {
                OnboardingPermissionsView(onNext: {}, onBack: {},
                                          microphoneGranted: true,
                                          notificationsGranted: false)
            }
        case "onb-04-permissions-all":
            card {
                OnboardingPermissionsView(onNext: {}, onBack: {},
                                          microphoneGranted: true,
                                          notificationsGranted: true)
            }
        case "onb-05-model":
            card {
                OnboardingSummaryModelView(onNext: {}, onBack: {}, isReady: false)
            }
        case "onb-05-model-downloading":
            // The screen deliberately shows no progress bar — tapping «Скачать»
            // advances immediately. Captured so that decision is visible in the
            // reference rather than looking like an omission.
            card {
                OnboardingSummaryModelView(onNext: {}, onBack: {}, isReady: false)
            }
        case "onb-05-model-ready":
            card {
                OnboardingSummaryModelView(onNext: {}, onBack: {}, isReady: true)
            }
        case "onb-05-model-error":
            card {
                OnboardingSummaryModelView(onNext: {}, onBack: {}, isReady: false,
                                           errorMessage: "Не удалось скачать модель: нет соединения")
            }
        case "onb-06-end":
            card { OnboardingEndView(onFinish: {}) }

        default:
            EmptyView()
        }
    }

    /// Ids this module can draw. The app-side gallery asks before falling back
    /// to its own screens, so ownership is decided in one place.
    public static let ownedIDs: Set<String> = [
        "onb-01-welcome", "onb-02-name",
        "onb-03-calendar", "onb-03-calendar-granted",
        "onb-04-permissions", "onb-04-permissions-partial", "onb-04-permissions-all",
        "onb-05-model", "onb-05-model-downloading", "onb-05-model-ready", "onb-05-model-error",
        "onb-06-end",
    ]

    // MARK: - Framing

    /// Onboarding is a fixed 400×400 plate on the glass background — same
    /// framing as `OnboardingPanelController`, so the screenshots match the app.
    @ViewBuilder
    private static func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(width: Tokens.Card.width, height: Tokens.Card.height)
            .background(GlassBackground(cornerRadius: Tokens.Card.radius))
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Card.radius, style: .continuous))
            .padding(24)
            .background(Color.black)
    }

}
#endif

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

        // MARK: Setup

        case "onb-01-setup":
            plate { SetupView() }
        case "onb-01-setup-mic":
            plate { SetupView(microphoneGranted: true) }
        case "onb-01-setup-all":
            plate {
                SetupView(microphoneGranted: true,
                          notificationsGranted: true,
                          launchAtLogin: true)
            }

        default:
            EmptyView()
        }
    }

    /// Ids this module can draw. The app-side gallery asks before falling back
    /// to its own screens, so ownership is decided in one place.
    ///
    /// The rail's two questions are **not** here: they are states of the rail,
    /// and the rail needs a window and a list of meetings around it to be worth
    /// photographing. `SidebarGallery` draws those.
    public static let ownedIDs: Set<String> = [
        "onb-01-setup", "onb-01-setup-mic", "onb-01-setup-all",
    ]

    // MARK: - Framing

    /// Setup is a fixed 400×410 plate on the glass background — same framing as
    /// `OnboardingPanelController`, so the screenshots match the app.
    @ViewBuilder
    private static func plate<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(width: Tokens.Setup.width, height: Tokens.Setup.height)
            .background(GlassBackground(cornerRadius: Tokens.Setup.radius))
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Setup.radius, style: .continuous))
            .padding(24)
            .background(Color.black)
    }

}
#endif

import SwiftUI
import PropellerUI

/// Visual tokens for the v2 re-skin. See design/propeller-ui.md → «v2 визуальные
/// принципы». Glass darkness is `Tokens.Glass` in PropellerUI — shared with
/// onboarding.

/// Main-window glass. Same path / tint as the onboarding plate.
struct VisualEffectBackground: View {
    var body: some View {
        GlassBackground()
    }
}

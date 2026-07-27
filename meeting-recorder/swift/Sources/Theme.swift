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

extension View {
    /// A large page title, aligned leading, with the standard content inset.
    func pageHeader(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .typo(Tokens.Typography.Heading.lg)
                .foregroundStyle(.primary)
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 10)
            self
        }
    }
}

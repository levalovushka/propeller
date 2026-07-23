import SwiftUI
import AppKit

/// Visual tokens for the v2 re-skin. See design/propeller-ui.md → «v2 визуальные
/// принципы». Dark glass + editorial serif headings; hierarchy by space and
/// typography, not frames (pgcorpus PR-005/006/011).

/// Real behind-window vibrancy: the window becomes translucent and picks up
/// whatever is behind it (desktop / wallpaper) — colour comes from the content
/// below, not from a painted tint. Mirrors the draft mockup's glass.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        // Make the hosting window transparent so the vibrancy shows the desktop
        // behind it. Done here (not in make) because the window exists by now.
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
        }
    }
}

extension Font {
    /// Editorial serif for page titles (native New York via `design: .serif`).
    static func pageTitle(_ size: CGFloat = 30) -> Font {
        .system(size: size, weight: .medium, design: .serif)
    }
}

extension View {
    /// A large serif page title, aligned leading, with the standard content inset.
    func pageHeader(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.pageTitle())
                .foregroundStyle(.primary)
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 10)
            self
        }
    }
}

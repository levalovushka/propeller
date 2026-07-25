import AppKit
import SwiftUI

/// Shared liquid-glass chrome. Tint lives in `Tokens.Glass` — change it once,
/// main window and onboarding plate both pick it up.
public enum SystemGlass {
    /// Configure an `NSGlassEffectView` with the shared tint (and optional radius).
    @available(macOS 26.0, *)
    public static func apply(to glass: NSGlassEffectView, cornerRadius: CGFloat? = nil) {
        glass.style = .regular
        glass.tintColor = Tokens.Glass.tint
        if let cornerRadius {
            glass.cornerRadius = cornerRadius
        }
    }

    @available(macOS 26.0, *)
    public static func makeEffectView(cornerRadius: CGFloat? = nil) -> NSGlassEffectView {
        let glass = NSGlassEffectView()
        apply(to: glass, cornerRadius: cornerRadius)
        return glass
    }
}

/// AppKit liquid glass as a SwiftUI background (macOS 26+).
@available(macOS 26.0, *)
struct LiquidGlassBackdrop: NSViewRepresentable {
    var cornerRadius: CGFloat? = nil

    func makeNSView(context: Context) -> NSGlassEffectView {
        SystemGlass.makeEffectView(cornerRadius: cornerRadius)
    }

    func updateNSView(_ glass: NSGlassEffectView, context: Context) {
        SystemGlass.apply(to: glass, cornerRadius: cornerRadius)
    }
}

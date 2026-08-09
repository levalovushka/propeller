import AppKit
import SwiftUI

/// Shared liquid-glass chrome. Tint lives in `Tokens.Glass` — change it once,
/// main window and onboarding plate both pick it up.
public enum SystemGlass {
    /// Configure an `NSGlassEffectView` with the shared tint (and optional radius).
    ///
    /// `tint` отличается ровно у одного вида поверхностей — у вызванного
    /// инструмента (`Tokens.Glass.summonedTint`): он поднят над текстом и обязан
    /// быть светлее фона, а не темнее вместе с ним.
    @available(macOS 26.0, *)
    public static func apply(
        to glass: NSGlassEffectView,
        cornerRadius: CGFloat? = nil,
        tint: NSColor = Tokens.Glass.tint
    ) {
        glass.style = .regular
        glass.tintColor = tint
        if let cornerRadius {
            glass.cornerRadius = cornerRadius
        }
    }

    @available(macOS 26.0, *)
    public static func makeEffectView(
        cornerRadius: CGFloat? = nil,
        tint: NSColor = Tokens.Glass.tint
    ) -> NSGlassEffectView {
        let glass = NSGlassEffectView()
        apply(to: glass, cornerRadius: cornerRadius, tint: tint)
        return glass
    }
}

/// AppKit liquid glass as a SwiftUI background (macOS 26+).
@available(macOS 26.0, *)
struct LiquidGlassBackdrop: NSViewRepresentable {
    var cornerRadius: CGFloat? = nil
    var tint: NSColor = Tokens.Glass.tint

    func makeNSView(context: Context) -> NSGlassEffectView {
        SystemGlass.makeEffectView(cornerRadius: cornerRadius, tint: tint)
    }

    func updateNSView(_ glass: NSGlassEffectView, context: Context) {
        SystemGlass.apply(to: glass, cornerRadius: cornerRadius, tint: tint)
    }
}

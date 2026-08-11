import AppKit
import SwiftUI

/// AppKit text → bitmap → flakes.
///
/// `ImageRenderer` on a SwiftUI `Button`/`Text` quietly yields an empty image
/// here. Drawing the string ourselves is boring and reliable.
enum AshField {
    static func rasterize(
        title: String,
        preview: String,
        width: CGFloat,
        scale: CGFloat
    ) -> (cgImage: CGImage, size: CGSize)? {
        let style = Tokens.Sidebar.Typo.meetingTitle
        let font = style.nsFont
        let ink = resolvedInk()
        let dim = ink.withAlphaComponent(ink.alphaComponent * 0.55)

        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: title, attributes: [
            .font: font,
            .foregroundColor: ink,
        ]))
        if !preview.isEmpty {
            let gap = title.isEmpty ? "" : " "
            text.append(NSAttributedString(string: gap + preview, attributes: [
                .font: font,
                .foregroundColor: dim,
            ]))
        }
        guard text.length > 0 else { return nil }

        // Mirror `typoBlock`, glyph for glyph: `.lineSpacing(extra)` plus half
        // of it as padding above and below. Forcing a line box with
        // min/maximumLineHeight instead puts AppKit's baseline a couple of
        // points off SwiftUI's, so the ash appeared shifted from the letters it
        // replaced — which reads as the row's padding vanishing on the frame the
        // ash starts, and makes the list flinch.
        let half = max(0, style.lineSpacingExtra) / 2
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = max(0, style.lineSpacingExtra)
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))

        let padX = Tokens.Sidebar.meetingHPadding
        let padY = Tokens.Sidebar.meetingVPadding + half
        let textWidth = max(40, width - padX * 2)
        let bounds = text.boundingRect(
            with: CGSize(width: textWidth, height: 10_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        let viewSize = CGSize(
            width: width,
            height: ceil(bounds.height) + padY * 2
        )
        let px = max(1, Int(ceil(viewSize.width * scale)))
        let py = max(1, Int(ceil(viewSize.height * scale)))

        guard let ctx = CGContext(
            data: nil,
            width: px,
            height: py,
            bitsPerComponent: 8,
            bytesPerRow: px * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.translateBy(x: 0, y: CGFloat(py))
        ctx.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        text.draw(
            with: CGRect(x: padX, y: padY, width: textWidth, height: bounds.height + 4),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        NSGraphicsContext.restoreGraphicsState()

        guard let image = ctx.makeImage() else { return nil }
        return (image, viewSize)
    }

    private static func resolvedInk() -> NSColor {
        // `NSApp` is nil wherever there is no application — a test reaching this
        // through `rasterize` took the whole run down on the force-unwrap. The
        // drawing appearance is the right fallback anyway: it is what the context
        // we are about to draw into would answer.
        let appearance = NSApp?.effectiveAppearance ?? .currentDrawing()
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark
            ? NSColor(white: 1, alpha: 0.95)
            : NSColor(white: 0, alpha: 0.88)
    }

}

/// Layout-neutral ash: sits in an `overlay` on the real row so the rail height
/// never changes. A `ZStack` with a large canvas was what blew the slot.
///
/// It is given the row's *frozen* height by the caller, not the shrinking one —
/// an overlay inside the collapsing, clipped slot gets guillotined from the
/// bottom, and the field looked like it burned out halfway.
struct MeetingRowAshView: View {
    let title: String
    let preview: String
    var onFinished: () -> Void

    @State private var raster: CGImage?
    @State private var rasterSize: CGSize = .zero
    @State private var finished = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var duration: TimeInterval { Tokens.Motion.Ash.duration }
    private var margin: CGFloat { Tokens.Motion.Ash.headroom }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // Never let this subtree be empty. `onAppear` used to hang off a
                // `Group` that resolves to nothing until `raster` is set — and
                // `boot` is what sets it. SwiftUI does not reliably fire
                // `onAppear` on content that renders to nothing, so the boot
                // never ran, the row rasterised nothing, and there was no ash at
                // all. The old CPU path got away with it because `TimelineView`
                // always produced a view to hang the callback on.
                Color.clear.onAppear { boot(width: geo.size.width) }

                if let raster {
                    // Grown by `margin` on every side and pulled back by the same,
                    // so the row's own origin is exactly where the letters were and
                    // a particle that leaves the line still has canvas to fly into.
                    AshMetalCanvas(
                        image: raster,
                        rowSize: rasterSize,
                        margin: margin,
                        duration: duration,
                        onFinished: finishOnce,
                        onUnavailable: finishOnce
                    )
                    .frame(
                        width: rasterSize.width + margin * 2,
                        height: rasterSize.height + margin * 2,
                        alignment: .topLeading
                    )
                    .offset(x: -margin, y: -margin)
                }
            }
        }
        // Take exactly the space the row already offered — nothing more.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    private func boot(width: CGFloat) {
        guard width > 1, raster == nil, !finished else {
            AshLog.log.info("boot: skipped, width \(width) hasRaster \(raster != nil) finished \(finished)")
            return
        }
        if reduceMotion {
            finishOnce()
            return
        }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let shot = AshField.rasterize(
            title: title,
            preview: preview,
            width: width,
            scale: scale
        ) else {
            finishOnce()
            return
        }
        rasterSize = shot.size
        raster = shot.cgImage
        AshLog.log.info("boot: width \(width) raster \(shot.size.debugDescription) margin \(margin)")
    }

    private func finishOnce() {
        guard !finished else { return }
        finished = true
        onFinished()
    }
}

import AppKit
import SwiftUI
import PropellerPure

/// # Панель над выделением без кражи фокуса
///
/// SwiftUI `Button` в overlay забирает first responder у `NSTextView`: wash
/// пропадает, `selectedRange` обнуляется, Bold/«Короче» бьют в пустоту, а
/// обходные `pinRewriteTarget` лечат симптом. Правильный приём AppKit —
/// контейнер, который **не становится** first responder (`acceptsFirstResponder
/// = false`), плюс кнопки с `refusesFirstResponder`. Клик доходит, каретка и
/// выделение в тексте остаются.
///
/// Позиционирование по-прежнему у SwiftUI overlay: панель едет вместе со
/// скроллом колонки. Отдельный `NSPanel` в экранных координатах этого не умеет
/// без подписки на каждый скролл.
struct SummaryActionBarHost: NSViewRepresentable {
    let selection: SummaryEditorController.Selection
    let onKind: (SummaryDocument.Block.Kind) -> Void
    let onBold: () -> Void
    let onItalic: () -> Void
    let onRewrite: ((SummaryRewrite) -> Void)?
    let onMeasuredWidth: (CGFloat) -> Void

    func makeNSView(context: Context) -> NonActivatingHostingView<SummaryActionBar> {
        let root = SummaryActionBar(
            selection: selection,
            onKind: onKind,
            onBold: onBold,
            onItalic: onItalic,
            onRewrite: onRewrite
        )
        let view = NonActivatingHostingView(rootView: root)
        view.translatesAutoresizingMaskIntoConstraints = false
        // Clear, or the material behind the bar samples an opaque plate and
        // the glass reads as a solid grey slab.
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        // First layout builds the buttons asynchronously — mark them after.
        DispatchQueue.main.async { view.refuseFirstResponderInSubtree() }
        return view
    }

    func updateNSView(
        _ view: NonActivatingHostingView<SummaryActionBar>, context: Context
    ) {
        view.rootView = SummaryActionBar(
            selection: selection,
            onKind: onKind,
            onBold: onBold,
            onItalic: onItalic,
            onRewrite: onRewrite
        )
        view.refuseFirstResponderInSubtree()
        let width = view.fittingSize.width
        if width > 0 {
            DispatchQueue.main.async { onMeasuredWidth(width) }
        }
    }
}

/// `NSHostingView`, который никогда не забирает клавиатуру у редактора.
final class NonActivatingHostingView<Content: View>: NSHostingView<Content> {
    override var acceptsFirstResponder: Bool { false }

    override func becomeFirstResponder() -> Bool { false }

    /// После каждого обновления дерева SwiftUI заново помечает кнопки:
    /// иначе свежий `NSButton` снова сможет стать first responder.
    func refuseFirstResponderInSubtree() {
        func walk(_ view: NSView) {
            if let button = view as? NSButton {
                button.refusesFirstResponder = true
            }
            for child in view.subviews { walk(child) }
        }
        walk(self)
    }
}

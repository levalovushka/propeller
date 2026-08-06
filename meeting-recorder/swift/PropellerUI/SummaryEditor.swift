import SwiftUI
import AppKit
import PropellerPure

/// # Колонка саммари — она же редактор
///
/// Один вид, а не «показ» и «правка» по очереди. Режим переключал бы вёрстку
/// под руками: щёлкнув в текст, человек видел бы, как 18-й кегль лида
/// схлопывается в моноширинный markdown, — и это ровно то, что делал прежний
/// экран. Здесь текст всегда тот же, каретка просто появляется там, куда
/// щёлкнули.
///
/// Полосы прокрутки у редактора своей нет: он живёт внутри `ScrollView` панели
/// и сообщает наружу свою высоту. Вложенная прокрутка внутри прокрутки — это
/// два перехвата колеса на одном жесте.

// MARK: - Ручка управления

/// То, чем панель действий двигает текст, и то, что она про него знает.
///
/// Живёт у панели, а не у редактора: панель действий рисуется поверх колонки и
/// должна пережить пересборку `NSViewRepresentable`, которая случается на каждый
/// кадр анимации соседа.
public final class SummaryEditorController: ObservableObject {

    /// Что сейчас выделено — и где это на экране.
    public struct Selection: Equatable {
        public var kind: SummaryDocument.Block.Kind
        public var bold: Bool
        public var italic: Bool
        public var text: String
        /// Диапазон в тексте. Он же — тождество выделения: панель уезжает и
        /// приезжает, когда меняется он, а не когда меняются координаты.
        public var range: NSRange
        /// Левый нижний угол выделения, в координатах редактора. Панель
        /// действий встаёт под ним — как под курсором, а не в углу окна.
        public var anchor: CGPoint
        /// Прямоугольник, охватывающий выделенное, — по нему кладётся шиммер.
        public var bounds: CGRect
        /// Выделенные глифы на прозрачном, размером с `bounds`.
        ///
        /// Шиммер в рельсе идёт по маске из самого текста, а не по плашке
        /// (`paragraph.sidebarSweep()`), и здесь должно быть так же —
        /// иначе вместо «фраза оживает» получается «по фразе едет полоса».
        /// `NSTextView` своей альфы не отдаёт, поэтому глифы рисуются в
        /// картинку один раз, когда выделение случилось.
        public var glyphs: NSImage?

        public init(
            kind: SummaryDocument.Block.Kind,
            bold: Bool,
            italic: Bool,
            text: String,
            range: NSRange = NSRange(location: 0, length: 0),
            anchor: CGPoint,
            bounds: CGRect = .zero,
            glyphs: NSImage? = nil
        ) {
            self.kind = kind
            self.bold = bold
            self.italic = italic
            self.text = text
            self.range = range
            self.anchor = anchor
            self.bounds = bounds
            self.glyphs = glyphs
        }
    }

    /// nil — выделения нет, панели действий тоже.
    @Published public internal(set) var selection: Selection?
    /// Фрагмент, который сейчас переписывает модель.
    ///
    /// Живёт отдельно от `selection`: клик по «Короче» снимает выделение у
    /// `NSTextView` (кнопка забирает first responder), а шиммер и подстановка
    /// ответа всё ещё должны знать, *куда* класть текст. Пока это не nil —
    /// модель думает (или typewriter ещё доигрывает замену).
    @Published public private(set) var rewriteTarget: Selection?
    /// Идёт запрос к модели: «короче» или «подробнее». Ставится снаружи — тем,
    /// кто этот запрос и делает: у редактора нет ни модели, ни настроек.
    ///
    /// При подъёме запоминает выделение, гасит его (шиммер вместо wash, панель
    /// уезжает) и притушивает глифы — иначе шиммер по белому в 95 % не виден.
    /// `rewriteTarget` не сбрасывается здесь: его снимает `applyRewrite` /
    /// `cancelRewrite` после typewriter.
    @Published public var isRewriting = false {
        didSet {
            guard isRewriting != oldValue else { return }
            if isRewriting {
                if let selection {
                    pinRewriteTarget(selection)
                }
                textView?.setDimmed(rewriteTarget?.range)
                // Снять wash, панель и каретку: ответ ждёт шиммер, не курсор.
                withdrawCaret()
            } else {
                textView?.setDimmed(nil)
            }
        }
    }
    /// Мягкий typewriter играет — каретку и правку не пускаем.
    @Published public internal(set) var isTypewriting = false
    /// Следующая загрузка документа — появление колонки typewriter'ом.
    private var pendingColumnAppear = false
    private var pendingColumnAppearAnimated = true

    fileprivate weak var textView: SummaryTextView?

    public init() {}

    public var hasSelection: Bool { selection != nil }

    /// Запомнить фрагмент до снятия выделения — и дорисовать маску глифов,
    /// если её ещё нет (на обычном выделении её не строим: `lockFocus` на
    /// каждый жест мыши слишком дорог).
    public func pinRewriteTarget(_ target: Selection) {
        var target = target
        if target.glyphs == nil {
            target.glyphs = textView?.glyphMask(of: target.range, in: target.bounds)
        }
        rewriteTarget = target
    }

    /// Модель написала саммари в уже открытую встречу — проявить колонку.
    public func armColumnAppear(animated: Bool = true) {
        pendingColumnAppear = true
        pendingColumnAppearAnimated = animated
    }

    fileprivate func consumeColumnAppear() -> Bool? {
        guard pendingColumnAppear else { return nil }
        pendingColumnAppear = false
        return pendingColumnAppearAnimated
    }

    public func setKind(_ kind: SummaryDocument.Block.Kind) {
        textView?.applyKind(kind)
    }

    public func toggleBold() { textView?.toggleEmphasis(.bold) }
    public func toggleItalic() { textView?.toggleEmphasis(.italic) }

    /// Ответ модели не пришёл — снять шиммер и цель.
    public func cancelRewrite() {
        isRewriting = false
        rewriteTarget = nil
        withdrawCaret()
    }

    /// Убрать старый фрагмент typewriter'ом, подставить ответ, проявить его.
    @MainActor
    public func applyRewrite(_ text: String) async {
        guard let range = rewriteTarget?.range, let textView else {
            cancelRewrite()
            return
        }
        isRewriting = false
        textView.setDimmed(nil)
        isTypewriting = true
        defer {
            isTypewriting = false
            rewriteTarget = nil
            textView.typewriterClear()
            // Не оставляем каретку в теле: захочет править — сам щёлкнет.
            withdrawCaret()
        }
        await textView.typewriterDismiss(range: range)
        guard let inserted = textView.replaceSelectionKeepingKind(with: text, range: range)
        else {
            // Dismiss left the old glyphs at alpha 0 — put them back. Nothing
            // landed in undo, so ⌘Z would not have saved us.
            return
        }
        await textView.typewriterAppear(range: inserted)
    }

    /// Снять выделение и убрать мигающую каретку из колонки.
    private func withdrawCaret() {
        guard let textView else {
            selection = nil
            return
        }
        let length = (textView.string as NSString).length
        let loc = min(max(0, textView.selectedRange().location), length)
        textView.setSelectedRange(NSRange(location: loc, length: 0))
        selection = nil
        if textView.window?.firstResponder === textView {
            _ = textView.window?.makeFirstResponder(
                textView.superview ?? textView.window?.contentView
            )
        }
    }

    /// Выделить первый блок такого вида — для доски состояний.
    ///
    /// Настоящим выделением, а не подделкой: панель тогда встаёт там, где она
    /// действительно встанет, и кадр отвечает на вопрос «как это выглядит», а
    /// не «как это нарисовал бы тот, кто позировал».
    public func poseSelection(ofFirst kind: SummaryDocument.Block.Kind) {
        textView?.selectFirstBlock(of: kind)
    }

    /// Снять выделение — панель действий уезжает.
    public func clearSelection() {
        withdrawCaret()
    }
}

// MARK: - Представление

public struct SummaryEditor: NSViewRepresentable {
    private let document: SummaryDocument
    private let isEditable: Bool
    private let controller: SummaryEditorController
    private let onChange: (SummaryDocument) -> Void
    @Binding private var height: CGFloat

    public init(
        document: SummaryDocument,
        isEditable: Bool = true,
        controller: SummaryEditorController,
        height: Binding<CGFloat>,
        onChange: @escaping (SummaryDocument) -> Void
    ) {
        self.document = document
        self.isEditable = isEditable
        self.controller = controller
        self._height = height
        self.onChange = onChange
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller, onChange: onChange, height: $height)
    }

    public func makeNSView(context: Context) -> SummaryTextView {
        // A width from the start, not `.zero`. TextKit lays glyphs into the
        // container it is given, and a container zero points wide is one where
        // nothing ever fits — it does not fail, it keeps trying, on the main
        // thread, and the window never appears.
        let view = SummaryTextView(frame: NSRect(
            x: 0, y: 0, width: Tokens.Pane.summaryMaxWidth, height: 0
        ))
        view.delegate = context.coordinator
        view.coordinator = context.coordinator
        view.allowsUndo = true
        view.isRichText = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.usesFontPanel = false
        view.usesRuler = false
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.size = NSSize(
            width: Tokens.Pane.summaryMaxWidth, height: .greatestFiniteMagnitude
        )
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        view.insertionPointColor = Tokens.Pane.caret
        view.selectedTextAttributes = [.backgroundColor: Tokens.Pane.selectionFill]
        context.coordinator.attach(view)
        context.coordinator.load(document, into: view)
        return view
    }

    public func updateNSView(_ view: SummaryTextView, context: Context) {
        view.isEditable = isEditable
        context.coordinator.onChange = onChange
        // Только когда снаружи пришёл *другой* документ: перезагружать текст на
        // каждое обновление вью — значит терять каретку на каждой букве.
        if context.coordinator.loaded != document {
            context.coordinator.load(document, into: view)
        }
        context.coordinator.reportHeight(of: view)
    }

    // MARK: - Координатор

    public final class Coordinator: NSObject, NSTextViewDelegate {
        let controller: SummaryEditorController
        var onChange: (SummaryDocument) -> Void
        @Binding var height: CGFloat
        /// Последний документ, который редактор *получил* — чтобы отличить свою
        /// правку от чужой подмены.
        var loaded: SummaryDocument?
        /// Своя история отмены, а не оконная. `NSTextView` с `allowsUndo`
        /// по умолчанию берёт менеджер из цепочки респондеров — то есть окна, —
        /// и `removeAllActions()` при загрузке другого конспекта стирал вместе
        /// со своей чужую запись: отмену удаления встречи. ⌘Z в рельсе после
        /// этого просто нечего было отменять.
        private let editorUndo = UndoManager()
        /// Заголовок «## Итог» едет с документом, а не с текстом: панель его не
        /// рисует, но файл его ждёт обратно.
        private var leadHeading: String?
        private var isLoading = false

        init(
            controller: SummaryEditorController,
            onChange: @escaping (SummaryDocument) -> Void,
            height: Binding<CGFloat>
        ) {
            self.controller = controller
            self.onChange = onChange
            self._height = height
        }

        func attach(_ view: SummaryTextView) {
            controller.textView = view
        }

        func load(_ document: SummaryDocument, into view: SummaryTextView) {
            isLoading = true
            defer { isLoading = false }
            loaded = document
            leadHeading = document.leadHeading
            let text = SummaryText.attributed(document, colour: Tokens.Pane.bodyNSColor)
            view.typewriterCancel()
            view.textStorage?.setAttributedString(text)
            view.undoManager?.removeAllActions()
            view.setTypingAttributesFromCaret()
            reportHeight(of: view)
            if let animated = controller.consumeColumnAppear() {
                let whole = NSRange(location: 0, length: text.length)
                guard whole.length > 0 else { return }
                controller.isTypewriting = true
                if animated {
                    view.typewriterSnap(range: whole, progress: 0)
                    Task { @MainActor [weak controller] in
                        await view.typewriterAppear(range: whole)
                        controller?.isTypewriting = false
                    }
                } else {
                    view.typewriterClear()
                    controller.isTypewriting = false
                }
            } else {
                view.typewriterClear()
            }
        }

        public func undoManager(for view: NSTextView) -> UndoManager? { editorUndo }

        public func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? SummaryTextView else { return }
            view.restyle()
            publish(from: view)
            reportHeight(of: view)
        }

        public func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? SummaryTextView else { return }
            view.keepCaretOutOfBulletMarker()
            view.setTypingAttributesFromCaret()
            let next = view.currentSelection()
            // Анимация только когда панель появляется или исчезает. На каждый
            // кадр растягивания выделения `withAnimation` гонял Observation и
            // ловил EXC_BAD_ACCESS в ScrollEnvironment на mouseExited.
            let presenceChanged = (controller.selection == nil) != (next == nil)
            if presenceChanged {
                withAnimation { controller.selection = next }
            } else {
                controller.selection = next
            }
        }

        /// Тот же документ наружу — и запомненный здесь, чтобы `updateNSView` не
        /// принял наше собственное изменение за чужое и не перезагрузил текст.
        func publish(from view: SummaryTextView) {
            guard !isLoading, let storage = view.textStorage else { return }
            let document = SummaryText.document(from: storage, leadHeading: leadHeading)
            loaded = document
            onChange(document)
        }

        func reportHeight(of view: SummaryTextView) {
            guard let layout = view.layoutManager, let container = view.textContainer else { return }
            // Never lay out into nothing — see `makeNSView`. SwiftUI hands the
            // view its real width a beat after creating it, and asking before
            // that is the difference between a summary and a hung window.
            guard container.size.width > 1 else { return }
            layout.ensureLayout(for: container)
            let measured = ceil(layout.usedRect(for: container).height)
            guard abs(measured - height) > 0.5 else { return }
            DispatchQueue.main.async { [weak self] in self?.height = measured }
        }
    }
}

// MARK: - Текстовое поле

/// `NSTextView`, который знает, что абзац — это блок.
///
/// Всё, что здесь переопределено, — это охрана двух вещей: маркера списка,
/// который лежит в тексте настоящим символом, и вида блока, который должен
/// пережить Return, вставку из буфера и удаление.
public final class SummaryTextView: NSTextView {
    weak var coordinator: SummaryEditor.Coordinator?
    private var typewriter: SummaryTypewriterDrive?

    private func typewriterDrive() -> SummaryTypewriterDrive {
        if let typewriter { return typewriter }
        let drive = SummaryTypewriterDrive(textView: self)
        typewriter = drive
        return drive
    }

    func typewriterCancel() { typewriter?.cancel() }

    func typewriterClear() { typewriterDrive().clear() }

    func typewriterSnap(range: NSRange, progress: Double) {
        typewriterDrive().snap(
            range: range, progress: progress, colour: Tokens.Pane.bodyNSColor
        )
    }

    @MainActor
    func typewriterAppear(range: NSRange) async {
        let duration = SummaryTypewriter.duration(
            count: range.length,
            secondsPerChar: Tokens.Pane.Reveal.appearSecondsPerChar,
            minimum: Tokens.Pane.Reveal.appearMin,
            maximum: Tokens.Pane.Reveal.appearMax
        )
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            typewriterDrive().animate(
                range: range,
                from: 0,
                to: 1,
                duration: duration,
                colour: Tokens.Pane.bodyNSColor,
                reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ) {
                cont.resume()
            }
        }
    }

    @MainActor
    func typewriterDismiss(range: NSRange) async {
        let duration = SummaryTypewriter.duration(
            count: range.length,
            secondsPerChar: Tokens.Pane.Reveal.dismissSecondsPerChar,
            minimum: Tokens.Pane.Reveal.dismissMin,
            maximum: Tokens.Pane.Reveal.dismissMax
        )
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            typewriterDrive().animate(
                range: range,
                from: 1,
                to: 0,
                duration: duration,
                colour: Tokens.Pane.bodyNSColor,
                reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ) {
                cont.resume()
            }
        }
    }

    private var isTypewriting: Bool { coordinator?.controller.isTypewriting == true }

    // MARK: Ввод

    public override func insertText(_ insertString: Any) {
        guard !isTypewriting else { return }
        super.insertText(insertString)
    }

    public override func doCommand(by selector: Selector) {
        // Swallow typing during the gesture. Undo is fine if it somehow lands
        // here; after the gesture we re-key the window for ⌘Z.
        if isTypewriting {
            let name = NSStringFromSelector(selector)
            if name != "undo:" && name != "redo:" { return }
        }
        super.doCommand(by: selector)
    }

    /// Return открывает следующий блок: из пункта — пункт, из всего
    /// остального — обычный текст. Пустой пункт Return не продолжает, а
    /// закрывает: это единственный способ выйти из списка, не трогая мышь.
    public override func insertNewline(_ sender: Any?) {
        guard !isTypewriting else { return }
        let kind = kindAtCaret()
        if kind == .bullet, currentParagraphIsEmptyBullet() {
            convertParagraphToBody()
            return
        }
        super.insertNewline(sender)
        let next: SummaryDocument.Block.Kind = kind == .bullet ? .bullet : .body
        setKindOfCurrentParagraph(next)
        if next == .bullet {
            insertText(SummaryText.bulletMarker, replacementRange: selectedRange())
            setKindOfCurrentParagraph(.bullet)
        }
        restyle()
        setTypingAttributesFromCaret()
        coordinator?.publish(from: self)
    }

    /// Backspace сразу за диском убирает весь маркер и превращает пункт в
    /// абзац — иначе он съедает табуляцию и оставляет диск без списка.
    public override func deleteBackward(_ sender: Any?) {
        guard !isTypewriting else { return }
        let range = selectedRange()
        let paragraph = paragraphRange(at: range.location)
        let markerLength = (SummaryText.bulletMarker as NSString).length
        if range.length == 0,
           kindAtCaret() == .bullet,
           range.location == paragraph.location + markerLength {
            convertParagraphToBody()
            return
        }
        super.deleteBackward(sender)
    }

    /// Из буфера приходит только текст. Чужие шрифты и цвета в саммари — это
    /// вид, которого нет ни в одном токене, и который переживёт сохранение.
    public override func paste(_ sender: Any?) {
        guard !isTypewriting else { return }
        pasteAsPlainText(sender)
        restyle()
        coordinator?.publish(from: self)
    }

    // MARK: Команды панели действий

    /// Сменить вид абзацев под выделением.
    ///
    /// Одна замена через `shouldChangeText` / `didChangeText` — так AppKit
    /// кладёт правку в стопку отмены, и ⌘Z возвращает и маркеры списка, и вид.
    /// Ручной `undoManager.beginUndoGrouping` вокруг `textStorage` этого не
    /// делает: регистрация undo живёт в паре should/did у `NSTextView`.
    func applyKind(_ kind: SummaryDocument.Block.Kind) {
        guard let storage = textStorage else { return }
        let affected = paragraphRanges(coveredBy: selectedRange())
        guard let first = affected.first, let last = affected.last else { return }
        let union = NSRange(
            location: first.location,
            length: NSMaxRange(last) - first.location
        )
        let edited = NSMutableAttributedString(
            attributedString: storage.attributedSubstring(from: union)
        )
        for range in affected.reversed() {
            var local = NSRange(
                location: range.location - union.location,
                length: range.length
            )
            let was = SummaryText.kind(in: edited, at: local.location)
            guard was != kind else { continue }
            if was == .bullet {
                local = removingMarker(at: local, in: edited)
            }
            if kind == .bullet {
                edited.replaceCharacters(
                    in: NSRange(location: local.location, length: 0),
                    with: SummaryText.bulletMarker
                )
                local.length += (SummaryText.bulletMarker as NSString).length
            }
            edited.addAttribute(
                SummaryText.blockKindKey, value: kind.rawValue, range: local
            )
        }
        edited.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: edited.length))
        guard shouldChangeText(in: union, replacementString: edited.string) else { return }
        storage.replaceCharacters(in: union, with: edited)
        didChangeText()
        setTypingAttributesFromCaret()
        invalidateDisplay(around: union)
    }

    /// Включить или снять выделение. `replacementString: nil` — правка только
    /// атрибутов; AppKit всё равно регистрирует шаг отмены.
    func toggleEmphasis(_ emphasis: SummaryText.Emphasis) {
        guard let storage = textStorage else { return }
        let range = selectedRange()
        guard range.length > 0 else { return }
        let turningOn = !hasEmphasis(emphasis, in: range)
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttribute(SummaryText.emphasisKey, in: range) { value, subrange, _ in
            var current = SummaryText.Emphasis(rawValue: value as? Int ?? 0)
            if turningOn { current.insert(emphasis) } else { current.remove(emphasis) }
            storage.addAttribute(SummaryText.emphasisKey, value: current.rawValue, range: subrange)
        }
        // `shouldChangeText` по выделенному иногда копирует wash selection в
        // storage как `backgroundColor` — снимаем сразу, не дожидаясь restyle.
        storage.removeAttribute(.backgroundColor, range: range)
        storage.endEditing()
        didChangeText()
        setTypingAttributesFromCaret()
        invalidateDisplay(around: range)
    }

    /// Заменить фрагмент, сохранив вид блока, в котором он лежал.
    ///
    /// `range` — куда класть ответ модели, когда выделения уже нет (его сняли
    /// в момент запроса). Без него — текущее выделение, как у обычной правки.
    ///
    /// Ответ модели проходит через `SummaryRewriteText`: одна строка, без
    /// списков и с `**жирным**` уже как атрибутом — иначе «Подробнее» режет
    /// блок переводами строк и оставляет bullet без диска.
    ///
    /// Возвращает диапазон вставленного. ⌘Z откатывает подстановку целиком:
    /// правка идёт через `shouldChangeText` / `didChangeText`.
    @discardableResult
    func replaceSelectionKeepingKind(with text: String, range: NSRange? = nil) -> NSRange? {
        let range = range ?? selectedRange()
        guard range.length > 0 else { return nil }
        let end = (string as NSString).length
        guard range.location >= 0, NSMaxRange(range) <= end else { return nil }
        let kind = SummaryText.kind(in: attributedString(), at: range.location)
        let spans = SummaryRewriteText.prepare(text)
        guard !spans.isEmpty else { return nil }
        let replacement = Self.attributed(spans: spans, kind: kind)
        guard shouldChangeText(in: range, replacementString: replacement.string)
        else { return nil }
        textStorage?.replaceCharacters(in: range, with: replacement)
        let inserted = NSRange(location: range.location, length: replacement.length)
        // Каретка до `didChangeText`: `textDidChange` → `restyle` сохранит её,
        // а не старое выделение, длины которого уже нет.
        setSelectedRange(NSRange(location: NSMaxRange(inserted), length: 0))
        didChangeText()
        setTypingAttributesFromCaret()
        return inserted
    }

    private static func attributed(
        spans: [SummaryDocument.Span], kind: SummaryDocument.Block.Kind
    ) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for span in spans {
            var emphasis: SummaryText.Emphasis = []
            if span.bold { emphasis.insert(.bold) }
            if span.italic { emphasis.insert(.italic) }
            out.append(NSAttributedString(string: span.text, attributes: [
                SummaryText.blockKindKey: kind.rawValue,
                SummaryText.emphasisKey: emphasis.rawValue,
            ]))
        }
        return out
    }

    // MARK: Что сейчас выделено

    func currentSelection() -> SummaryEditorController.Selection? {
        let range = selectedRange()
        guard range.length > 0, let storage = textStorage else { return nil }
        let text = (storage.string as NSString).substring(with: range)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let bounds = self.bounds(of: range) ?? .zero
        // Без маски глифов: она нужна только шиммеру rewrite, и строится в
        // `pinRewriteTarget`. Здесь — на каждый жест выделения — это лишняя
        // растеризация всего диапазона.
        return .init(
            kind: SummaryText.kind(in: storage, at: range.location),
            bold: hasEmphasis(.bold, in: range),
            italic: hasEmphasis(.italic, in: range),
            text: text,
            range: range,
            anchor: anchor(for: range),
            bounds: bounds,
            glyphs: nil
        )
    }

    /// Притушить диапазон, пока над ним думает модель. nil — вернуть всё.
    ///
    /// Временным атрибутом, а не правкой хранилища: `restyle` выводит цвет из
    /// токенов и затёр бы его на первом же проходе, а сохранение записало бы в
    /// файл цвет — которого в markdown нет и быть не может.
    func setDimmed(_ range: NSRange?) {
        guard let layout = layoutManager else { return }
        let whole = NSRange(location: 0, length: (string as NSString).length)
        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: whole)
        guard let range, range.length > 0 else { return }
        layout.addTemporaryAttribute(
            .foregroundColor, value: Tokens.Pane.Rewriting.dimmed, forCharacterRange: range
        )
    }

    /// Выделить текст первого блока такого вида, без маркера списка.
    func selectFirstBlock(of kind: SummaryDocument.Block.Kind) {
        guard let storage = textStorage, storage.length > 0 else { return }
        for range in SummaryText.paragraphRanges(in: storage.string) {
            guard SummaryText.kind(in: storage, at: range.location) == kind else { continue }
            var body = range
            let text = (storage.string as NSString).substring(with: body)
            if text.hasSuffix("\n") { body.length -= 1 }
            if text.hasPrefix(SummaryText.bulletMarker) {
                let marker = (SummaryText.bulletMarker as NSString).length
                body.location += marker
                body.length -= marker
            }
            guard body.length > 0 else { continue }
            setSelectedRange(body)
            coordinator?.controller.selection = currentSelection()
            return
        }
    }

    /// Прямоугольник, охватывающий диапазон, в координатах вьюхи.
    func bounds(of range: NSRange) -> CGRect? {
        guard let layout = layoutManager, let container = textContainer else { return nil }
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        var union: CGRect?
        layout.enumerateEnclosingRects(
            forGlyphRange: glyphs, withinSelectedGlyphRange: glyphs, in: container
        ) { rect, _ in
            union = union.map { $0.union(rect) } ?? rect
        }
        return union
    }

    /// Выделенные глифы, нарисованные на прозрачном, — маска для шиммера.
    ///
    /// `drawGlyphs` кладёт их тем же путём, каким рисуется сама вьюха, поэтому
    /// маска совпадает с текстом пиксель в пиксель. Цвет неважен: наружу уходит
    /// только форма. `drawingHandler`, не `lockFocus`: focus-стек на каждое
    /// выделение был лишней ценой и устаревшим API.
    func glyphMask(of range: NSRange, in bounds: CGRect) -> NSImage? {
        guard let layout = layoutManager, bounds.width > 0, bounds.height > 0 else { return nil }
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        let origin = CGPoint(x: -bounds.minX, y: -bounds.minY)
        return NSImage(size: bounds.size, flipped: true) { _ in
            layout.drawGlyphs(forGlyphRange: glyphs, at: origin)
            return true
        }
    }

    /// Левый нижний угол выделения — там, где кончается его последняя строка.
    private func anchor(for range: NSRange) -> CGPoint {
        guard let layout = layoutManager, let container = textContainer else { return .zero }
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var bottom = CGPoint.zero
        // Последний фрагмент, а не весь прямоугольник: выделение в три строки
        // должно вешать панель под третьей, а не по центру всех трёх.
        layout.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, _, _ in
            bottom = CGPoint(x: used.minX, y: used.maxY)
        }
        if bottom == .zero {
            let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            bottom = CGPoint(x: rect.minX, y: rect.maxY)
        }
        // Начало выделения, а не начало строки: панель встаёт под курсором.
        let first = layout.boundingRect(
            forGlyphRange: NSRange(location: glyphs.location, length: 1), in: container
        )
        return CGPoint(x: first.minX, y: bottom.y)
    }

    private func hasEmphasis(_ emphasis: SummaryText.Emphasis, in range: NSRange) -> Bool {
        guard let storage = textStorage, range.length > 0 else { return false }
        var everywhere = true
        storage.enumerateAttribute(SummaryText.emphasisKey, in: range) { value, subrange, stop in
            let text = (storage.string as NSString).substring(with: subrange)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            if !SummaryText.Emphasis(rawValue: value as? Int ?? 0).contains(emphasis) {
                everywhere = false
                stop.pointee = true
            }
        }
        return everywhere
    }

    // MARK: Каретка и оформление

    /// Каретка не заходит внутрь диска: щелчок в маркер ставит её за ним.
    ///
    /// Только когда маркер в абзаце действительно есть. Абзац с видом `bullet`
    /// без `•\t` (так ломало «Подробнее») сюда не входит: иначе каретка на
    /// каждом щелчке прыгает на два символа вперёд и интерфейс зависает.
    func keepCaretOutOfBulletMarker() {
        let range = selectedRange()
        guard range.length == 0, kindAtCaret() == .bullet else { return }
        let paragraph = paragraphRange(at: range.location)
        let marker = SummaryText.bulletMarker as NSString
        guard paragraph.length >= marker.length,
              (string as NSString).substring(with: paragraph).hasPrefix(SummaryText.bulletMarker)
        else { return }
        let floor = paragraph.location + marker.length
        guard range.location < floor else { return }
        setSelectedRange(NSRange(location: floor, length: 0))
    }

    /// Печать продолжает тот блок, в котором стоит каретка.
    func setTypingAttributesFromCaret() {
        let kind = kindAtCaret()
        let emphasis = emphasisAtCaret()
        typingAttributes = [
            .font: SummaryText.font(for: kind, emphasis: emphasis),
            .foregroundColor: Tokens.Pane.bodyNSColor,
            .paragraphStyle: SummaryText.paragraphStyle(for: kind, after: previousKind()),
            .kern: SummaryText.tracking(for: kind),
            SummaryText.blockKindKey: kind.rawValue,
            SummaryText.emphasisKey: emphasis.rawValue,
        ]
    }

    func restyle() {
        guard let storage = textStorage else { return }
        let selection = selectedRange()
        SummaryText.restyle(storage, colour: Tokens.Pane.bodyNSColor)
        setSelectedRange(selection)
    }

    // MARK: Мелочи про абзацы

    private func kindAtCaret() -> SummaryDocument.Block.Kind {
        guard let storage = textStorage, storage.length > 0 else { return .body }
        let location = min(max(0, selectedRange().location), storage.length - 1)
        return SummaryText.kind(in: storage, at: location)
    }

    private func previousKind() -> SummaryDocument.Block.Kind? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let paragraph = paragraphRange(at: selectedRange().location)
        guard paragraph.location > 0 else { return nil }
        return SummaryText.kind(in: storage, at: paragraph.location - 1)
    }

    private func emphasisAtCaret() -> SummaryText.Emphasis {
        guard let storage = textStorage, storage.length > 0 else { return [] }
        let location = min(max(0, selectedRange().location - 1), storage.length - 1)
        let value = storage.attribute(SummaryText.emphasisKey, at: location, effectiveRange: nil)
        return SummaryText.Emphasis(rawValue: value as? Int ?? 0)
    }

    private func paragraphRange(at location: Int) -> NSRange {
        let text = string as NSString
        guard text.length > 0 else { return NSRange(location: 0, length: 0) }
        return text.paragraphRange(for: NSRange(location: min(location, text.length), length: 0))
    }

    private func paragraphRanges(coveredBy range: NSRange) -> [NSRange] {
        let text = string as NSString
        guard text.length > 0 else { return [] }
        let full = text.paragraphRange(for: range)
        return SummaryText.paragraphRanges(in: text.substring(with: full)).map {
            NSRange(location: full.location + $0.location, length: $0.length)
        }
    }

    private func currentParagraphIsEmptyBullet() -> Bool {
        let paragraph = paragraphRange(at: selectedRange().location)
        let text = (string as NSString).substring(with: paragraph)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text == SummaryText.bulletMarker.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func convertParagraphToBody() {
        guard let storage = textStorage else { return }
        let paragraph = paragraphRange(at: selectedRange().location)
        let edited = NSMutableAttributedString(
            attributedString: storage.attributedSubstring(from: paragraph)
        )
        let stripped = removingMarker(
            at: NSRange(location: 0, length: edited.length), in: edited
        )
        edited.addAttribute(
            SummaryText.blockKindKey,
            value: SummaryDocument.Block.Kind.body.rawValue,
            range: stripped
        )
        guard shouldChangeText(in: paragraph, replacementString: edited.string) else { return }
        storage.replaceCharacters(in: paragraph, with: edited)
        setSelectedRange(NSRange(location: paragraph.location, length: 0))
        didChangeText()
        setTypingAttributesFromCaret()
    }

    /// Снять «•\t» с начала абзаца и вернуть его новые границы.
    private func removingMarker(at range: NSRange, in storage: NSMutableAttributedString) -> NSRange {
        let marker = SummaryText.bulletMarker as NSString
        guard range.length >= marker.length,
              (storage.string as NSString).substring(with: range).hasPrefix(SummaryText.bulletMarker)
        else { return range }
        storage.replaceCharacters(
            in: NSRange(location: range.location, length: marker.length), with: ""
        )
        return NSRange(location: range.location, length: range.length - marker.length)
    }

    private func setKindOfCurrentParagraph(_ kind: SummaryDocument.Block.Kind) {
        guard let storage = textStorage else { return }
        let paragraph = paragraphRange(at: selectedRange().location)
        guard paragraph.length > 0 else { return }
        storage.addAttribute(SummaryText.blockKindKey, value: kind.rawValue, range: paragraph)
    }

    /// Стереть возможные остатки wash выделения после смены метрик шрифта.
    private func invalidateDisplay(around range: NSRange) {
        guard let layout = layoutManager else {
            needsDisplay = true
            return
        }
        let end = (string as NSString).length
        guard range.location >= 0, range.length > 0, NSMaxRange(range) <= end else {
            needsDisplay = true
            return
        }
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        layout.invalidateDisplay(forGlyphRange: glyphs)
        needsDisplay = true
    }
}

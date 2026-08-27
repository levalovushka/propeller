import AppKit
import PropellerPure

/// # Документ саммари как текст, который правят
///
/// Между `SummaryDocument` (что написано) и `NSTextView` (во что тычут мышью)
/// нужен один слой, и он здесь: абзац текста ↔ блок документа, символ ↔ символ.
///
/// # Два своих атрибута вместо чтения шрифта
///
/// Вид блока и выделение хранятся отдельными атрибутами, а шрифт из них
/// *выводится*. Обратный порядок — узнавать жирность по начертанию — ломается
/// на первом же подзаголовке: он и так bold, и «жирное слово внутри
/// подзаголовка» становится неотличимо от самого подзаголовка. Атрибут знает
/// разницу, начертание — нет.
///
/// # Маркеров списка на экране нет
///
/// До 2026-08-27 пункт нёс настоящий символ «•\t» в тексте, а редактор стерёг
/// его от каретки. Макет 312:11129 маркеров не рисует вовсе: пункт «Решений» и
/// абзац под ними выглядят одинаково, различаются они только в файле («- »
/// против пустого начала). Решение владельца: маркеры в UI не едут — то место,
/// где они стояли, займут чекбокс и кружок слоя атомов, и рисовать сейчас диск,
/// чтобы через неделю заменить его на другой знак, незачем.
///
/// Из этого следует, что `bullet` и `body` на экране неразличимы, а в
/// выпадающем списке панели действий остаются оба. Это не тупик: галочка в том
/// же меню показывает, какой вид у блока сейчас, а сам вид меняет строку файла —
/// её потом собирают `RecapDigest` и MCP.
public enum SummaryText {

    /// Вид блока, на всём абзаце вместе с его переводом строки.
    public static let blockKindKey = NSAttributedString.Key("propellerSummaryBlockKind")
    /// Выделение внутри строки — `Emphasis.rawValue`.
    public static let emphasisKey = NSAttributedString.Key("propellerSummaryEmphasis")

    public struct Emphasis: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let bold = Emphasis(rawValue: 1 << 0)
        public static let italic = Emphasis(rawValue: 1 << 1)
    }

    // MARK: - Типографика вида блока

    public static func style(for kind: SummaryDocument.Block.Kind) -> Tokens.Typography.Style {
        switch kind {
        case .lead:    return Tokens.Pane.Typo.lead
        case .heading: return Tokens.Pane.Typo.sectionTitle
        case .body, .bullet: return Tokens.Pane.Typo.body
        }
    }

    public static func tracking(for kind: SummaryDocument.Block.Kind) -> CGFloat {
        switch kind {
        case .lead:    return Tokens.Pane.Typo.leadTracking
        case .heading: return Tokens.Pane.Typo.sectionTracking
        case .body, .bullet: return 0
        }
    }

    /// Сколько воздуха над абзацем — зазоры макета 312:11129.
    ///
    /// Три числа вместо прежних трёх, но по другому правилу: раздел отбивается
    /// от предыдущего на 36, его заголовок стоит в 8 над первым пунктом, а
    /// пункты внутри раздела — через 20. Абзац и пункт списка в макете
    /// неразличимы по ритму, поэтому у них один зазор, а не два.
    public static func spacingBefore(
        _ kind: SummaryDocument.Block.Kind, after previous: SummaryDocument.Block.Kind?
    ) -> CGFloat {
        guard let previous else { return 0 }
        if kind == .heading { return Tokens.Pane.summarySectionGap }
        if previous == .heading { return Tokens.Pane.summaryHeadingGap }
        return Tokens.Pane.summaryItemGap
    }

    /// Цвет вида блока. Тихий заголовок раздела — единственный, кто спорит с
    /// цветом, переданным снаружи: он не «текст потише», он подпись над
    /// текстом, и 30 % — часть его определения, а не настройка вызывающего.
    public static func colour(for kind: SummaryDocument.Block.Kind, body: NSColor) -> NSColor {
        kind == .heading ? Tokens.Pane.headingNSColor : body
    }

    static func paragraphStyle(
        for kind: SummaryDocument.Block.Kind, after previous: SummaryDocument.Block.Kind?
    ) -> NSParagraphStyle {
        let style = paragraph(for: kind)
        style.paragraphSpacingBefore = spacingBefore(kind, after: previous)
        return style
    }

    private static func paragraph(for kind: SummaryDocument.Block.Kind) -> NSMutableParagraphStyle {
        let typography = style(for: kind)
        let paragraph = NSMutableParagraphStyle()
        // `lineSpacing` не бывает отрицательным, а у лида нарисованная строка
        // может быть выше заданной (SF Pro vs макетный LH). Ужимать нечем —
        // остаётся не добавлять.
        paragraph.lineSpacing = max(0, typography.lineHeight - typography.renderedLineHeight)
        return paragraph
    }

    static func font(for kind: SummaryDocument.Block.Kind, emphasis: Emphasis) -> NSFont {
        let base = style(for: kind).nsFont
        var traits: NSFontTraitMask = []
        if emphasis.contains(.bold) { traits.insert(.boldFontMask) }
        if emphasis.contains(.italic) { traits.insert(.italicFontMask) }
        guard !traits.isEmpty else { return base }
        return NSFontManager.shared.convert(base, toHaveTrait: traits)
    }

    // MARK: - Документ → текст

    public static func attributed(
        _ document: SummaryDocument, colour: NSColor
    ) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        for (index, block) in document.blocks.enumerated() {
            let start = out.length
            for span in block.spans {
                var emphasis: Emphasis = []
                if span.bold { emphasis.insert(.bold) }
                if span.italic { emphasis.insert(.italic) }
                out.append(NSAttributedString(
                    string: span.text,
                    attributes: [emphasisKey: emphasis.rawValue]
                ))
            }
            // Перевод строки входит в абзац, который он закрывает: каретка в
            // конце строки должна знать, в каком блоке она стоит.
            if index < document.blocks.count - 1 {
                out.append(NSAttributedString(string: "\n"))
            }
            out.addAttribute(blockKindKey, value: block.kind.rawValue,
                             range: NSRange(location: start, length: out.length - start))
        }
        restyle(out, colour: colour)
        return out
    }

    // MARK: - Пересчёт оформления

    /// Заново вывести шрифты, отступы и цвет из видов блоков и выделений.
    ///
    /// Целиком, а не по диапазону правки: зазор над абзацем зависит от того, что
    /// было *до* него, поэтому смена вида одного блока меняет оформление
    /// соседнего. Саммари — это десятки абзацев; полный проход дешевле, чем
    /// вычисление затронутой окрестности, и не умеет ошибиться.
    ///
    /// Снимает и `backgroundColor`: правка атрибутов по *выделенному* диапазону
    /// (`shouldChangeText` + bold) иногда запекает wash выделения из
    /// `selectedTextAttributes` в storage. После снятия selection остаются
    /// тонкие полоски сверху и снизу слова — это не рамка, а края того фона.
    public static func restyle(_ text: NSMutableAttributedString, colour: NSColor) {
        guard text.length > 0 else { return }
        let whole = NSRange(location: 0, length: text.length)
        text.beginEditing()
        text.removeAttribute(.backgroundColor, range: whole)
        var previous: SummaryDocument.Block.Kind?
        for range in paragraphRanges(in: text.string) {
            let kind = self.kind(in: text, at: range.location)
            text.addAttributes([
                .paragraphStyle: paragraphStyle(for: kind, after: previous),
                .foregroundColor: self.colour(for: kind, body: colour),
                .kern: tracking(for: kind),
            ], range: range)
            text.enumerateAttribute(emphasisKey, in: range) { value, subrange, _ in
                let emphasis = Emphasis(rawValue: value as? Int ?? 0)
                text.addAttribute(.font, value: font(for: kind, emphasis: emphasis), range: subrange)
            }
            previous = kind
        }
        text.endEditing()
    }

    /// Вид блока, в котором лежит позиция. Незнакомое значение — обычный текст:
    /// вставка из буфера приходит вообще без наших атрибутов.
    public static func kind(in text: NSAttributedString, at location: Int) -> SummaryDocument.Block.Kind {
        guard location < text.length,
              let raw = text.attribute(blockKindKey, at: location, effectiveRange: nil) as? String,
              let kind = SummaryDocument.Block.Kind(rawValue: raw)
        else { return .body }
        return kind
    }

    /// Границы абзацев, включая перевод строки в конце каждого.
    public static func paragraphRanges(in string: String) -> [NSRange] {
        let text = string as NSString
        guard text.length > 0 else { return [] }
        var out: [NSRange] = []
        var location = 0
        while location < text.length {
            let range = text.paragraphRange(for: NSRange(location: location, length: 0))
            guard range.length > 0 else { break }
            out.append(range)
            location = NSMaxRange(range)
        }
        return out
    }

    // MARK: - Текст → документ

    public static func document(
        from text: NSAttributedString, leadHeading: String?
    ) -> SummaryDocument {
        var blocks: [SummaryDocument.Block] = []
        for (index, range) in paragraphRanges(in: text.string).enumerated() {
            let kind = self.kind(in: text, at: range.location)
            var body = range
            // Перевод строки принадлежит абзацу, но не его тексту.
            if body.length > 0, (text.string as NSString).substring(with: body).hasSuffix("\n") {
                body.length -= 1
            }
            guard body.length > 0 else { continue }
            let spans = self.spans(in: text, range: body)
            guard !spans.isEmpty else { continue }
            blocks.append(.init(id: "b\(index)", kind: kind, spans: spans))
        }
        return SummaryDocument(blocks: blocks, leadHeading: leadHeading)
    }

    private static func spans(in text: NSAttributedString, range: NSRange) -> [SummaryDocument.Span] {
        var out: [SummaryDocument.Span] = []
        text.enumerateAttribute(emphasisKey, in: range) { value, subrange, _ in
            let emphasis = Emphasis(rawValue: value as? Int ?? 0)
            let string = (text.string as NSString).substring(with: subrange)
            guard !string.isEmpty else { return }
            // Соседние отрезки с одинаковым выделением — один отрезок: иначе
            // каждая правка дробила бы строку на всё более мелкие куски.
            if var last = out.last,
               last.bold == emphasis.contains(.bold),
               last.italic == emphasis.contains(.italic) {
                last.text += string
                out[out.count - 1] = last
            } else {
                out.append(.init(string,
                                 bold: emphasis.contains(.bold),
                                 italic: emphasis.contains(.italic)))
            }
        }
        guard out.contains(where: { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }) else { return [] }
        return out
    }
}

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
/// # Диск списка — настоящий символ
///
/// TextKit сам маркеры не рисует: `NSTextList` только описывает список, рисует
/// его тот, кто вставил маркер в строку. Поэтому «•\t» лежит в тексте, а
/// редактор стережёт его от каретки (`SummaryTextView`), и обратный разбор его
/// снимает. Альтернатива — рисовать диски поверх, вычисляя позиции строк, —
/// разъезжается на первом же переносе.
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

    /// Маркер пункта и его табуляция до втяжки.
    public static let bulletMarker = "•\t"

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

    /// Сколько воздуха над абзацем — ровно те же зазоры, что были у стопки
    /// `VStack`, которую редактор заменил.
    public static func spacingBefore(
        _ kind: SummaryDocument.Block.Kind, after previous: SummaryDocument.Block.Kind?
    ) -> CGFloat {
        guard let previous else { return 0 }
        if kind == .heading { return Tokens.Pane.summaryBlockGap }
        if previous == .lead || previous == .heading { return Tokens.Pane.summaryLineGap }
        return Tokens.Pane.bulletGap
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
        if kind == .bullet {
            paragraph.headIndent = Tokens.Pane.bulletIndent
            paragraph.firstLineHeadIndent = 0
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: Tokens.Pane.bulletIndent)]
            paragraph.defaultTabInterval = Tokens.Pane.bulletIndent
        }
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
            if block.kind == .bullet {
                out.append(NSAttributedString(string: bulletMarker))
            }
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
                .foregroundColor: colour,
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
            if kind == .bullet, (text.string as NSString).substring(with: body).hasPrefix(bulletMarker) {
                body.location += (bulletMarker as NSString).length
                body.length -= (bulletMarker as NSString).length
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

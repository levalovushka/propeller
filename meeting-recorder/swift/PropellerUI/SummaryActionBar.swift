import SwiftUI
import PropellerPure

/// # Панель действий над выделением
///
/// Появляется под курсором, когда что-то выделено, и уезжает, когда выделение
/// снято. Это не полоса над интерфейсом, которую приложение подняло само
/// (такой в Propeller нет, `design/notifications.md`), а инструмент, вызванный
/// жестом: пока его не позвали, его не существует.
///
/// # Почему в ряд
///
/// Вертикальное меню заставляет читать список, чтобы найти «жирный». Ряд
/// показывает всё сразу и занимает одну строку — а выделив текст, человек уже
/// знает, чего хочет, и ищет не название, а место, куда попасть мышью.
///
/// Три группы, разделённые чертой: чем стал абзац, как выглядит слово, что с
/// текстом сделает модель. Порядок — от структуры к смыслу.
public struct SummaryActionBar: View {
    private let selection: SummaryEditorController.Selection
    private let onKind: (SummaryDocument.Block.Kind) -> Void
    private let onBold: () -> Void
    private let onItalic: () -> Void
    private let onRewrite: ((SummaryRewrite) -> Void)?

    public init(
        selection: SummaryEditorController.Selection,
        onKind: @escaping (SummaryDocument.Block.Kind) -> Void,
        onBold: @escaping () -> Void,
        onItalic: @escaping () -> Void,
        onRewrite: ((SummaryRewrite) -> Void)? = nil
    ) {
        self.selection = selection
        self.onKind = onKind
        self.onBold = onBold
        self.onItalic = onItalic
        self.onRewrite = onRewrite
    }

    /// Стекло, угол и тень — в `SummonedPlate`, общей с переключателем встреч:
    /// это один предмет приложения в двух ролях, и выглядеть он обязан одинаково.
    /// Здесь остаётся только ряд.
    public var body: some View {
        SummonedPlate(minHeight: Tokens.Pane.Bar.height) {
            HStack(spacing: Tokens.Pane.Bar.groupGap) {
                kindMenu
                divider
                HStack(spacing: Tokens.Pane.Bar.itemGap) {
                    BarIcon(symbol: "bold", help: "Полужирный", isOn: selection.bold, action: onBold)
                    BarIcon(symbol: "italic", help: "Курсив", isOn: selection.italic, action: onItalic)
                }
                // Без модели этой группы просто нет: кнопка, которая не может
                // сработать, — хуже отсутствующей.
                if let onRewrite {
                    divider
                    HStack(spacing: Tokens.Pane.Bar.itemGap) {
                        ForEach(SummaryRewrite.allCases, id: \.self) { rewrite in
                            BarLabel(title: rewrite.title) { onRewrite(rewrite) }
                        }
                    }
                }
            }
        }
        .fixedSize()
    }

    private var divider: some View {
        Rectangle()
            .fill(Tokens.Pane.Bar.divider)
            .frame(width: 1, height: Tokens.Pane.Bar.dividerHeight)
    }

    /// Чем стал этот абзац. Меню, а не переключатели в ряд: видов четыре, и
    /// четыре кнопки заняли бы больше места, чем все остальные действия вместе.
    private var kindMenu: some View {
        KindMenu(
            title: selection.kind.title,
            current: selection.kind,
            onKind: onKind
        )
    }
}

/// Что модель сделает с выделенным.
///
/// Две разные операции, а не одна с знаком: «короче» работает с тем, что уже
/// написано, «подробнее» — с тем, что было сказано на встрече. Поэтому вторая
/// берёт транскрипт, а первая нет.
public enum SummaryRewrite: String, CaseIterable, Sendable {
    case shorter, longer

    public var title: String {
        switch self {
        case .shorter: return "Короче"
        case .longer:  return "Подробнее"
        }
    }

    /// Нужен ли транскрипт. «Подробнее» без него может только развести воду:
    /// подробностей во фрагменте по определению нет, иначе он не был бы коротким.
    public var needsTranscript: Bool {
        switch self {
        case .shorter: return false
        case .longer:  return true
        }
    }

    /// Задание модели. Здесь, а не у вызывающего: формулировка — это копирайт,
    /// и он живёт в одном месте.
    public var instruction: String {
        switch self {
        case .shorter:
            return """
            Сожми фрагмент: та же мысль, заметно меньше слов — цель примерно \
            вдвое короче исходного, и в любом случае короче, чем было. \
            Не перефразируй длиннее и не «улучшай» стиль: только вырежи лишнее. \
            Работай только с тем, что во фрагменте, — ничего не добавляй и не уточняй. \
            Если уж почти нечего вырезать, всё равно верни более короткий вариант, \
            а не тот же текст другими словами. \
            Верни один абзац: без списков, без заголовков и без пустых строк.
            """
        case .longer:
            return """
            Разверни фрагмент, опираясь на расшифровку встречи: найди в ней, что ещё \
            говорили по этому месту, и добавь недостающие детали — числа, имена, сроки, \
            причины. Не выдумывай ничего, чего в расшифровке нет; если добавить нечего, \
            верни фрагмент без изменений. \
            Верни один абзац: без списков, без заголовков и без пустых строк.
            """
        }
    }
}

// MARK: - Кнопки панели

/// Селектор вида блока — тот же pill-hover, что у «Короче» / B / I.
private struct KindMenu: View {
    let title: String
    let current: SummaryDocument.Block.Kind
    let onKind: (SummaryDocument.Block.Kind) -> Void

    @State private var hovering = false

    var body: some View {
        Menu {
            ForEach(SummaryDocument.Block.Kind.allCases, id: \.self) { kind in
                Button {
                    onKind(kind)
                } label: {
                    if kind == current {
                        Label(kind.title, systemImage: "checkmark")
                    } else {
                        Text(kind.title)
                    }
                }
            }
        } label: {
            HStack(spacing: Tokens.Pane.Bar.menuChevronGap) {
                Text(title)
                    .typo(Tokens.Pane.Bar.labelType)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: Tokens.Pane.Bar.menuChevronSize, weight: .regular))
            }
            .foregroundStyle(Tokens.Pane.Bar.label)
            .frame(height: Tokens.Pane.Bar.itemHeight)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        // Pad outside `Menu`: system chrome eats inner leading otherwise.
        .padding(.horizontal, Tokens.Pane.Bar.itemHPadding)
        .background(
            hovering ? Tokens.Pane.Bar.itemHoverFill : .clear,
            in: RoundedRectangle(cornerRadius: Tokens.Pane.Bar.itemRadius, style: .continuous)
        )
        .frame(height: Tokens.Pane.Bar.itemHeight)
        .fixedSize()
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.Motion.hover), value: hovering)
    }
}

private struct BarIcon: View {
    let symbol: String
    let help: String
    let isOn: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: Tokens.Pane.Bar.itemIconSize, weight: .regular))
                .foregroundStyle(Tokens.Pane.Bar.label)
                .frame(width: Tokens.Pane.Bar.itemHeight, height: Tokens.Pane.Bar.itemHeight)
                .background(fill, in: RoundedRectangle(cornerRadius: Tokens.Pane.Bar.itemRadius,
                                                       style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.Motion.hover), value: hovering)
        .animation(.easeOut(duration: Tokens.Motion.hover), value: isOn)
        .help(help)
        .accessibilityLabel(help)
    }

    private var fill: Color {
        if isOn { return Tokens.Pane.Bar.itemOnFill }
        return hovering ? Tokens.Pane.Bar.itemHoverFill : .clear
    }
}

private struct BarLabel: View {
    let title: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .typo(Tokens.Pane.Bar.labelType)
                .foregroundStyle(Tokens.Pane.Bar.label)
                .lineLimit(1)
                .frame(height: Tokens.Pane.Bar.itemHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Pad outside the label — same place as `kindMenu`, so left and right
        // edges of the bar breathe the same amount.
        .padding(.horizontal, Tokens.Pane.Bar.itemHPadding)
        .background(
            hovering ? Tokens.Pane.Bar.itemHoverFill : .clear,
            in: RoundedRectangle(cornerRadius: Tokens.Pane.Bar.itemRadius, style: .continuous)
        )
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.Motion.hover), value: hovering)
    }
}

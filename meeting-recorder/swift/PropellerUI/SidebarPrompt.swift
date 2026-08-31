import SwiftUI

/// The block docked at the foot of the rail — Figma 91:794 (calendar) / 91:882 (name).
///
/// It is where the two questions that are not permissions ended up. Both were
/// screens in the old onboarding; neither blocks anything, so neither earns a
/// screen. Asked here they arrive *after* the app is on screen, next to the list
/// they would improve, which is the only place either question makes sense.
///
/// One at a time, with a «1/2» so the block says how long it is. Which step is
/// showing is decided by `SetupPromptMachine`, not here.
public struct SidebarPromptModel: Equatable, Sendable {

    /// The two shapes a question can take, and there are deliberately only two.
    public enum Action: Equatable, Sendable {
        /// A pill that goes and does something — «Подключить».
        case button(String)
        /// A field that takes the answer itself — «Ваше имя», submitted with ⏎.
        case field(placeholder: String)
    }

    /// The step this block is asking, from `SetupPrompt.rawValue`. Handed back on
    /// every event so the window knows which question was answered without
    /// re-deriving it.
    public let id: String
    public let title: String
    public let subtitle: String
    /// «1/2».
    public let counter: String
    public let action: Action

    public init(id: String, title: String, subtitle: String, counter: String, action: Action) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.counter = counter
        self.action = action
    }
}

// MARK: - The block

struct SidebarPromptBlock: View {
    let model: SidebarPromptModel
    let onAction: (String) -> Void
    let onSubmit: (String, String) -> Void

    @State private var typed = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.RailPrompt.blockGap) {
            head
            control
        }
        .padding(Tokens.RailPrompt.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Blur first, wash over it: the list behind the block stays legible as
        // texture, which is what keeps this a plate on glass rather than a hole
        // cut in the rail.
        .background {
            RoundedRectangle(cornerRadius: Tokens.RailPrompt.radius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: Tokens.RailPrompt.radius, style: .continuous)
                        .fill(Tokens.RailPrompt.fill)
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.RailPrompt.radius, style: .continuous)
                .strokeBorder(Tokens.RailPrompt.border, lineWidth: 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: Tokens.RailPrompt.radius, style: .continuous))
        // Смена вопроса **стирает** набранное — и это сознательно наоборот к
        // `MeetingPaneIdentity`, которая на той же развилке сначала коммитит.
        // Там смена — это «то же поле, другая встреча», и текст принадлежит
        // прошлой. Здесь шаги идут строго по возрастанию (`SetupPrompt.index`),
        // и вопрос про имя уходит с экрана ровно тогда, когда на него ответили
        // **где-то ещё** — полем в настройках. Коммит на этой развилке затирал
        // бы только что названное имя недонабранным.
        .onChange(of: model.id) { _, _ in typed = "" }
        // А снос блока — это не ответ ни от кого, и вот тут набранное надо
        // сохранить: блок сносит тумблер рельса и любой уход с экрана, где он
        // стоит, а поле у него одно и своего «Отменить» нет.
        //
        // Уходом каретки не коммитим, и это отличие от поля тега в настройках
        // названо вслух: там подтверждение добавляет слово в список, который
        // человек тут же видит, а здесь оно закрывает шаг мастера и запекает имя
        // во все будущие расшифровки. Блок при этом от клика мимо никуда не
        // девается и продолжает спрашивать — с набранным текстом на месте.
        .onDisappear { submit() }
    }

    private var head: some View {
        HStack(alignment: .top, spacing: Tokens.RailPrompt.counterGap) {
            VStack(alignment: .leading, spacing: 0) {
                Text(model.title)
                    .typoBlock(Tokens.RailPrompt.Typo.head)
                    .foregroundStyle(Tokens.RailPrompt.title)
                Text(model.subtitle)
                    .typoBlock(Tokens.RailPrompt.Typo.head)
                    .foregroundStyle(Tokens.RailPrompt.subtitle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(model.counter)
                .typoBlock(Tokens.RailPrompt.Typo.head, monospacedDigit: true)
                .foregroundStyle(Tokens.RailPrompt.counter)
        }
    }

    @ViewBuilder
    private var control: some View {
        switch model.action {
        case .button(let title):
            SidebarPromptButton(title: title) { onAction(model.id) }
        case .field(let placeholder):
            field(placeholder: placeholder)
        }
    }

    private func field(placeholder: String) -> some View {
        HStack(spacing: Tokens.RailPrompt.fieldGlyphGap) {
            TextField("", text: $typed, prompt: promptText(placeholder))
                .textFieldStyle(.plain)
                .typo(Tokens.RailPrompt.Typo.field)
                .foregroundStyle(Tokens.RailPrompt.controlLabel)
                .focused($focused)
                .onSubmit(submit)
                .padding(.horizontal, Tokens.RailPrompt.fieldTextInset)
                .frame(maxWidth: .infinity, alignment: .leading)

            // A glyph that is also the button, so ⏎ and the pointer answer the
            // same way. Quiet until there is something to submit — an arrow that
            // is always lit promises a press that does nothing.
            Button(action: submit) {
                Image(systemName: "return.left")
                    .font(.system(size: Tokens.RailPrompt.fieldGlyphSize, weight: .regular))
                    .foregroundStyle(canSubmit
                                     ? Tokens.RailPrompt.controlLabel
                                     : Tokens.RailPrompt.fieldGlyph)
                    .frame(width: Tokens.Space.s16, height: Tokens.Space.s16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.press)
            .disabled(!canSubmit)
            .accessibilityLabel("Сохранить имя")
        }
        .padding(.horizontal, Tokens.RailPrompt.controlHPadding)
        .frame(height: Tokens.RailPrompt.controlHeight)
        .background(
            Tokens.RailPrompt.controlFill,
            in: RoundedRectangle(cornerRadius: Tokens.RailPrompt.controlRadius, style: .continuous)
        )
        // The block appears while the window is already up, so the field takes
        // focus on its own — the question is the only thing that just moved.
        .onAppear { focused = true }
    }

    private func promptText(_ placeholder: String) -> Text {
        Text(placeholder)
            .font(Tokens.RailPrompt.Typo.field.font)
            .foregroundStyle(Tokens.RailPrompt.fieldPlaceholder)
    }

    /// Набранное как ответ, или `nil` — отвечать нечем.
    static func resolve(_ typed: String) -> String? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var answer: String? { Self.resolve(typed) }
    private var canSubmit: Bool { answer != nil }

    private func submit() {
        guard let answer else { return }
        // Черновик израсходован **до** того, как ответ уйдёт наружу: ответ
        // меняет шаг и обычно сносит сам блок, а `onDisappear` читает `typed` —
        // оставленный там текст уехал бы вторым ответом, которого никто не давал.
        typed = ""
        onSubmit(model.id, answer)
    }
}

/// «Подключить» — the full width of the block, 36 pt.
private struct SidebarPromptButton: View {
    let title: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .typo(Tokens.RailPrompt.Typo.head)
                .foregroundStyle(Tokens.RailPrompt.controlLabel)
                .frame(maxWidth: .infinity)
                .frame(height: Tokens.RailPrompt.controlHeight)
                .background(
                    hovering ? Tokens.RailPrompt.controlHoverFill : Tokens.RailPrompt.controlFill,
                    in: RoundedRectangle(cornerRadius: Tokens.RailPrompt.controlRadius, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: Tokens.RailPrompt.controlRadius, style: .continuous))
        }
        .buttonStyle(.press)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.Motion.hover), value: hovering)
    }
}

// MARK: - Height

/// How much of the rail's foot the docked block takes, measured rather than
/// stated — a wrapping subtitle makes the block taller, and the list's bottom
/// clear zone has to move with it.
struct SidebarPromptHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

#Preview("Rail prompt — calendar") {
    SidebarPromptBlock(
        model: SidebarPromptModel(
            id: "calendar",
            title: "Подключите календарь",
            subtitle: "Возьмём там встречи и имена",
            counter: "1/2",
            action: .button("Подключить")
        ),
        onAction: { _ in },
        onSubmit: { _, _ in }
    )
    .frame(width: Tokens.Sidebar.width - Tokens.RailPrompt.inset * 2)
    .padding(24)
    .background(GlassBackground())
}

#Preview("Rail prompt — name") {
    SidebarPromptBlock(
        model: SidebarPromptModel(
            id: "name",
            title: "Как вас зовут?",
            subtitle: "Учтём в расшифровках",
            counter: "2/2",
            action: .field(placeholder: "Ваше имя")
        ),
        onAction: { _ in },
        onSubmit: { _, _ in }
    )
    .frame(width: Tokens.Sidebar.width - Tokens.RailPrompt.inset * 2)
    .padding(24)
    .background(GlassBackground())
}

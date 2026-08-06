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
        // Re-arm for the next question rather than carrying the last one's text.
        .onChange(of: model.id) { _, _ in typed = "" }
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
            .buttonStyle(.plain)
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

    private var trimmed: String { typed.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSubmit: Bool { !trimmed.isEmpty }

    private func submit() {
        guard canSubmit else { return }
        onSubmit(model.id, trimmed)
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
        .buttonStyle(.plain)
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

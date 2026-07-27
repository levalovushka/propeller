import SwiftUI
import AppKit

/// Name step — Figma 642:2199. Centred title + pill field (200×36).
/// Uses standard SwiftUI `TextField`; panel must be keyable (see OnboardingPanel).
struct OnboardingNameView: View {
    var onNext: (String) -> Void
    var onBack: () -> Void

    @State private var name = NSFullUserName()
    @FocusState private var focused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canProceed: Bool { !trimmed.isEmpty }

    var body: some View {
        OnboardingCard {
            OnboardingBackButton(action: onBack)
        } content: {
            VStack(spacing: Tokens.Card.contentGap) {
                OnboardText.title("Как вас подписывать\nв расшифровках?")
                    .fixedSize(horizontal: false, vertical: true)
                nameField
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } actions: {
            HStack {
                nextButton
            }
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            focused = true
            // Focus selects the whole prefilled name; collapse after the field editor attaches.
            DispatchQueue.main.async {
                DispatchQueue.main.async { collapseFieldSelectionToEnd() }
            }
        }
        .onChange(of: focused) { _, isFocused in
            if isFocused {
                DispatchQueue.main.async {
                    DispatchQueue.main.async { collapseFieldSelectionToEnd() }
                }
            }
        }
    }

    private var nameField: some View {
        TextField("Ваше имя", text: $name)
            .textFieldStyle(.plain)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Tokens.Ink.primary)
            .focused($focused)
            .onSubmit { submitIfReady() }
            .padding(.horizontal, 16)
            .frame(width: 200, height: Tokens.Pill.height, alignment: .leading)
            .background(Color.white.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: Tokens.Pill.radius, style: .continuous))
    }

    @ViewBuilder private var nextButton: some View {
        if canProceed {
            PillButton(title: "Далее", kind: .primary) { submitIfReady() }
        } else {
            Text("Далее")
                .font(.pillLabel)
                .foregroundStyle(Tokens.Ink.tertiary)
                .padding(.horizontal, Tokens.Pill.hPadding)
                .padding(.vertical, Tokens.Pill.vPadding)
                .frame(height: Tokens.Pill.height)
                .background(Color.white.opacity(0.07),
                            in: RoundedRectangle(cornerRadius: Tokens.Pill.radius, style: .continuous))
        }
    }

    private func submitIfReady() {
        guard canProceed else { return }
        onNext(trimmed)
    }

    /// Drop the default select-all on focus; leave a caret at the end of the name.
    private func collapseFieldSelectionToEnd() {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
        let end = (editor.string as NSString).length
        editor.setSelectedRange(NSRange(location: end, length: 0))
    }
}

#Preview("Name") {
    OnboardingNameView(onNext: { _ in }, onBack: {})
        .background(GlassBackground())
}

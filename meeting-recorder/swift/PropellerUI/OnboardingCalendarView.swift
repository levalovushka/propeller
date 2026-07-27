import SwiftUI

/// Which calendar the user picked. Google needs an extra step: Propeller reads
/// calendars through macOS (EventKit), so a Google calendar only shows up once
/// the account is added in System Settings → Internet Accounts. There is no
/// OAuth in the app and no cloud round-trip — that's the local-first design.
public enum CalendarProvider: Sendable {
    case mac
    case google
}

/// Calendar step — Figma 642:2236. Provider chips live in the content stack;
/// the action row is just Skip (or Next once access is actually granted).
struct OnboardingCalendarView: View {
    var onNext: () -> Void
    var onSkip: () -> Void
    var onBack: () -> Void
    /// True only when EventKit access is really granted — not merely tapped.
    var calendarGranted: Bool = false
    var onConnect: (CalendarProvider) -> Void = { _ in }

    /// Set after tapping Google so the "add the account first" hint appears.
    @State private var showGoogleHint = false

    var body: some View {
        OnboardingCard {
            OnboardingBackButton(action: onBack)
        } content: {
            VStack(spacing: Tokens.Card.contentGap) {
                VStack(spacing: Tokens.Card.textGap) {
                    OnboardText.title("Встречи и имена\nлучше из календаря")
                        .fixedSize(horizontal: false, vertical: true)
                    OnboardText.body("Только чтение, ничего не уходит в облако.")
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: Tokens.Pill.rowGap) {
                    if calendarGranted {
                        PillButton(title: "Календарь подключён", kind: .secondary,
                                   leadingSymbol: "checkmark") {}
                    } else {
                        PillButton(title: "Подключить календарь", kind: .secondary,
                                   leadingSymbol: "plus") { connect(.mac) }
                    }
                }

                Text("Читаем Календарь macOS (EventKit). Google и Exchange — через Системные настройки → Учётные записи. Без OAuth и без облака.")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Tokens.Ink.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if showGoogleHint && !calendarGranted {
                    Text("Если нужен именно Google: добавьте аккаунт в «Учётные записи», включите Календари — и нажмите снова.")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Tokens.Ink.tertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } actions: {
            HStack {
                if calendarGranted {
                    PillButton(title: "Далее", kind: .primary, action: onNext)
                } else {
                    PillButton(title: "Пропустить", kind: .ghost, action: onSkip)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func connect(_ provider: CalendarProvider) {
        onConnect(provider)
        withAnimation(.easeInOut(duration: 0.2)) {
            showGoogleHint = (provider == .google)
        }
    }
}

#Preview("Calendar") {
    OnboardingCalendarView(onNext: {}, onSkip: {}, onBack: {})
        .background(GlassBackground())
}

import SwiftUI

/// # Пустой архив — это приглашение, а не сообщение
///
/// То, что стоит в окне, пока записывать было нечего. Раньше здесь было слово
/// «Пока нет встреч», и оно стояло **дважды**: в рельсе и в панели, потому что
/// обе колонки пусты по одной и той же причине. Два серых сообщения об одном и
/// том же отсутствии — и ни одного способа это отсутствие прекратить.
///
/// Поэтому экран занимает окно целиком, вместо рельса и панели, а не поверх них:
/// колонки, в которых нечего показать, — не фон для приглашения, а то, что
/// приглашение заменяет. Стекло окна остаётся под ним, своего фона у экрана нет.
///
/// # Это состояние, а не шаг
///
/// Он приходит не «после настройки», а всякий раз, когда список пуст, — в том
/// числе через полгода, если все встречи удалили. Отсюда и текст: ни слова о
/// первом запуске, ничего, что было бы неправдой на второй раз.
///
/// Чистая презентация, как и вся `PropellerUI`: знает текст и одно замыкание.
/// Что именно делает кнопка — начинает запись или ведёт в разрешения — решает
/// окно, а не этот файл.
public struct FirstRunView: View {
    private let title: String
    private let subtitle: String
    private let actionTitle: String
    private let onAction: () -> Void

    public init(
        title: String = "Добро пожаловать.\nЗапишем первую встречу?",
        subtitle: String = "Запись, расшифровка и\u{00A0}саммари —\nвсё остаётся на\u{00A0}этом Mac",
        actionTitle: String = "Начать запись",
        onAction: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.actionTitle = actionTitle
        self.onAction = onAction
    }

    public var body: some View {
        VStack(spacing: 0) {
            SetupMark(size: Tokens.FirstRun.markSize)

            Spacer().frame(height: Tokens.FirstRun.markGap)
            SetupText.title(title, alignment: .center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Tokens.FirstRun.measure)

            Spacer().frame(height: Tokens.FirstRun.subtitleGap)
            Text(subtitle)
                .typoBlock(Tokens.Setup.Typo.cell)
                .multilineTextAlignment(.center)
                .foregroundStyle(Tokens.Setup.cellSubtitle)

            Spacer().frame(height: Tokens.FirstRun.actionGap)
            FirstRunActionButton(title: actionTitle, action: onAction)
        }
        // Центр окна, а не центр того, что осталось от окна: экран и есть окно.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// «Начать запись» — та же кнопка, что на плите настройки, но по размеру текста.
///
/// Растянутая по ширине она там потому, что стоит в колонке шириной 360 и
/// закрывает её подошву. Здесь колонки нет и подошвы нет: кнопка стоит в пустом
/// окне, и растянуть её было бы не на что — она бы просто стала полосой.
private struct FirstRunActionButton: View {
    let title: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .typo(Tokens.Setup.Typo.action)
                .foregroundStyle(Tokens.Setup.controlLabel)
                .padding(.horizontal, Tokens.FirstRun.actionHPadding)
                .frame(height: Tokens.Setup.actionHeight)
                .background(
                    hovering ? Tokens.Setup.controlHoverFill : Tokens.Setup.controlFill,
                    in: RoundedRectangle(cornerRadius: Tokens.Setup.actionRadius, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: Tokens.Setup.actionRadius, style: .continuous))
        }
        .buttonStyle(.press)
        .keyboardShortcut(.defaultAction)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.Motion.hover), value: hovering)
    }
}

#Preview("First run") {
    FirstRunView(onAction: {})
        .frame(width: 940, height: 700)
}

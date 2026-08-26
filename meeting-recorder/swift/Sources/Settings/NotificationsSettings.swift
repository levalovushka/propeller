import SwiftUI
import AppKit
import PropellerUI
import PropellerPure

/// Чем приложение себя показывает, пока окно закрыто.
///
/// Две поверхности и два выключателя, и оба — про видимость, а не про запись.
/// Заголовка у карточки нет: он назвал бы «Уведомления» второй раз (§5.5).
///
/// Системного разрешения на уведомления здесь пока нет, хотя в макете строка
/// есть: это не переключатель предпочтения, а разрешение macOS, и спрашивают
/// его сегодня только в онбординге (`OnboardingContainer`). Хвост записан.
struct NotificationsSettingsPage: View {
    @AppStorage("menuBarIconVisible") private var menuBarIconVisible = true
    @AppStorage("notchIndicator") private var notchIndicator = true

    var body: some View {
        SettingsPage(SettingsSection.notifications.title) {
            SettingsCard {
                // Единственная поверхность, которую приложение рисует поверх
                // чужих окон, — единственная, у которой есть выключатель.
                // Подпись меняется вместе с железом: на маке без выреза
                // выключать нечего, и честнее сказать это, чем прятать строку и
                // оставить человека гадать, куда делась настройка, про которую
                // он читал.
                SettingsCell(
                    "Индикация записи в\u{00A0}чёлке",
                    subtitle: NotchController.hardwareHasNotch
                        ? "Микрофон, пауза и\u{00A0}стоп в\u{00A0}вырезе"
                        : "На этом маке нет выреза — управление записью живёт в\u{00A0}окне"
                ) {
                    SettingsSwitch(
                        isOn: $notchIndicator,
                        enabled: NotchController.hardwareHasNotch
                    )
                }
                .onChange(of: notchIndicator) { _, _ in
                    NotchController.shared.preferenceChanged()
                }

                // Выключатель живёт здесь, потому что вернуть иконку можно
                // только отсюда: в поповере, которого без неё не будет, доступно
                // лишь «Скрыть». Сцена читает тот же ключ
                // (`MenuBarExtra(isInserted:)`).
                SettingsCell(
                    "Иконка в\u{00A0}меню баре",
                    subtitle: "Быстрый доступ к\u{00A0}старту записи"
                ) {
                    SettingsSwitch(isOn: $menuBarIconVisible)
                }
            }
        }
    }
}

import SwiftUI
import AppKit
import PropellerUI
import PropellerPure

// MARK: - Основные

/// Раздел «Основные»: кто вы, что система нам разрешила, когда приложение
/// оживает само, как оно выглядит и что о себе сообщает.
///
/// Сюда же уехало всё, чему в макете не нашлось экрана (решение владельца
/// 2026-08-26): разрешение на имена спикеров, аналитика и обновления. Довод —
/// тот же, по которому раздел называется «Основные»: это то, что настраивают
/// один раз и больше не открывают, и отдельный раздел на две строки был бы
/// разделом ради симметрии.
///
/// Первая карточка без заголовка намеренно: заголовок над ней назывался бы
/// «Основные» второй раз (§5.5).
struct GeneralSettingsPage: View {
    @ObservedObject var state: AppState
    @AppStorage("userName") private var userName = ""
    @AppStorage("appLanguage") private var appLanguage = "ru"

    var body: some View {
        SettingsPage(SettingsSection.general.title) {
            SettingsCard {
                // Плейсхолдер — то самое системное имя, которым подпишет фолбэк
                // (`Preferences.ownerName`). Пустое поле поэтому не врёт: оно
                // показывает, как встреча будет подписана, если ничего не
                // вводить. Поле узкое: имя человека короче любого пути.
                SettingsCell("Ваше имя", subtitle: "Для подписи в\u{00A0}саммари") {
                    SettingsField(NSFullUserName(), text: $userName)
                }
                .onChange(of: userName) { _, val in
                    state.setOwnerNameFromSettings(val)
                }

                SettingsCell("Язык приложения", subtitle: "Меняется только интерфейс") {
                    SettingsMenu(
                        selection: $appLanguage,
                        options: [.init("ru", "Русский"), .init("en", "Английский")]
                    )
                }
                .onChange(of: appLanguage) { _, val in
                    Preferences.shared.appLanguage = val
                }

                CalendarAccessRow(state: state)
                SpeakerAccessRow()
            }

            LaunchSettingsGroup(state: state)
            AppearanceSettingsGroup()
            AboutSettingsGroup()
        }
    }
}

/// Доступ к приложениям — то, чем читаются имена спикеров из окна Zoom.
///
/// Заголовок называет то, что человек получит, а не имя разрешения: имя
/// разрешения он увидит в System Settings, куда его и уводит кнопка.
///
/// Polled, not cached: the grant lands in System Settings, sometimes only after
/// a relaunch, and the tick must appear the moment it is true — same contract as
/// the onboarding plate's rows.
private struct SpeakerAccessRow: View {
    @State private var granted = AXIsProcessTrusted()
    @State private var promptShown = false
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        SettingsCell(
            "Имена спикеров из\u{00A0}Zoom",
            // Разрешено — сказать нечего: об этом говорит галочка. Не разрешено —
            // сказать надо, потому что цена молчания видна только в расшифровке.
            subtitle: granted ? nil : "Без доступа — «Участник\u{00A0}1» и «Участник\u{00A0}2»"
        ) {
            if granted {
                SettingsCheck()
            } else {
                SettingsButton("Разрешить", role: .prominent) { press() }
            }
        }
        .onReceive(poll) { _ in granted = AXIsProcessTrusted() }
    }

    private func press() {
        // Системное окно показывается один раз за установку. Второй нажим уже
        // ничего не спросит, поэтому ведёт туда, где решение принимают руками.
        if promptShown {
            if let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            ) {
                NSWorkspace.shared.open(url)
            }
            return
        }
        promptShown = true
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}

/// Строка календаря: единственное место, где приложение признаётся, что
/// названий из календаря не будет.
///
/// Решение состояния — в `PropellerPure/CalendarAccess.swift`; здесь только
/// чтение системы и нажатие. Тексты состояний живут там и покрыты тестами —
/// поэтому переписан только заголовок строки. Перечитывает ответ системы на
/// открытии настроек и на возврате в приложение — тот же приём, что у
/// `MCPClientRow`: человек уходит выдавать доступ руками и обязан вернуться к
/// изменившейся строке.
private struct CalendarAccessRow: View {
    @ObservedObject var state: AppState
    @ObservedObject private var calendar = CalendarService.shared
    @AppStorage("calendarEnabled") private var calendarEnabled = false

    private var row: CalendarSettingsRow {
        .state(enabled: calendarEnabled, access: calendar.access)
    }

    var body: some View {
        SettingsCell("Названия встреч из\u{00A0}Календаря", subtitle: row.subtitle) {
            control
        }
        .onAppear { calendar.refreshAccess() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in calendar.refreshAccess() }
    }

    @ViewBuilder
    private var control: some View {
        if let title = row.actionTitle {
            SettingsButton(title, role: .prominent) { press() }
        } else if row.showsCheckmark {
            SettingsCheck()
        } else {
            EmptyView()
        }
    }

    private func press() {
        // После отказа системы просить снова нечего: окна не будет, и кнопка
        // «Попробовать снова» читалась бы как сломанное приложение. Единственный
        // работающий путь — System Settings.
        if row.opensSystemSettings {
            if let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
            ) {
                NSWorkspace.shared.open(url)
            }
            return
        }
        state.enableCalendarFromSettings()
    }
}

// MARK: - Запуск

/// Когда приложение оживает само.
///
/// «Запуск Propeller при входе» назван с субъектом намеренно: без него строка
/// читалась бы как «запускать запись при входе».
private struct LaunchSettingsGroup: View {
    @ObservedObject var state: AppState
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var launchAtLoginError: String?
    @AppStorage("autoRecordMode") private var autoRecordMode = AutoRecordMode.auto.rawValue

    var body: some View {
        SettingsGroup("Запуск") {
            SettingsCell(
                "Запуск Propeller при\u{00A0}входе",
                // Единственная строка, которая здесь появляется: отказ системы.
                // Она не описывает настройку, она отвечает на нажатие — и потому
                // красится как отказ, а не как подсказка.
                subtitle: launchAtLoginError,
                tone: .failure
            ) {
                SettingsSwitch(isOn: $launchAtLogin)
            }
            .onChange(of: launchAtLogin) { _, want in
                do {
                    try LoginItem.setEnabled(want)
                    launchAtLoginError = nil
                } catch {
                    // Вернуть переключатель к правде и назвать причину.
                    launchAtLogin = LoginItem.isEnabled
                    launchAtLoginError = error.localizedDescription
                }
            }

            // Zoom назван поимённо: у Толка сигнала «идёт звонок» нет вовсе, и
            // обещать здесь «звонок» вообще значило бы обещать старт, который
            // не наступит.
            SettingsCell(
                "Автоматическая запись",
                subtitle: "Вместе со звонком в\u{00A0}Zoom"
            ) {
                SettingsSwitch(isOn: autoRecord)
            }
            .onChange(of: autoRecordMode) { _, val in
                Preferences.shared.autoRecordMode = AutoRecordMode(rawValue: val) ?? .auto
                state.applyAutoRecordMode()
            }
        }
        .onAppear {
            launchAtLogin = LoginItem.isEnabled
            // Через `Preferences`, а не из defaults напрямую: там живёт миграция
            // удалённого «Спросить», и без этого чтения выключатель показал бы
            // «выкл» при записанном `ask`.
            autoRecordMode = Preferences.shared.autoRecordMode.rawValue
        }
    }

    /// Два режима — выключатель, а не пикер из двух пунктов. `AutoRecordMode`
    /// остаётся на диске строкой: её `rawValue` уже лежат у людей.
    private var autoRecord: Binding<Bool> {
        Binding(
            get: { (AutoRecordMode(rawValue: autoRecordMode) ?? .auto) == .auto },
            set: { autoRecordMode = ($0 ? AutoRecordMode.auto : .off).rawValue }
        )
    }
}

// MARK: - Оформление

/// Как приложение выглядит.
///
/// **Все три строки помнят выбор и ничего не делают** (решение владельца
/// 2026-08-26). Они стоят здесь как напоминание, что за ними работа: тема —
/// `NSApp.appearance` поверх уже выведенных светлых токенов, кегль саммари —
/// множитель в `Tokens.Pane.Typo`, прозрачность — материал в `SystemGlass`.
///
/// Цена названа вслух в `Preferences` и в `STATE.md`: это ровно тот тупик,
/// который запрещает `design/no-dead-ends.md`, и ни одна из трёх не уезжает в
/// релиз, пока за ней нет поведения.
private struct AppearanceSettingsGroup: View {
    @AppStorage("appTheme") private var appTheme = "system"
    @AppStorage("summaryTextSize") private var summaryTextSize = "standard"
    @AppStorage("windowTranslucency") private var windowTranslucency = true

    var body: some View {
        SettingsGroup("Оформление") {
            SettingsCell("Тема приложения", subtitle: "Есть тёмная и\u{00A0}светлая") {
                SettingsMenu(
                    selection: $appTheme,
                    options: [
                        .init("system", "Системная"),
                        .init("dark", "Тёмная"),
                        .init("light", "Светлая"),
                    ]
                )
            }
            .onChange(of: appTheme) { _, val in Preferences.shared.appTheme = val }

            SettingsCell("Размер текста в\u{00A0}саммари", subtitle: "Можно сделать крупнее") {
                SettingsMenu(
                    selection: $summaryTextSize,
                    options: [
                        .init("small", "Мелкий"),
                        .init("standard", "Стандартный"),
                        .init("large", "Крупнее"),
                    ]
                )
            }
            .onChange(of: summaryTextSize) { _, val in Preferences.shared.summaryTextSize = val }

            SettingsCell("Прозрачность окон", subtitle: "Атмосферный фон для окна") {
                SettingsSwitch(isOn: $windowTranslucency)
            }
            .onChange(of: windowTranslucency) { _, val in
                Preferences.shared.windowTranslucency = val
            }
        }
    }
}

// MARK: - О программе

/// Приложение о себе — и один тумблер, который тоже про него.
///
/// Аналитика приехала сюда из распущенной «Приватности» (решение владельца
/// 2026-08-20): она не про архив и не про то, кто его читает, — она про само
/// приложение, как версия и обновления. Заголовок строки — глагол, потому что
/// это единственная строка группы, где человек что-то решает.
private struct AboutSettingsGroup: View {
    @AppStorage("analyticsEnabled") private var analyticsEnabled = true

    var body: some View {
        SettingsGroup("О программе") {
            SettingsCell(
                "Отправлять аналитику",
                subtitle: "Только события приложения, без личных данных"
            ) {
                SettingsSwitch(isOn: $analyticsEnabled)
            }
            .onChange(of: analyticsEnabled) { _, on in
                Analytics.setEnabled(on)
            }

            SettingsCell("Версия") {
                SettingsValue(LoginItem.appVersionString)
            }
            SettingsCell("Обновления") {
                SettingsButton(
                    "Проверить обновления",
                    enabled: SparkleUpdater.shared.canCheckForUpdates
                ) {
                    SparkleUpdater.shared.checkForUpdates()
                }
            }
        }
    }
}


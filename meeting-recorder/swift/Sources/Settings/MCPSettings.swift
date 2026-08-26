import SwiftUI
import AppKit
import PropellerUI
import PropellerPure

// MARK: - MCP

/// Раздел «MCP»: по строке на клиента, у каждой одна кнопка и ни одного диалога.
///
/// Имя раздела владелец оставил протоколом, а не вопросом («кто ещё читает
/// архив»): кто пришёл сюда подключать клиента, ищет именно эти три буквы.
///
/// Чужой конфиг можно отредактировать руками — сегодня это единственный способ,
/// и он не работает: путь надо знать. Здесь всё, что от человека требуется, —
/// нажать; остальное (найти приложение, сделать копию его конфига, дописать в
/// него запись) делает `MCPConnector`.
///
/// **Состояние выводится при каждом открытии, а не хранится.** Файлы чужие: их
/// может переписать сам клиент, и сохранённое «подключено» разошлось бы с
/// правдой молча. Плюс перечитывание на возврате в приложение — человек уходит
/// перезапускать Клода при открытых настройках и возвращается к строке, которая
/// обязана уже поменяться.
///
/// Кнопки «Перезапустить» здесь нет намеренно: закрывать чужое приложение с
/// открытыми разговорами — не наше дело.
///
/// Не `private` только ради галереи: её кадры рисуют эту же группу, а не её
/// копию, — иначе справочник показывал бы то, чего в приложении нет.
struct MCPSettingsPage: View {
    @ObservedObject var state: AppState

    var body: some View {
        SettingsPage(SettingsSection.mcp.title) {
            MCPClientsCard(state: state)
        }
    }
}

/// Не `private` только ради галереи: её кадры рисуют эту же карточку, а не её
/// копию, — иначе справочник показывал бы то, чего в приложении нет.
struct MCPClientsCard: View {
    @ObservedObject var state: AppState

    var body: some View {
        SettingsCard {
            // Список клиентов — данные (`PropellerPure/MCPClient.swift`), не
            // ветки здесь: добавить клиента значит дописать случай там.
            for client in MCPClient.allCases {
                if client.configLocation == nil {
                    // Клиент без конфига — значит и без кнопки: его подключают
                    // командой, и всё, что мы можем, — дать её скопировать.
                    MCPCommandRow(client: client)
                } else {
                    MCPClientRow(state: state, client: client)
                }
            }
        }
    }
}

/// Строка клиента, которого подключают руками.
///
/// Состояния у неё нет и быть не может: в чужой конфиг мы не смотрим, а
/// `claude mcp add` кладёт запись туда, куда сам решит — в проект, в профиль
/// или в сессию. Единственная честная роль строки здесь — отдать команду.
private struct MCPCommandRow: View {
    let client: MCPClient

    var body: some View {
        SettingsCell(client.rowTitle, subtitle: nil) {
            if let command = MCPConnector.claudeCodeCommand {
                SettingsCommandField(command) { copy(command) }
            } else {
                // Бинаря нет — команда вела бы в пустоту. Молчим: скопированная
                // строка, которая не работает, хуже отсутствующей.
                EmptyView()
            }
        }
    }

    private func copy(_ command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        Analytics.claudeSetup(step: "command_copied", client: client.rawValue)
    }
}

/// Одна строка — один клиент.
///
/// Своё `@State` на строку, а не общее на группу: неудача записи в конфиг
/// одного клиента ничего не говорит о другом, и «Попробовать снова» обязано
/// стоять ровно там, где нажали.
private struct MCPClientRow: View {
    @ObservedObject var state: AppState
    let client: MCPClient

    @State private var cell: MCPCellState = .offer
    /// Живёт до следующего нажатия. Это ответ на действие, а не свойство
    /// системы, и переживать открытие настроек ему незачем.
    @State private var writeFailed = false

    var body: some View {
        SettingsCell(client.rowTitle, subtitle: cell.subtitle(for: client)) {
            control
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in refresh() }
    }

    @ViewBuilder
    private var control: some View {
        if let title = cell.actionTitle {
            // Акцент — на том, что ещё не подключено; у подключённого тихая
            // галочка. «Попробовать снова» после отказа записи — тоже акцент:
            // это единственное, что осталось сделать в строке.
            SettingsButton(title, role: .prominent) { connect() }
        } else if cell.showsCheckmark {
            SettingsCheck()
        } else {
            // У «не установлен» справа нет ничего. Кнопки «Скачать» здесь не
            // будет: нажимать нам не на что, а уводить человека из настроек в
            // браузер за чужим приложением — не наше дело и не наш приём.
            EmptyView()
        }
    }

    private func connect() {
        writeFailed = !MCPConnector.connect(client)
        refresh()
    }

    private func refresh() {
#if GALLERY
        if let forced = state.galleryMCPCellOverride, forced.client == client {
            cell = forced.state
            return
        }
#endif
        cell = MCPConnector.cellState(for: client, lastWriteFailed: writeFailed)
    }
}


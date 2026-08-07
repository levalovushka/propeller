import Foundation

/// # Почему встреча стоит там, где стоит
///
/// Тип, в котором тупик невыразим. Две ветви, и третьей — «нужен человек» —
/// здесь нет: именно её отсутствие и есть вся идея `design/no-dead-ends.md`.
/// Пока такая ветвь существовала, у приложения был момент, когда оно сдаётся и
/// просит нажать кнопку, а у человека — красная встреча, про которую он не может
/// сделать ничего, чего не может сделать приложение.
///
/// Живёт в `PropellerPure`, потому что это правило, а не отрисовка: интерфейс
/// читает готовый ответ, а проверяет его тест.
public enum MeetingRest: Equatable, Sendable {
    /// Работа идёт или придёт. Всегда со сроком, когда посмотрим снова —
    /// «остановились и надеемся, что нас кто-нибудь пнёт» это и есть тот способ,
    /// которым встречи стояли неделю (I12).
    case waiting(WaitReason)
    /// Дальше нечего делать — по природе входа, а не потому что мы сдались.
    case done(TerminalReason)

    /// Чего ждём. Ни один из вариантов не требует человека.
    public enum WaitReason: String, Equatable, Sendable, CaseIterable {
        /// В очереди: воркер один, и он занят другой встречей.
        case queued
        /// Прямо сейчас в работе.
        case working
        /// Ждём модель саммари. Она качается сама (`ModelProvisioning`).
        case model
        /// Ждём сеть, сервис или следующую попытку. Лестница бесконечна
        /// (`PipelineRetry.steps`).
        case network
    }

    /// Законные концы. Все — про вход или про настройки, ни один — про нашу
    /// неудачу.
    /// `Codable`, потому что причина остановки лежит на записи и переживает
    /// перезапуск: карточка обязана сказать то же самое и завтра.
    public enum TerminalReason: String, Codable, Equatable, Sendable, CaseIterable {
        /// Прошла всю лестницу глубины.
        case complete
        /// В записи не нашлось речи.
        case noSpeech
        /// Саммари выключено в настройках: значит встреча готова без него.
        case summariesOff

        /// Строка для лога и телеметрии. Человеку её не показывают — он читает
        /// `disclosure`, — но руками она была скопирована в трёх местах, а копия
        /// копии расходится: у `ToastCopy` это уже случалось.
        public var logMessage: String {
            switch self {
            case .complete:     return "обработка завершена"
            case .noSpeech:     return "в записи не нашлось речи"
            case .summariesOff: return "саммари выключено в настройках"
            }
        }
    }

    /// Что об этом сказано в карточке. Nil — сказать нечего: встреча либо
    /// доделана, либо ею занимаются, и то и другое видно без слов.
    ///
    /// Формулировки — состояния, не сообщения и не ошибки: «дальше не будет»,
    /// а не «не удалось» (`design/notifications.md` §3).
    public var disclosure: String? {
        switch self {
        case .waiting(.queued), .waiting(.working):
            return nil
        case .waiting(.model):
            return "Саммари появится, когда докачается модель"
        case .waiting(.network):
            return "Ждём ответа сервиса"
        case .done(.complete):
            return nil
        case .done(.noSpeech):
            // Человеческим языком и про людей, а не про распознавание: «речи не
            // нашлось» звучит как отчёт движка о неудаче, хотя движок отработал
            // ровно правильно — говорить было некому.
            return "Никто ничего не сказал"
        case .done(.summariesOff):
            return "Саммари выключено в\u{00A0}настройках"
        }
    }

    /// Причитается ли этой встрече ещё работа.
    public var owesWork: Bool {
        if case .waiting = self { return true }
        return false
    }
}

// MARK: - Как это выводится

extension MeetingRest {
    /// Единственное место, где решается, где стоит встреча.
    ///
    /// Порядок ветвей — всё содержание функции:
    ///
    /// - **Полнота первой.** Дно лестницы — `.summarized`; с выключенным саммари
    ///   дном становится `.saved`, и это не «недоделано», а «доделано иначе».
    ///   Раньше первым стоял терминальный отказ, и это была ловушка: `clearFailure`
    ///   снимает отказ на каждом успехе, так что дошедшая до конца встреча его не
    ///   несёт — но если когда-нибудь понесёт, «Аудио удалено» на готовом саммари
    ///   врало бы, а «готово» на готовом — нет.
    /// - **Потом терминальный отказ.** Аудио удалено или речи не было: работы нет,
    ///   и никакая попытка этого не изменит.
    /// - **Потом текущая работа**, потом ожидание провайдера, потом очередь.
    ///
    /// Здесь нет ветви для «попытки исчерпаны», потому что такого состояния
    /// больше не существует (`PipelineRetry.steps` без конца).
    public static func of(
        stage: RecordingStage,
        failure: PipelineFailure?,
        isWorkingOnIt: Bool,
        summariesEnabled: Bool,
        summaryModelReady: Bool
    ) -> MeetingRest {
        let terminalStage: RecordingStage = summariesEnabled ? .summarized : .saved
        if stage >= terminalStage {
            return .done(summariesEnabled ? .complete : .summariesOff)
        }
        if let failure, failure.isTerminal {
            // Причину несёт сам отказ — её объявил тот, кто посмотрел на вход.
            // Выводить её из текста сообщения означало бы гадать о смысле по
            // подстроке, ровно как `PipelineRetry.classify` больше не делает.
            return .done(failure.terminalReason ?? .noSpeech)
        }
        if isWorkingOnIt { return .waiting(.working) }
        // Ждём чего-то внешнего? Ответ зависит от ступени: модель нужна только
        // саммари и до транскрипта никого не держит.
        if stage >= .saved, summariesEnabled, !summaryModelReady {
            return .waiting(.model)
        }
        if failure != nil { return .waiting(.network) }
        return .waiting(.queued)
    }
}

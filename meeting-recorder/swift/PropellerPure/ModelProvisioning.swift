import Foundation

/// # Модель саммари — часть установки, а не выбор пользователя
///
/// «Саммари нет» — законная глубина для одной встречи. «Нет LLM» — не законное
/// состояние приложения (`design/no-dead-ends.md` §5). Отсюда: модель
/// выдаётся сама при первом запуске и починивается при каждом следующем, если её
/// не нашли — удалили чистилкой диска, сломался рантайм после обновления
/// системы, поднялся пин версии в новой сборке.
///
/// Решение живёт здесь, а не в `AppState`, по обычной причине: `Sources/` —
/// исполняемая цель, до которой не дотягивается тест, а это правило из тех,
/// которые ошибаются незаметно на месяц.
public enum ModelProvisioning {

    /// Что известно в момент вопроса. Ровно те поля, которые у приложения уже есть.
    public struct Context: Equatable, Sendable {
        /// Нужна ли вообще локальная модель при текущем провайдере.
        public var usesLocalModel: Bool
        /// Веса на месте (манифест на диске или ответ уже поднятого сервера).
        public var modelInstalled: Bool
        /// Идёт запись, звонок или расшифровка: диск и сеть заняты тем, что важнее.
        public var busyWithAudio: Bool
        /// Загрузка уже идёт — второй раз начинать нечего.
        public var downloadInFlight: Bool

        public init(
            usesLocalModel: Bool,
            modelInstalled: Bool,
            busyWithAudio: Bool,
            downloadInFlight: Bool
        ) {
            self.usesLocalModel = usesLocalModel
            self.modelInstalled = modelInstalled
            self.busyWithAudio = busyWithAudio
            self.downloadInFlight = downloadInFlight
        }
    }

    public enum Decision: String, Equatable, Sendable {
        /// Качать. Без спроса — это часть установки.
        case fetch
        /// Всё на месте.
        case alreadyThere
        /// Локальная модель при этом провайдере не нужна: облачный ключ или
        /// саммари выключены совсем. Тянуть 3,4 ГБ было бы наглостью.
        case notOurs
        /// Не сейчас: идёт запись. Вернёмся — поводов ещё будет много.
        case waitForQuiet
        /// Уже качаем.
        case inFlight
    }

    public static func decide(_ ctx: Context) -> Decision {
        guard ctx.usesLocalModel else { return .notOurs }
        guard !ctx.downloadInFlight else { return .inFlight }
        // Проверка «есть ли модель» дешёвая, но она перед занятостью нарочно:
        // отвечать «подождём» про модель, которая на месте, — врать.
        guard !ctx.modelInstalled else { return .alreadyThere }
        guard !ctx.busyWithAudio else { return .waitForQuiet }
        return .fetch
    }

    // MARK: - Обязательство закрывается фактом, а не файлом

    /// Что известно про попытку поднять движок. Не хранится между запусками:
    /// запуск — сам по себе сигнал, и чистый лист на старте верен.
    public enum EngineVerdict: String, Equatable, Sendable, CaseIterable {
        /// Никто ещё не пробовал в этом запуске.
        case unknown
        /// Сервер отвечал — это единственный неопровержимый признак.
        case up
        /// Пробовали и не подняли: битая распаковка, таймаут здоровья,
        /// пропавший бинарь.
        case failed
    }

    /// Всё, что видно про локальную выдачу **без запуска сервера**. Три
    /// дешёвых факта: манифест на диске, файл движка нужной версии и вердикт
    /// последней настоящей попытки его поднять.
    public struct Readiness: Equatable, Sendable {
        /// Веса на месте.
        public var modelInstalled: Bool
        /// Движок распакован и той самой версии (`installed-version.txt`).
        public var engineInstalled: Bool
        /// Чем кончилась последняя попытка поднять сервер в этом запуске.
        public var lastServe: EngineVerdict

        public init(modelInstalled: Bool, engineInstalled: Bool, lastServe: EngineVerdict) {
            self.modelInstalled = modelInstalled
            self.engineInstalled = engineInstalled
            self.lastServe = lastServe
        }
    }

    /// Обязательство «у приложения есть LLM»: закрыто или ещё висит.
    public enum Obligation: String, Equatable, Sendable {
        /// Саммари действительно возможно — можно снимать лестницу и монитор.
        case discharged
        /// Ещё нет. Лестница остаётся, вигиль остаётся, попытка повторяется.
        case owed
    }

    /// Закрыто ли обязательство.
    ///
    /// **Файл на диске принимали за «саммари возможно», и это разные вещи.**
    /// Саммари требует большего: `RecapService.ollamaUsable` после проверки
    /// весов поднимает сервер и стучится в него. А `ensureSummaryModel` при
    /// `modelInstalled == true` снимал лестницу, гасил монитор сети и считал
    /// обязательство закрытым. Итог: модель лежит, сервер не встаёт (битая
    /// распаковка, таймаут здоровья, слетевший `installed-version.txt`) —
    /// и чинить это некому: вигиль выключен, остаётся только лестница
    /// `.blocked` в конвейере, вечно тыкающая в тот же неподнимающийся сервер
    /// с потолком в полчаса. Человек не видит ничего и не получает ничего.
    ///
    /// Цена вопроса — ноль запусков сервера: `up` знает тот, кто уже пробовал
    /// (`ensureServerRunning` на каждом саммари), остальное — два обращения к
    /// файловой системе. Спрашивать сервер прямо здесь было бы дороже самого
    /// дефекта: это `ollama serve` на каждый чих вигиля.
    public static func summaryPossible(_ r: Readiness) -> Obligation {
        // Сервер отвечал — спорить не с чем, чей бы он ни был: `adopt-if-present`
        // значит, что движок может быть и не наш, и файловые проверки про него
        // ничего не скажут.
        if r.lastServe == .up && r.modelInstalled { return .discharged }
        guard r.modelInstalled else { return .owed }
        // Пробовали и не подняли. Это ровно тот случай, ради которого правило
        // и написано: весов достаточно, чтобы соврать «всё на месте».
        guard r.lastServe != .failed else { return .owed }
        // Никто не пробовал. Тогда единственное, что можно спросить дёшево, —
        // лежит ли движок нужной версии. Нет — выдача обязана доехать.
        return r.engineInstalled ? .discharged : .owed
    }

    /// Нужна ли локальная модель при этом провайдере.
    ///
    /// По строковым значениям префов, потому что именно они лежат на диске и
    /// именно они не должны меняться. `auto` — да: без облачного ключа он
    /// сваливается на локальную модель, а ключа у большинства нет.
    public static func usesLocalModel(providerRawValue: String) -> Bool {
        switch providerRawValue {
        case "ollama", "auto": return true
        case "openai", "claude", "openrouter", "off": return false
        // Незнакомое значение — из сборки новее этой. Качать «на всякий случай»
        // дешевле, чем оставить человека без саммари.
        default: return true
        }
    }
}

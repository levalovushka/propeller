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

    /// Нужна ли локальная модель при этом провайдере.
    ///
    /// По строковым значениям префов, потому что именно они лежат на диске и
    /// именно они не должны меняться. `auto` — да: без облачного ключа он
    /// сваливается на локальную модель, а ключа у большинства нет.
    public static func usesLocalModel(providerRawValue: String) -> Bool {
        switch providerRawValue {
        case "ollama", "auto": return true
        case "openai", "claude", "off": return false
        // Незнакомое значение — из сборки новее этой. Качать «на всякий случай»
        // дешевле, чем оставить человека без саммари.
        default: return true
        }
    }
}

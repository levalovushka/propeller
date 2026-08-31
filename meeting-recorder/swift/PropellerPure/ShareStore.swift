import Foundation

/// # Список публикаций, который переживает встречу
///
/// `shares.json` — единственное место на свете, где известно, что саммари
/// опубликовано. Сервер содержимого не видит и списка «моих ссылок» собрать не
/// может (`Sources/ShareService.swift`), поэтому потерять запись отсюда значит
/// потерять токен отзыва: ссылка доживёт свой срок, а снять её будет нечем.
///
/// Файл читается здесь, а не только в сервисе, ради одного свойства.
///
/// **Стирание встречи обязано его видеть.** `ArchiveEraser` вычищает `.bak` и
/// карантинные снимки ради правила «стёрли значит стёрли», а копия саммари на
/// сервере из этого правила выпадала: человек публиковал саммари на месяц,
/// рассылал ссылку, удалял встречу — и `residue` отдавал пусто. Ссылка при этом
/// оставалась рабочей, а отозвать её было уже нечем: `unpublish` звался ровно из
/// одной кнопки в плите встречи, а плиты больше нет.
///
/// **Снять публикацию — это сеть, а удаление сети не ждёт.** Поэтому здесь тот
/// же приём, что у надгробий (`TombstoneFile`): метка ставится синхронно,
/// дочистка приходит позже. Запись не уходит вместе со встречей — она получает
/// `erasedAt` и становится списком того, что осталось отозвать.
public enum ShareStore {

    /// `~/Library/Application Support/Meeting Recorder/shares.json`.
    ///
    /// Не в папке архива: архив человек переносит и переименовывает, а токены
    /// отзыва привязаны к машине, а не к папке. Путь живёт здесь, а не в
    /// сервисе, потому что читателей у файла теперь два — сервис и стирание.
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Meeting Recorder", isDirectory: true)
            .appendingPathComponent("shares.json")
    }

    public static func read(_ url: URL?) -> [String: ShareRecord] {
        guard let url, let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode([String: ShareRecord].self, from: data)) ?? [:]
    }

    /// Записать список. `false` — не удалось; вызывающий обязан доложить, а не
    /// промолчать: непойманная неудача здесь — это потерянный токен.
    @discardableResult
    public static func write(_ records: [String: ShareRecord], to url: URL?) -> Bool {
        guard let url else { return false }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(records) else { return false }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard (try? data.write(to: url, options: [.atomic])) != nil else { return false }
        // Файл держит токены отзыва — читать его посторонним незачем.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path
        )
        return true
    }

    /// Встречи, чья копия саммари сейчас лежит на сервере.
    ///
    /// Стёртая встреча отсюда **не** исчезает: копия на сервере от удаления
    /// встречи никуда не делась, и след обязан считаться следом, пока сервер не
    /// подтвердил отзыв. Исчезает только просроченная: её сервер уронил сам
    /// (`SERVER.md` §1, бэкапов нет), отзывать нечего.
    public static func liveIDs(at url: URL?, now: Date = Date()) -> [String] {
        read(url).filter { $0.value.isLive(at: now) }.map(\.key)
    }

    /// Встречи, которые стёрли, а публикацию ещё не сняли. Это и есть очередь
    /// отзыва — она же единственное, что от встречи осталось.
    public static func awaitingRevocation(at url: URL?, now: Date = Date()) -> [String: ShareRecord] {
        read(url).filter { $0.value.awaitsRevocation && $0.value.isLive(at: now) }
    }

    public static func isAwaitingRevocation(_ id: String, at url: URL?) -> Bool {
        read(url)[id]?.awaitsRevocation == true
    }

    /// Пометить публикацию стёртой встречи. Запись остаётся целиком — с
    /// токеном и ключом: без них отзывать нечем.
    ///
    /// `true`, если помечать было нечего или пометили. `false` — запись есть, а
    /// перезаписать файл не вышло: тогда след останется неучтённым, и об этом
    /// надо сказать вслух.
    @discardableResult
    public static func markErased(_ id: String, at url: URL?, now: Date = Date()) -> Bool {
        var records = read(url)
        guard var record = records[id] else { return true }
        // Просроченную метить незачем: копии на сервере уже нет, отзывать нечего.
        // Её выметает `ShareService.sweepExpired`, а не стирание встречи.
        guard record.isLive(at: now), record.erasedAt == nil else { return true }
        record.erasedAt = now
        records[id] = record
        return write(records, to: url)
    }

    /// Убрать запись: сервер подтвердил отзыв или срок вышел сам.
    @discardableResult
    public static func forget(_ id: String, at url: URL?) -> Bool {
        var records = read(url)
        guard records.removeValue(forKey: id) != nil else { return true }
        return write(records, to: url)
    }

    /// Записи, чей срок вышел. Сервер их уже уронил, отзывать нечего, а
    /// показывать «Опубликовано» по ним — врать.
    ///
    /// Чистая функция, потому что решение «что выбросить» проверяется без
    /// файла, а выбрасывает пусть тот, кто и так пишет.
    public static func expiredIDs(in records: [String: ShareRecord], now: Date) -> [String] {
        records.filter { !$0.value.isLive(at: now) }.map(\.key).sorted()
    }
}

/// Одна публикация. Лежит в `PropellerPure`, а не в сервисе, потому что её
/// читают двое: сервис (чтобы показать ссылку) и стирание (чтобы не соврать
/// «следов нет»). Форма на диске не менялась — `erasedAt` необязательное, и
/// файлы, написанные прежними сборками, читаются как есть.
public struct ShareRecord: Codable, Equatable, Sendable {
    public let id: String
    /// Токен отзыва. На сервере лежит только его хеш — значит, снять
    /// публикацию может ровно эта машина и никто больше.
    public let token: String
    /// Ключ шифрования, base64url. Хранится, потому что ссылку надо уметь
    /// показать ещё раз («Скопировать», «Перейти»), а восстановить ключ
    /// неоткуда: у сервера его нет.
    public let key: String
    public let expiresAt: Date
    public let title: String
    /// Когда стёрли встречу. `nil` — встреча жива. Не `nil` — встречи больше
    /// нет, а копия саммари на сервере ещё есть, и эта запись единственное, чем
    /// её можно снять.
    public var erasedAt: Date?

    public init(
        id: String, token: String, key: String, expiresAt: Date, title: String,
        erasedAt: Date? = nil
    ) {
        self.id = id
        self.token = token
        self.key = key
        self.expiresAt = expiresAt
        self.title = title
        self.erasedAt = erasedAt
    }

    public var url: URL? {
        guard let raw = ShareLink.data(base64url: key) else { return nil }
        return ShareLink.url(id: id, key: raw, title: title)
    }

    /// Лежит ли копия на сервере прямо сейчас.
    public func isLive(at now: Date) -> Bool { expiresAt > now }

    /// Ждёт ли отзыва: встречу стёрли, сервер ещё не подтвердил.
    public var awaitsRevocation: Bool { erasedAt != nil }
}

import CryptoKit
import Foundation
import PropellerPure

/// # Публикация саммари по ссылке
///
/// Контракт — `SERVER.md` §3. Главное в нём одно: **сервер не видит
/// содержимого**. Приватность держится на конструкции, а не на обещании, и вся
/// конструкция здесь: саммари шифруется до отправки, ключ уезжает во фрагменте
/// ссылки, а фрагмент браузер серверу не отправляет никогда.
///
/// Поэтому у сервиса нет и не может быть «списка моих публикаций»: серверу
/// не по чему его собрать. Список живёт только тут, в `shares.json`, и если
/// его потерять — ссылка останется живой до конца своего срока, а снять её
/// будет нечем. Это названо вслух, а не спрятано: цена того, что на сервере
/// нет аккаунтов.
///
/// Из этого же следует, что запись **переживает встречу**. Человек публиковал
/// саммари на месяц, рассылал ссылку и удалял встречу — приложение молчало, а
/// копия жила на сервере до истечения срока: `unpublish` звался ровно из одной
/// кнопки в плите встречи, а плиты больше нет. Теперь стирание записи не
/// уносит, а помечает (`ShareStore.markErased`), и она становится очередью
/// отзыва: `finishPendingRevocations`.
///
/// UI сюда не входит. Модалку «Поделиться ссылкой» (Figma 298:26408) рисует
/// своя сессия; ей нужны ровно три вещи — `publish`, `unpublish` и `link(for:)`.
@MainActor
final class ShareService: ObservableObject {

    static let shared = ShareService()

    /// Срок жизни ссылки. «Вечной» нет: у сервера нет бэкапов осознанно
    /// (`SERVER.md` §1), и ссылка, которая обещает пережить машину, врёт.
    /// Названия здесь, а не в модалке: копирайт живёт в одном месте.
    enum Lifetime: String, CaseIterable, Identifiable {
        case week
        case month

        var id: String { rawValue }

        var title: String {
            switch self {
            case .week: return "Неделя"
            case .month: return "Месяц"
            }
        }
    }

    /// Запись живёт в `PropellerPure` (`ShareRecord`), потому что читателей у
    /// неё двое: этот сервис — чтобы показать ссылку, и стирание встречи —
    /// чтобы не соврать «следов не осталось» про саммари, лежащее на сервере.
    typealias Record = ShareRecord

    @Published private(set) var records: [String: Record] = [:]

    private let client: ShareClient
    private let storeURL: URL

    init(client: ShareClient = ShareClient(), storeURL: URL? = nil) {
        self.client = client
        self.storeURL = storeURL ?? ShareStore.defaultURL
        self.records = ShareStore.read(self.storeURL)
    }

    // MARK: - Что знает приложение

    /// Живая публикация **существующей** встречи — или nil.
    ///
    /// Просроченная запись не показывается и не удаляется здесь: удалять при
    /// чтении значило бы менять файл под тем, кто просто смотрит. Её выметает
    /// `sweepExpired()`, у которого есть право писать.
    ///
    /// Запись стёртой встречи тоже не показывается, но по другой причине:
    /// показывать её некому — плиты у стёртой встречи нет. Она осталась не для
    /// экрана, а как очередь отзыва (`pendingRevocations`).
    func record(for meetingID: String, now: Date = Date()) -> Record? {
        guard let record = records[meetingID], record.isLive(at: now),
              !record.awaitsRevocation else { return nil }
        return record
    }

    func link(for meetingID: String, now: Date = Date()) -> URL? {
        record(for: meetingID, now: now)?.url
    }

    /// Есть ли чем публиковать. Секрета нет — значит, эта сборка собрана без
    /// него: кнопке лучше молчать, чем показывать ошибку после нажатия.
    var isAvailable: Bool { client.hasSecret }

    // MARK: - Действия

    /// Шифрует саммари, публикует и возвращает готовую ссылку.
    ///
    /// Порядок именно такой: сначала шифротекст, потом сеть. Сеть не получает
    /// ни одной ветки, на которой в неё уехал бы открытый текст.
    @discardableResult
    func publish(
        meetingID: String,
        title: String,
        date: Date?,
        peopleCount: Int,
        document: SummaryDocument,
        lifetime: Lifetime
    ) async throws -> URL {
        let payload = SharePayload.make(
            title: title, date: date, peopleCount: peopleCount, document: document
        )
        guard let sealed = try? ShareCrypto.seal(payload.encoded()) else {
            throw ShareError.encryptionFailed
        }
        let published = try await client.publish(blob: sealed.blob, lifetime: lifetime)

        let record = Record(
            id: published.id,
            token: published.token,
            key: ShareLink.base64url(sealed.key),
            expiresAt: published.expiresAt,
            title: title
        )
        guard let url = record.url else { throw ShareError.malformedLink }

        // Прежняя публикация этой встречи снимается, а не забывается: иначе
        // старая ссылка осталась бы живой, а токена от неё уже не было бы.
        if let previous = records[meetingID] {
            try? await client.revoke(id: previous.id, token: previous.token)
        }
        records[meetingID] = record
        save()
        return url
    }

    /// Снимает публикацию — и забывает её **только если сервер подтвердил**.
    ///
    /// 404 подтверждением считается: он и означает «такой ссылки больше нет»
    /// (§3.6), а держать запись о несуществующем шере значит показывать
    /// кнопку, которая врёт. Разбор 404 живёт в `ShareClient.revoke`.
    ///
    /// А вот оборванная сеть или 500 — не подтверждение. Стирать запись здесь
    /// (первая версия делала это через `defer`) значит потерять токен: ссылка
    /// осталась бы живой до конца срока, и отозвать её было бы уже нечем.
    /// Лучше показать ошибку и оставить кнопку, чем молча выбросить ключ.
    func unpublish(meetingID: String) async throws {
        guard let record = records[meetingID] else { return }
        try await client.revoke(id: record.id, token: record.token)
        records[meetingID] = nil
        save()
    }

    // MARK: - Публикации стёртых встреч

    /// Что осталось отозвать: встречи уже нет, а копия саммари лежит на сервере.
    ///
    /// Кнопки для этого нет и быть не может — плита живёт в строке встречи, а
    /// строки больше нет. Поэтому очередь, а не кнопка.
    func pendingRevocations(now: Date = Date()) -> [String: Record] {
        records.filter { $0.value.awaitsRevocation && $0.value.isLive(at: now) }
    }

    /// Довести отзывы, оставшиеся от стёртых встреч. Возвращает id встреч, чью
    /// публикацию сервер подтвердил снятой.
    ///
    /// Зовётся сразу после удаления и потом на каждом скане архива
    /// (`RecordingStore`), потому что первая попытка приходится ровно на тот
    /// момент, когда сети может не быть, а удаление её не ждало.
    ///
    /// Неудача — не потеря: запись с токеном остаётся на месте, и следующий
    /// заход попробует снова. Забывается запись только по подтверждению сервера
    /// (404 он тоже считает подтверждением — `ShareClient.revoke`) или когда
    /// срок ссылки вышел сам.
    @discardableResult
    func finishPendingRevocations(now: Date = Date()) async -> [String] {
        // Метку `erasedAt` ставит стирание, прямо в файл. Без перечитывания мы
        // бы её не увидели, а сохранив свой старый список — стёрли.
        reload()
        sweepExpired(now: now)

        var revoked: [String] = []
        for (meetingID, record) in records where record.awaitsRevocation {
            do { try await client.revoke(id: record.id, token: record.token) } catch { continue }
            revoked.append(meetingID)
        }
        guard !revoked.isEmpty else { return [] }

        // Пока ходили в сеть, файл могли поправить — перечитываем и вынимаем
        // только подтверждённое.
        reload()
        for id in revoked { records[id] = nil }
        save()
        return revoked
    }

    /// Выбросить записи, чей срок вышел. Возвращает выброшенные id.
    ///
    /// Отзывать там нечего: бэкапов у сервера нет осознанно (`SERVER.md` §1), и
    /// по истечении срока копии не существует. А запись оставалась и делала
    /// вид, что публикация есть: экран показывал «Опубликовать» (`record(for:)`
    /// уже отдавал nil), а файл — что встреча опубликована. Разъезд ровно там,
    /// где потом ищут, живая ли ссылка.
    @discardableResult
    func sweepExpired(now: Date = Date()) -> [String] {
        let dead = ShareStore.expiredIDs(in: records, now: now)
        guard !dead.isEmpty else { return [] }
        for id in dead { records[id] = nil }
        save()
        return dead
    }

    // MARK: - Файл со списком

    /// Перечитать файл с диска.
    ///
    /// Нужен, потому что писателей у `shares.json` теперь двое: этот сервис и
    /// стирание встречи (`ArchiveEraser` ставит метку `erasedAt`). Список в
    /// памяти после стирания устарел, и `save()` без перечитывания затёр бы
    /// чужую метку — то есть выбросил бы очередь отзыва.
    func reload() {
        records = ShareStore.read(storeURL)
    }

    private func save() {
        ShareStore.write(records, to: storeURL)
    }
}

// MARK: - Сеть

struct ShareClient {

    /// Ключ публикации. Лежит в `Info.plist`, куда его кладёт `build.sh` из
    /// `swift/.share-secret` (в .gitignore — репозиторий публичный).
    ///
    /// **Не Keychain**, и это решение владельца 2026-08-27, а не удобство.
    /// В связке ключей он был бы только у автора: у всех остальных
    /// «Поделиться» не работало бы вовсе, а первое обращение macOS вынесла бы
    /// на подтверждение. Ключ нужен каждому, кто поставил приложение, —
    /// значит, он часть установки, как веса ASR и рантайм LLM, а не чья-то
    /// личная тайна. Отсюда же ушла и вся возня с отложенным чтением связки:
    /// читать `Info.plist` можно сколько угодно и когда угодно.
    ///
    /// **Цена названа вслух:** ключ уезжает внутри приложения и извлекается
    /// любым, кто его скачал (`plutil -p Propeller.app/Contents/Info.plist`).
    /// Он гейтит **только выпуск** ссылок. Прочитать чужой шер им нельзя —
    /// содержимое лежит под ключом, которого нет ни у сервера, ни в
    /// приложении; снять чужую публикацию нельзя — для этого нужен токен, а на
    /// сервере от него только SHA-256. Это порог выше «curl из скрипта», а не
    /// секрет. Настоящая защита выпуска — токен на установку, и её здесь нет.
    /// Смена ключа = новая сборка, старые сборки перестают публиковать.
    static let infoPlistKey = "PropellerShareSecret"

    private let session: URLSession
    private let secret: String?
    private let base: URL

    init(
        session: URLSession = .shared,
        secret: String? = Bundle.main.object(forInfoDictionaryKey: ShareClient.infoPlistKey) as? String,
        base: URL = URL(string: ShareLink.host)!
    ) {
        self.session = session
        self.secret = secret
        self.base = base
    }

    /// Спрашивает связку ключей — звать только там, где ответ нужен по делу.
    var hasSecret: Bool { secret?.isEmpty == false }

    struct Published {
        let id: String
        let token: String
        let expiresAt: Date
    }

    func publish(blob: Data, lifetime: ShareService.Lifetime) async throws -> Published {
        guard let secret, !secret.isEmpty else { throw ShareError.noSecret }

        var components = URLComponents(
            url: base.appendingPathComponent("api/shares"), resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "ttl", value: lifetime.rawValue)]
        guard let url = components?.url else { throw ShareError.malformedLink }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer " + secret, forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = blob

        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw ShareError.server(code) }

        struct Reply: Decodable {
            let id: String
            let token: String
            let expiresAt: TimeInterval
        }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        return Published(
            id: reply.id,
            token: reply.token,
            expiresAt: Date(timeIntervalSince1970: reply.expiresAt)
        )
    }

    func revoke(id: String, token: String) async throws {
        guard let secret, !secret.isEmpty else { throw ShareError.noSecret }

        var request = URLRequest(url: base.appendingPathComponent("api/shares/\(id)"))
        request.httpMethod = "DELETE"
        request.setValue("Bearer " + secret, forHTTPHeaderField: "Authorization")
        request.setValue(token, forHTTPHeaderField: "X-Share-Token")

        let (_, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        // 404 — тоже успех: ссылки уже нет, а сервер не рассказывает, почему
        // именно (§3.6). Настаивать не на чем.
        guard code == 204 || code == 404 else { throw ShareError.server(code) }
    }
}

enum ShareError: LocalizedError {
    case noSecret
    case encryptionFailed
    case malformedLink
    case server(Int)

    var errorDescription: String? {
        switch self {
        case .noSecret:
            return "Эта сборка собрана без ключа публикации — поделиться ссылкой нельзя."
        case .encryptionFailed:
            return "Не удалось зашифровать саммари."
        case .malformedLink:
            return "Сервер вернул ссылку, которую не получается собрать."
        case let .server(code) where code == 401:
            return "Сервер не принял ключ публикации."
        case let .server(code) where code == 413:
            return "Саммари слишком большое для ссылки."
        case let .server(code) where code == 0:
            return "Не получилось связаться с сервером. Проверьте сеть."
        case let .server(code):
            return "Сервер ответил ошибкой \(code)."
        }
    }
}

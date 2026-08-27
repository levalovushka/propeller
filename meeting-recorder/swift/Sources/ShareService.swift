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

    struct Record: Codable, Equatable {
        let id: String
        /// Токен отзыва. На сервере лежит только его хеш — значит, снять
        /// публикацию может ровно эта машина и никто больше.
        let token: String
        /// Ключ шифрования, base64url. Хранится, потому что ссылку надо уметь
        /// показать ещё раз («Скопировать», «Перейти»), а восстановить ключ
        /// неоткуда: у сервера его нет.
        let key: String
        let expiresAt: Date
        let title: String

        var url: URL? {
            guard let raw = ShareLink.data(base64url: key) else { return nil }
            return ShareLink.url(id: id, key: raw, title: title)
        }
    }

    @Published private(set) var records: [String: Record] = [:]

    private let client: ShareClient
    private let storeURL: URL

    init(client: ShareClient = ShareClient(), storeURL: URL? = nil) {
        self.client = client
        self.storeURL = storeURL ?? Self.defaultStoreURL
        self.records = Self.load(from: self.storeURL)
    }

    // MARK: - Что знает приложение

    /// Живая публикация этой встречи — или nil, если её нет или срок вышел.
    ///
    /// Просроченная запись не показывается и не удаляется: удалять её здесь
    /// значило бы менять файл при чтении. Её подметает следующая публикация.
    func record(for meetingID: String, now: Date = Date()) -> Record? {
        guard let record = records[meetingID], record.expiresAt > now else { return nil }
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

    // MARK: - Файл со списком

    private static var defaultStoreURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Meeting Recorder", isDirectory: true)
            .appendingPathComponent("shares.json")
    }

    private static func load(from url: URL) -> [String: Record] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode([String: Record].self, from: data)) ?? [:]
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(records) else { return }
        try? FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // Файл держит токены отзыва — читать его посторонним незачем.
        try? data.write(to: storeURL, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: storeURL.path
        )
    }
}

// MARK: - Сеть

struct ShareClient {

    /// Секрет публикации. Он гейтит только создание шера: прочитать чужой им
    /// нельзя, отозвать чужой нельзя (для этого нужен токен), — но выпускать
    /// ссылки от нашего имени можно. Репозиторий публичный, поэтому в код
    /// секрет не зашит: он лежит в Keychain этой машины и больше нигде.
    static let keychainAccount = "share-secret"

    private let session: URLSession
    /// Замыкание, а не значение: читать связку ключей на создании клиента —
    /// значит спрашивать пароль тогда, когда человек ещё ничего не просил.
    ///
    /// Секрет положен `security add-generic-password` без `-T`, поэтому в его
    /// ACL не значится ни одно приложение, и первое обращение macOS выносит на
    /// подтверждение (`TAILS.md`). До 2026-08-27 обращение случалось при первом
    /// касании `ShareService.shared` — то есть на **открытии** плиты
    /// публикации, где ещё ничего не публикуют. Теперь оно там, где человек
    /// нажал «Опубликовать».
    private let secret: () -> String?
    private let base: URL

    init(
        session: URLSession = .shared,
        secret: @escaping @autoclosure () -> String? =
            KeychainHelper.get(account: ShareClient.keychainAccount),
        base: URL = URL(string: ShareLink.host)!
    ) {
        self.session = session
        self.secret = secret
        self.base = base
    }

    /// Спрашивает связку ключей — звать только там, где ответ нужен по делу.
    var hasSecret: Bool { secret()?.isEmpty == false }

    struct Published {
        let id: String
        let token: String
        let expiresAt: Date
    }

    func publish(blob: Data, lifetime: ShareService.Lifetime) async throws -> Published {
        guard let secret = secret(), !secret.isEmpty else { throw ShareError.noSecret }

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
        guard let secret = secret(), !secret.isEmpty else { throw ShareError.noSecret }

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

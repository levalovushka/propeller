import Foundation
import PropellerPure

/// # Архив глазами сервера — только чтение
///
/// Ни одной записи в `~/.meeting-recorder`, включая индекс. Это не осторожность,
/// а условие: процесс поднимает Claude Desktop, он живёт вне жизненного цикла
/// Пропеллера, и два писателя одного индекса — это способ потерять архив, а не
/// способ ответить на вопрос. Единственное, что сервер пишет, — отметка о своём
/// запуске, и она лежит в Application Support (`Handshake`).
///
/// Пути берутся из настроек самого Пропеллера (домен `com.simplyai.meeting-recorder`),
/// потому что человек мог перенести архив; если настройки недоступны — умолчания.
enum Archive {

    static let defaultsDomain = "com.simplyai.meeting-recorder"

    /// Настройки приложения — те же самые, а не копия.
    ///
    /// Бинарь лежит в `Propeller.app/Contents/MacOS`, поэтому `Bundle.main` для
    /// него — само приложение, и `UserDefaults.standard` уже читает его домен.
    /// Просить ту же сюиту по имени **нельзя**: `UserDefaults(suiteName:)` со
    /// своим же bundle id не работает и говорит об этом в stderr. Сюита нужна
    /// только когда бинарь запущен сам по себе — из `.build/debug` на отладке.
    private static var defaults: UserDefaults {
        if Bundle.main.bundleIdentifier == defaultsDomain { return .standard }
        return UserDefaults(suiteName: defaultsDomain) ?? .standard
    }

    private static func home() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
    }

    static var recordingsPath: String {
        let fallback = home().appendingPathComponent(".meeting-recorder/recordings").path
        return ArchivePath.normalized(defaults.string(forKey: "recordingsPath"), default: fallback)
    }

    static var meetingsPath: String {
        let fallback = home().appendingPathComponent(".meeting-recorder/meetings").path
        return ArchivePath.normalized(defaults.string(forKey: "meetingsPath"), default: fallback)
    }

    /// Переключатель телеметрии из настроек приложения. Сервер спрашивает его
    /// перед тем, как записать хоть одну строку про свои вызовы: выключено —
    /// значит счёт не ведётся, а не ведётся и лежит.
    static var analyticsEnabled: Bool {
        defaults.object(forKey: "analyticsEnabled") as? Bool ?? true
    }

    static var indexURL: URL {
        URL(fileURLWithPath: recordingsPath).appendingPathComponent("recordings.json")
    }

    // MARK: - Запись индекса

    /// Ровно те поля, которые сервер отдаёт наружу.
    ///
    /// Своя структура, а не `RecordingEntry`: та живёт в исполняемом таргете
    /// приложения, и тянуть её сюда значило бы тянуть за ней `AppState`.
    /// Декодер терпимый — незнакомое поле не должно ронять чтение, потому что
    /// индекс пишет приложение, которое обновляется отдельно от этого бинаря.
    struct Entry: Decodable {
        let id: String
        let date: Date
        let title: String
        let duration: Double
        let transcript: String?
        let notes: String?
        let topics: [String]?
        let tags: [String]?
        let mergedSegmentsJSON: String?
        let liveSegmentsJSON: String?
        /// Кого звали. Единственное место в архиве, где у участников есть
        /// настоящие имена: диаризация называет только владельца микрофона.
        let calendarMeta: CalendarMeta?
    }

    /// Индекс, от новых встреч к старым.
    ///
    /// Переживает и отсутствие файла, и его карантин (C5): на месте индекса
    /// может не оказаться ничего, и это не ошибка сервера — это архив, который
    /// приложение сейчас чинит.
    static func entries() -> [Entry] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let all = try? decoder.decode([Entry].self, from: data) {
            return all.sorted { $0.date > $1.date }
        }
        // Одна битая запись не должна прятать остальной архив — тот же приём,
        // что в `RecordingStore.load`.
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        var recovered: [Entry] = []
        for item in array {
            guard JSONSerialization.isValidJSONObject(item),
                  let itemData = try? JSONSerialization.data(withJSONObject: item),
                  let entry = try? decoder.decode(Entry.self, from: itemData) else { continue }
            recovered.append(entry)
        }
        return recovered.sorted { $0.date > $1.date }
    }

    // MARK: - Файлы встречи

    private static func meetingFiles() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: meetingsPath)) ?? []
    }

    /// Конспект встречи, если он записан. Ищется по идентификатору, а не по
    /// слагу: заголовок могли поменять после того, как файл назвали.
    static func recap(for id: String, in files: [String]? = nil) -> String? {
        let names = files ?? meetingFiles()
        guard let name = names.first(where: { RecapFile.isRecap($0, for: id) }) else { return nil }
        let url = URL(fileURLWithPath: meetingsPath).appendingPathComponent(name)
        return try? String(contentsOf: url, encoding: .utf8)
    }

    static func segments(of entry: Entry) -> [PersistedSegment] {
        let json = entry.mergedSegmentsJSON ?? entry.liveSegmentsJSON
        guard let json, let data = json.data(using: .utf8),
              let parsed = try? JSONDecoder().decode([PersistedSegment].self, from: data) else { return [] }
        return parsed.sorted { $0.startTime < $1.startTime }
    }

    // MARK: - Карточки

    private static let dateLabelFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMMM yyyy, HH:mm"
        return formatter
    }()

    static func dateLabel(_ date: Date) -> String {
        dateLabelFormatter.string(from: date)
    }

    /// Встречи в том виде, в каком по ним ищут: тексты уже прочитаны.
    ///
    /// Конспекты читаются здесь, один раз на запрос, а не по разу на встречу в
    /// цикле сравнения — тот же урок, что стоил `SearchPalette` двухсот чтений
    /// на нажатие клавиши (`ArchiveSearch`).
    static func cards() -> [(card: MeetingCard, recap: String?)] {
        let files = meetingFiles()
        return entries().map { entry in
            let recap = recap(for: entry.id, in: files)
            let people = Array(Set(segments(of: entry).map(\.speaker))).sorted()
            let invited = invited(of: entry)
            var bodies: [String] = []
            if let transcript = entry.transcript, !transcript.isEmpty { bodies.append(transcript) }
            if let notes = entry.notes, !notes.isEmpty { bodies.append(notes) }
            if let recap, !recap.isEmpty { bodies.append(recap) }
            let card = MeetingCard(
                id: entry.id,
                date: entry.date,
                title: entry.title,
                durationSeconds: entry.duration,
                topics: entry.topics ?? [],
                tags: entry.tags ?? [],
                people: people,
                invited: invited,
                dateLabel: dateLabel(entry.date),
                bodies: bodies
            )
            return (card, recap)
        }
    }

    static func entry(id: String) -> Entry? {
        entries().first { $0.id == id }
    }

    /// Приглашённые и организатор, без повторов и в том виде, в каком их знает
    /// календарь: где-то имена, где-то почты.
    static func invited(of entry: Entry) -> [String] {
        guard let meta = entry.calendarMeta else { return [] }
        var seen = Set<String>()
        return (meta.attendees + [meta.organizer].compactMap { $0 })
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}

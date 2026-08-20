import EventKit
import Foundation
import PropellerPure

/// A calendar event, read only to answer one question: what is this recording
/// called, and who was in it.
///
/// Sourced from the system Calendar (EventKit), which includes the Google /
/// Exchange accounts the user added in System Settings → Internet Accounts. No
/// OAuth, no cloud — one permission prompt, in keeping with the local-first
/// design.
///
/// It used to be «a meeting in the Upcoming list», and the list is gone
/// (2026-08-04): nothing in the interface shows calendar events, they only name
/// recordings and fill `CalendarMeta`. The type is named for what it is now.
struct CalendarEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let attendees: [String]
    let hasVideoLink: Bool
    /// Everything else the event carried, snapshotted for the recording this
    /// event names.
    var meta: CalendarMeta?
}

@MainActor
final class CalendarService: ObservableObject {
    static let shared = CalendarService()

    /// Пересоздаётся на каждый запрос доступа — см. `enableAndLoad`.
    private var store = EKEventStore()
    /// The window of events around now, kept only so a starting recording can be
    /// matched to one. Nothing draws this.
    @Published var events: [CalendarEvent] = []
    @Published var accessGranted = false
    /// Что ответила система — с разницей между «ещё не спрашивали» и «отказано».
    /// Читает её строка настроек: у первого случая есть окно, у второго только
    /// System Settings (`CalendarAccess`).
    @Published var access: CalendarAccess = .notDetermined

    /// Спросить систему про доступ (если нужно) и загрузить события.
    ///
    /// Хранилище пересоздаётся перед запросом, и это не гигиена, а условие
    /// работы кнопки. Окно разрешения показывается один раз на хранилище: тот
    /// же `EKEventStore`, у которого запрос однажды не удался, дальше отвечает
    /// отказом из кэша — молча, без окна и без строки в TCC. Приложение
    /// спрашивало на запуске, и этим тратило единственную попытку процесса:
    /// нажатие «Разрешить» в настройках после этого не делало ничего видимого
    /// (2026-08-20). Запрос на запуске убран (`AppState`), а каждый следующий
    /// идёт с чистого хранилища — тогда и второе нажатие показывает окно.
    func enableAndLoad() async {
        store = EKEventStore()
        let granted: Bool
        if #available(macOS 14.0, *) {
            granted = (try? await store.requestFullAccessToEvents()) ?? false
        } else {
            granted = await withCheckedContinuation { cont in
                store.requestAccess(to: .event) { ok, _ in cont.resume(returning: ok) }
            }
        }
        accessGranted = granted
        // Не `granted ? .granted : .denied`: отказ бывает «окно закрыли, статус
        // остался notDetermined», и обещать тогда System Settings рано.
        access = Self.currentAccess()
        if granted { load() }
    }

    /// Перечитать ответ системы, ничего у неё не спрашивая.
    ///
    /// Нужно строке настроек: человек уходит выдавать доступ руками и обязан
    /// вернуться к изменившейся строке. Запрос здесь был бы окном на открытие
    /// настроек.
    func refreshAccess() {
        access = Self.currentAccess()
        accessGranted = access == .granted
    }

    static func currentAccess() -> CalendarAccess {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .notDetermined:
            return .notDetermined
        case .fullAccess:
            return .granted
        case .authorized:
            // До macOS 14 полный доступ назывался так.
            return .granted
        default:
            // `.denied`, `.restricted` и `.writeOnly`. Право дописывать события
            // ничего не говорит о праве их читать, а читаем мы.
            return .denied
        }
    }

    /// Refresh the event window. Safe to call repeatedly; no-op without access.
    func load() {
        access = Self.currentAccess()
        guard access == .granted else { accessGranted = false; return }
        accessGranted = true

        let now = Date()
        // Reach a few hours back so an in-progress meeting (started earlier) is
        // still available for recording title matching.
        let rangeStart = Calendar.current.date(byAdding: .hour, value: -4, to: now)!
        let end = Calendar.current.date(byAdding: .day, value: 7, to: now)!
        let predicate = store.predicateForEvents(withStart: rangeStart, end: end, calendars: nil)
        events = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
            .prefix(25)
            .map { ev in
                CalendarEvent(
                    id: ev.eventIdentifier ?? UUID().uuidString,
                    title: (ev.title?.isEmpty == false ? ev.title! : "Без названия"),
                    start: ev.startDate,
                    end: ev.endDate,
                    attendees: (ev.attendees ?? []).compactMap { $0.name },
                    hasVideoLink: Self.hasVideoLink(ev),
                    meta: Self.meta(for: ev)
                )
            }
    }

    // Muting used to live here: «Don't record» on an Upcoming row set an event
    // aside so auto-record would skip it (DECIDE-6). With no list there is no way
    // to say it, so the mute became a branch nothing could ever enter — removed
    // with the list. Declining a recording that has *started* is still there, in
    // the notification's «Не записывать».

    /// Best calendar event to name a recording started at `date`.
    /// Prefers an in-progress meeting (especially with a video link), then one
    /// starting within the next 15 minutes.
    func matchingMeeting(at date: Date = Date()) -> CalendarEvent? {
        guard accessGranted else { return nil }
        let inProgress = events.filter { $0.start <= date && date < $0.end }
        if let hit = Self.pickBest(inProgress) { return hit }
        let startingSoon = events.filter {
            let delta = $0.start.timeIntervalSince(date)
            return delta >= 0 && delta <= 15 * 60
        }
        return Self.pickBest(startingSoon)
    }

    /// Non-empty calendar title for a new recording, or nil to keep the default.
    func suggestedRecordingTitle(at date: Date = Date()) -> String? {
        guard let meeting = matchingMeeting(at: date) else { return nil }
        let t = meeting.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.lowercased() != "untitled" else { return nil }
        return t
    }

    /// Calendar metadata for a recording started at `date`, or nil when nothing
    /// matched. Same event the title comes from, so the two can never disagree.
    func suggestedRecordingMeta(at date: Date = Date()) -> CalendarMeta? {
        guard let meta = matchingMeeting(at: date)?.meta, !meta.isEmpty else { return nil }
        return meta
    }

    private static func pickBest(_ meetings: [CalendarEvent]) -> CalendarEvent? {
        guard !meetings.isEmpty else { return nil }
        let named = meetings.filter {
            let t = $0.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return !t.isEmpty && t.lowercased() != "untitled"
        }
        let pool = named.isEmpty ? meetings : named
        return pool.first(where: \.hasVideoLink) ?? pool.first
    }

    private static func hasVideoLink(_ ev: EKEvent) -> Bool {
        let text = [ev.location, ev.notes, ev.url?.absoluteString]
            .compactMap { $0 }.joined(separator: " ").lowercased()
        return text.contains("zoom.us") || text.contains("meet.google")
            || text.contains("telemost") || text.contains("teams.microsoft")
            || text.contains("vk.com/call") || text.contains("whereby")
    }

    /// Snapshot of the event, taken while the calendar is still in reach. Read
    /// only here: EventKit objects must not outlive the store that vended them,
    /// and a recording outlives everything.
    private static func meta(for ev: EKEvent) -> CalendarMeta {
        CalendarMeta(
            eventID: ev.eventIdentifier ?? "",
            seriesID: ev.calendarItemExternalIdentifier,
            title: ev.title ?? "",
            calendarName: ev.calendar?.title,
            organizer: ev.organizer?.name,
            attendees: (ev.attendees ?? []).compactMap { $0.name },
            conferenceURL: conferenceURL(ev),
            start: ev.startDate,
            end: ev.endDate,
            isRecurring: ev.hasRecurrenceRules
        )
    }

    /// First call link on the event. The URL field is the reliable one; the
    /// location and notes are where people actually paste it.
    private static func conferenceURL(_ ev: EKEvent) -> String? {
        if let url = ev.url?.absoluteString, isCallLink(url) { return url }
        let haystack = [ev.location, ev.notes].compactMap { $0 }.joined(separator: " ")
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(haystack.startIndex..., in: haystack)
        let matches = detector?.matches(in: haystack, range: range) ?? []
        for match in matches {
            guard let link = match.url?.absoluteString else { continue }
            if isCallLink(link) { return link }
        }
        return nil
    }

    private static func isCallLink(_ link: String) -> Bool {
        let l = link.lowercased()
        return l.contains("zoom.us") || l.contains("meet.google")
            || l.contains("telemost") || l.contains("teams.microsoft")
            || l.contains("vk.com/call") || l.contains("whereby")
    }
}

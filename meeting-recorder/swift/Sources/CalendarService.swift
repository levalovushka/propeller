import EventKit
import Foundation

/// A calendar event surfaced in the "Upcoming" list. Read-only; sourced from the
/// system Calendar (EventKit), which includes Google/Exchange accounts the user
/// has added in System Settings → Internet Accounts. No OAuth, no cloud — just a
/// calendar-access permission prompt, in keeping with the local-first design.
struct UpcomingMeeting: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let attendees: [String]
    let hasVideoLink: Bool

    /// "Сегодня · 16:45", "Завтра · 16:45", or "пт · 16:45".
    var whenLabel: String {
        let cal = Calendar.current
        let time = Self.timeFormatter.string(from: start)
        if cal.isDateInToday(start) { return "Сегодня · \(time)" }
        if cal.isDateInTomorrow(start) { return "Завтра · \(time)" }
        return "\(Self.weekdayFormatter.string(from: start)) · \(time)"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "EEE"
        return f
    }()
}

@MainActor
final class CalendarService: ObservableObject {
    static let shared = CalendarService()

    private let store = EKEventStore()
    @Published var upcoming: [UpcomingMeeting] = []
    @Published var accessGranted = false
    /// Events muted via Upcoming «Don't record» this session (DECIDE-6: mute session).
    /// Kept even after removal from `upcoming` so Zoom auto-record can still match them.
    private var mutedEventIDs: Set<String> = []
    private var mutedMeetings: [String: UpcomingMeeting] = [:]

    /// Prompt for calendar access (if needed) and load upcoming events.
    func enableAndLoad() async {
        let granted: Bool
        if #available(macOS 14.0, *) {
            granted = (try? await store.requestFullAccessToEvents()) ?? false
        } else {
            granted = await withCheckedContinuation { cont in
                store.requestAccess(to: .event) { ok, _ in cont.resume(returning: ok) }
            }
        }
        accessGranted = granted
        if granted { load() }
    }

    /// Refresh the upcoming list. Safe to call repeatedly; no-op without access.
    func load() {
        let status = EKEventStore.authorizationStatus(for: .event)
        let ok: Bool
        if #available(macOS 14.0, *) {
            ok = status == .fullAccess
        } else {
            ok = status == .authorized
        }
        guard ok else { accessGranted = false; return }
        accessGranted = true

        let now = Date()
        // Reach a few hours back so an in-progress meeting (started earlier) is
        // still available for recording title matching.
        let rangeStart = Calendar.current.date(byAdding: .hour, value: -4, to: now)!
        let end = Calendar.current.date(byAdding: .day, value: 7, to: now)!
        let predicate = store.predicateForEvents(withStart: rangeStart, end: end, calendars: nil)
        upcoming = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
            .prefix(25)
            .map { ev in
                UpcomingMeeting(
                    id: ev.eventIdentifier ?? UUID().uuidString,
                    title: (ev.title?.isEmpty == false ? ev.title! : "Без названия"),
                    start: ev.startDate,
                    end: ev.endDate,
                    attendees: (ev.attendees ?? []).compactMap { $0.name },
                    hasVideoLink: Self.hasVideoLink(ev)
                )
            }
            .filter { !mutedEventIDs.contains($0.id) }
    }

    /// Hide from Upcoming and mute Zoom auto-record while this event is in progress
    /// (or starting within 15 minutes).
    func dismiss(_ meeting: UpcomingMeeting) {
        mutedEventIDs.insert(meeting.id)
        mutedMeetings[meeting.id] = meeting
        upcoming.removeAll { $0.id == meeting.id }
    }

    /// True when the user muted the calendar meeting that covers `date`.
    func isMutedForRecording(at date: Date = Date()) -> Bool {
        pruneMuted(at: date)
        for m in mutedMeetings.values {
            if m.start <= date && date < m.end { return true }
            let delta = m.start.timeIntervalSince(date)
            if delta >= 0 && delta <= 15 * 60 { return true }
        }
        return false
    }

    private func pruneMuted(at date: Date) {
        mutedMeetings = mutedMeetings.filter { $0.value.end > date.addingTimeInterval(-60) }
        mutedEventIDs = Set(mutedMeetings.keys)
    }

    /// Best calendar event to name a recording started at `date`.
    /// Prefers an in-progress meeting (especially with a video link), then one
    /// starting within the next 15 minutes.
    func matchingMeeting(at date: Date = Date()) -> UpcomingMeeting? {
        guard accessGranted else { return nil }
        let inProgress = upcoming.filter { $0.start <= date && date < $0.end }
        if let hit = Self.pickBest(inProgress) { return hit }
        let startingSoon = upcoming.filter {
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

    private static func pickBest(_ meetings: [UpcomingMeeting]) -> UpcomingMeeting? {
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
}

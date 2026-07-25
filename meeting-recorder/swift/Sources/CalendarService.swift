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

    /// "Today · 16:45", "Tomorrow · 16:45", or "Fri · 16:45".
    var whenLabel: String {
        let cal = Calendar.current
        let time = Self.timeFormatter.string(from: start)
        if cal.isDateInToday(start) { return "Today · \(time)" }
        if cal.isDateInTomorrow(start) { return "Tomorrow · \(time)" }
        return "\(Self.weekdayFormatter.string(from: start)) · \(time)"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE"; return f
    }()
}

@MainActor
final class CalendarService: ObservableObject {
    static let shared = CalendarService()

    private let store = EKEventStore()
    @Published var upcoming: [UpcomingMeeting] = []
    @Published var accessGranted = false
    /// Events the user dismissed from the Upcoming list this session.
    private var dismissed: Set<String> = []

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
                    title: (ev.title?.isEmpty == false ? ev.title! : "Untitled"),
                    start: ev.startDate,
                    end: ev.endDate,
                    attendees: (ev.attendees ?? []).compactMap { $0.name },
                    hasVideoLink: Self.hasVideoLink(ev)
                )
            }
            .filter { !dismissed.contains($0.id) }
    }

    func dismiss(_ meeting: UpcomingMeeting) {
        dismissed.insert(meeting.id)
        upcoming.removeAll { $0.id == meeting.id }
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

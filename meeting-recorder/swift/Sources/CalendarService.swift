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
        let end = Calendar.current.date(byAdding: .day, value: 7, to: now)!
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
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

    private static func hasVideoLink(_ ev: EKEvent) -> Bool {
        let text = [ev.location, ev.notes, ev.url?.absoluteString]
            .compactMap { $0 }.joined(separator: " ").lowercased()
        return text.contains("zoom.us") || text.contains("meet.google")
            || text.contains("telemost") || text.contains("teams.microsoft")
            || text.contains("vk.com/call") || text.contains("whereby")
    }
}

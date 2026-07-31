import Foundation

/// What the calendar knew about a meeting at the moment recording started.
///
/// Recorded because the strongest signal for "which meetings belong together"
/// is an identifier, not text: a weekly sync is not a set of similar-looking
/// meetings, it is *one* calendar event with one series identifier and a
/// near-constant attendee list. EventKit hands those over for free, and until
/// now the recorder read the event's title and dropped everything else.
///
/// Nothing consumes this yet — it is persisted with the recording and written
/// into the meeting document so the archive already carries the answer by the
/// time something asks the question.
public struct CalendarMeta: Codable, Equatable, Sendable {
    /// `EKEvent.eventIdentifier`. Shared by the occurrences of a recurring
    /// event, which is exactly why it is worth keeping.
    public let eventID: String
    /// `EKEvent.calendarItemExternalIdentifier` — the organiser-side identity of
    /// the event, stable across devices and accounts. The series key.
    public let seriesID: String?
    /// Event title as the calendar had it. Kept separately from the recording's
    /// title, which the user or the LLM may rewrite later.
    public let title: String
    /// Calendar the event lives in ("Работа", "Личное").
    public let calendarName: String?
    public let organizer: String?
    /// Attendee display names: trimmed, empties dropped, duplicates removed,
    /// order preserved.
    public let attendees: [String]
    /// Video-call link found on the event. A team's permanent room is another
    /// identifier that groups meetings.
    public let conferenceURL: String?
    public let start: Date?
    public let end: Date?
    public let isRecurring: Bool

    public init(
        eventID: String,
        seriesID: String? = nil,
        title: String = "",
        calendarName: String? = nil,
        organizer: String? = nil,
        attendees: [String] = [],
        conferenceURL: String? = nil,
        start: Date? = nil,
        end: Date? = nil,
        isRecurring: Bool = false
    ) {
        self.eventID = Self.clean(eventID) ?? ""
        self.seriesID = Self.clean(seriesID)
        self.title = Self.clean(title) ?? ""
        self.calendarName = Self.clean(calendarName)
        self.organizer = Self.clean(organizer)
        self.attendees = Self.normalized(attendees)
        self.conferenceURL = Self.clean(conferenceURL)
        self.start = start
        self.end = end
        self.isRecurring = isRecurring
    }

    /// Nothing worth writing down: no identifier, no title, nobody invited.
    public var isEmpty: Bool {
        eventID.isEmpty && (seriesID ?? "").isEmpty && title.isEmpty && attendees.isEmpty
    }

    // MARK: - Rendering

    /// YAML front-matter lines for the Obsidian format. Keys are prefixed so
    /// they can never collide with the note's own fields, and a key whose value
    /// is missing is omitted rather than written empty.
    public var yamlFrontmatterLines: [String] {
        var lines: [String] = []
        func put(_ key: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            lines.append("\(key): \"\(Self.yamlEscaped(value))\"")
        }
        put("calendar_event_id", eventID)
        put("calendar_series_id", seriesID)
        put("calendar_title", title)
        put("calendar_name", calendarName)
        put("calendar_organizer", organizer)
        if !attendees.isEmpty {
            let items = attendees.map { "\"\(Self.yamlEscaped($0))\"" }
            lines.append("calendar_attendees: [\(items.joined(separator: ", "))]")
        }
        put("calendar_conference_url", conferenceURL)
        put("calendar_start", start.map(Self.iso))
        put("calendar_end", end.map(Self.iso))
        if isRecurring {
            lines.append("calendar_recurring: true")
        }
        return lines
    }

    /// Header lines for the plain format. Readable first — the identifiers come
    /// last, on one line, because a document that keeps only the pretty half is
    /// a document that cannot be joined to anything later.
    public var plainHeaderLines: [String] {
        var lines: [String] = []
        let heading = [title, calendarName, isRecurring ? "повторяется" : nil]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        if !heading.isEmpty {
            lines.append("**Calendar:** \(heading.joined(separator: " · "))")
        }
        if let organizer, !organizer.isEmpty {
            lines.append("**Organizer:** \(organizer)")
        }
        if !attendees.isEmpty {
            lines.append("**Invited:** \(attendees.joined(separator: ", "))")
        }
        if let conferenceURL, !conferenceURL.isEmpty {
            lines.append("**Call:** \(conferenceURL)")
        }
        let ids = [
            eventID.isEmpty ? nil : "event \(eventID)",
            (seriesID?.isEmpty == false) ? "series \(seriesID!)" : nil,
        ].compactMap { $0 }
        if !ids.isEmpty {
            lines.append("**Calendar ID:** \(ids.joined(separator: ", "))")
        }
        return lines
    }

    // MARK: - Helpers

    private static func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalized(_ names: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for name in names {
            guard let cleaned = clean(name), !seen.contains(cleaned) else { continue }
            seen.insert(cleaned)
            out.append(cleaned)
        }
        return out
    }

    /// Front matter is parsed by other tools, so a stray quote must not end the
    /// value early. Same substitution the note's own `title:` already uses.
    private static func yamlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f.string(from: date)
    }
}

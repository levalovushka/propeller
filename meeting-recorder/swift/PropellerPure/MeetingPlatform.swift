import Foundation

/// A conferencing app Propeller can notice a call in.
///
/// Everything platform-specific is data, not code: adding one is a row in
/// `MeetingPlatform.all`, and the rules that read it are pure functions with
/// tests. The window-title rules matter most — Zoom's idle panels («Настройки»,
/// «Чат») used to false-trigger auto-record, and every fix there is one word in
/// a list away from starting a recording nobody asked for.
public struct MeetingPlatform: Equatable, Sendable {
    public let id: String
    public let displayName: String
    /// Bundle identifiers of the desktop app, lowercased.
    public let bundleIDs: [String]
    /// Owner names as they appear in the window list, lowercased.
    public let windowOwners: [String]
    /// Helper processes spawned only for an active call. The cheapest signal —
    /// no window list, no permissions.
    public let callHelperProcesses: [String]
    /// Title fragments that mean a call is up (lowercased, matched as substrings).
    public let meetingTitleMarkers: [String]
    /// Titles of idle windows — never a call, whatever else matches.
    public let idleTitles: Set<String>
    /// Web address of the service, for calls held in a browser tab.
    public let webHostFragments: [String]

    public init(
        id: String,
        displayName: String,
        bundleIDs: [String],
        windowOwners: [String],
        callHelperProcesses: [String],
        meetingTitleMarkers: [String],
        idleTitles: Set<String>,
        webHostFragments: [String] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.bundleIDs = bundleIDs
        self.windowOwners = windowOwners
        self.callHelperProcesses = callHelperProcesses
        self.meetingTitleMarkers = meetingTitleMarkers
        self.idleTitles = idleTitles
        self.webHostFragments = webHostFragments
    }
}

extension MeetingPlatform {

    public static let zoom = MeetingPlatform(
        id: "zoom",
        displayName: "Zoom",
        bundleIDs: ["us.zoom.xos"],
        windowOwners: ["zoom.us"],
        // `aomhost` is spawned for calls; `caphost` alone is idle-safe and ignored.
        callHelperProcesses: ["aomhost"],
        meetingTitleMarkers: [
            "zoom meeting", "webinar", "meeting id", "конференция", "вебинар",
        ],
        idleTitles: [
            "", "zoom", "zoom.us", "zoom workplace", "zoom - free account",
            "login", "sign in", "settings", "preferences", "chat", "contacts",
            "войти", "вход", "настройки", "параметры", "чат", "контакты", "зум",
        ]
    )

    /// Контур.Толк.
    ///
    /// **Unverified against a live install** — nobody on the team had it when
    /// this was written, so the identifiers below are the plausible ones and
    /// must be confirmed with `Diagnostics.describeRunningApps()` before
    /// release. The rules are data precisely so that confirming them is a one
    /// line edit, not a code change.
    ///
    /// Talk is commonly used *in a browser*, so `webHostFragments` carries the
    /// address: a browser window whose title mentions the service counts as the
    /// same platform.
    public static let konturTalk = MeetingPlatform(
        id: "kontur-talk",
        displayName: "Контур.Толк",
        bundleIDs: ["ru.kontur.talk", "ru.skbkontur.talk", "ru.kontur.talk.desktop"],
        windowOwners: ["толк", "kontur talk", "контур.толк", "talk"],
        callHelperProcesses: [],
        meetingTitleMarkers: [
            "конференция", "встреча", "созвон", "комната", "meeting", "call",
        ],
        idleTitles: [
            "", "толк", "контур.толк", "kontur talk", "talk",
            "настройки", "параметры", "чат", "контакты", "календарь",
            "settings", "preferences", "chat", "contacts", "calendar",
            "вход", "войти", "login", "sign in",
        ],
        webHostFragments: ["talk.kontur.ru", "контур.толк"]
    )

    public static let all: [MeetingPlatform] = [.zoom, .konturTalk]

    public static func platform(id: String) -> MeetingPlatform? {
        all.first { $0.id == id }
    }
}

// MARK: - Rules

extension MeetingPlatform {

    public func owns(bundleID: String?, appName: String?) -> Bool {
        if let bundleID, bundleIDs.contains(bundleID.lowercased()) { return true }
        if let appName {
            let name = appName.lowercased()
            if windowOwners.contains(name) { return true }
        }
        return false
    }

    /// Does this window title mean a call is up?
    ///
    /// Idle titles win over markers: a settings panel called «Настройки» must
    /// never start a recording, even when the app is a conferencing one.
    public func titleMeansCall(_ rawTitle: String) -> Bool {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !title.isEmpty, !idleTitles.contains(title) else { return false }
        return meetingTitleMarkers.contains { title.contains($0) }
    }

    /// A browser window can be the call itself when the service runs on the web.
    /// Requires both the address and a call marker, so the service's landing
    /// page or a docs tab does not trigger anything.
    public func browserTitleMeansCall(_ rawTitle: String) -> Bool {
        guard !webHostFragments.isEmpty else { return false }
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !title.isEmpty, !idleTitles.contains(title) else { return false }
        guard webHostFragments.contains(where: { title.contains($0) }) else { return false }
        return meetingTitleMarkers.contains { title.contains($0) }
    }
}

/// What one poll saw.
public struct MeetingSnapshot: Equatable, Sendable {
    /// Platform whose call is up, if any.
    public let platformID: String?
    public let appRunning: Bool
    public let signals: [String]

    public var inMeeting: Bool { platformID != nil }

    public init(platformID: String?, appRunning: Bool, signals: [String]) {
        self.platformID = platformID
        self.appRunning = appRunning
        self.signals = signals
    }

    public static let idle = MeetingSnapshot(platformID: nil, appRunning: false, signals: [])
}

/// Turns raw poll readings into "are we in a call", with hysteresis.
///
/// Kept apart from the polling so the debounce can be tested: a detector that
/// flaps starts and stops recordings on its own, and that is not something to
/// discover during a real meeting.
public struct MeetingDebounce {
    /// Consecutive positives before a call counts as started.
    public let enterThreshold: Int
    /// Consecutive negatives before it is considered over. Higher than
    /// `enterThreshold`: a brief blind spot mid-call must not stop a recording.
    public let exitThreshold: Int

    private var positives = 0
    private var negatives = 0
    public private(set) var isInMeeting = false

    public init(enterThreshold: Int = 2, exitThreshold: Int = 3) {
        self.enterThreshold = enterThreshold
        self.exitThreshold = exitThreshold
    }

    public enum Transition: Equatable, Sendable {
        case none
        case started(platformID: String)
        case ended
    }

    public mutating func observe(_ snapshot: MeetingSnapshot) -> Transition {
        if let platformID = snapshot.platformID {
            positives += 1
            negatives = 0
            if !isInMeeting, positives >= enterThreshold {
                isInMeeting = true
                return .started(platformID: platformID)
            }
        } else {
            negatives += 1
            positives = 0
            if isInMeeting, negatives >= exitThreshold {
                isInMeeting = false
                return .ended
            }
        }
        return .none
    }

    /// The app quit — end immediately, no debounce to wait for.
    public mutating func reset() -> Transition {
        positives = 0
        negatives = 0
        guard isInMeeting else { return .none }
        isInMeeting = false
        return .ended
    }
}

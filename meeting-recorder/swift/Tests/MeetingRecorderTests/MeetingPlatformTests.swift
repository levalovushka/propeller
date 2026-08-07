import XCTest
@testable import PropellerPure

/// Auto-record starts a recording without asking, so a false positive is a
/// recording nobody wanted and a false negative is a lost meeting. Both live in
/// these rules.
final class MeetingPlatformTests: XCTestCase {

    // MARK: - Zoom (the behaviour already shipped — must not regress)

    func testZoomMeetingTitlesAreRecognised() {
        for title in ["Zoom Meeting", "Личная конференция Левона", "Webinar: Q3", "Meeting ID: 123 456"] {
            XCTAssertTrue(MeetingPlatform.zoom.titleMeansCall(title), title)
        }
    }

    /// The regression that shipped once: Russian idle panels started recordings.
    func testZoomIdlePanelsNeverCount() {
        for title in ["Настройки", "Чат", "Контакты", "Zoom Workplace", "  ", "Zoom", "Вход"] {
            XCTAssertFalse(MeetingPlatform.zoom.titleMeansCall(title), title)
        }
    }

    func testZoomIsIdentifiedByBundleIDAndByName() {
        XCTAssertTrue(MeetingPlatform.zoom.owns(bundleID: "us.zoom.xos", appName: nil))
        XCTAssertTrue(MeetingPlatform.zoom.owns(bundleID: nil, appName: "zoom.us"))
        XCTAssertFalse(MeetingPlatform.zoom.owns(bundleID: "com.figma.Desktop", appName: "Figma"))
    }

    // MARK: - Контур.Толк

    func testTalkCallTitlesAreRecognised() {
        for title in ["Конференция: планёрка", "Встреча команды", "Созвон по релизу", "Комната 42"] {
            XCTAssertTrue(MeetingPlatform.konturTalk.titleMeansCall(title), title)
        }
    }

    func testTalkIdlePanelsNeverCount() {
        for title in ["Толк", "Настройки", "Чат", "Календарь", "Контакты", "", "Вход"] {
            XCTAssertFalse(MeetingPlatform.konturTalk.titleMeansCall(title), title)
        }
    }

    /// Talk is often used in a browser. A tab counts only when it is both on the
    /// service *and* looks like a call — otherwise reading the docs would start
    /// recording.
    func testTalkInABrowserNeedsBothTheAddressAndACallMarker() {
        let talk = MeetingPlatform.konturTalk
        XCTAssertTrue(talk.browserTitleMeansCall("Конференция — talk.kontur.ru"))
        XCTAssertFalse(talk.browserTitleMeansCall("talk.kontur.ru — вход"), "landing page")
        XCTAssertFalse(talk.browserTitleMeansCall("Конференция — Google Meet"), "another service")
        XCTAssertFalse(talk.browserTitleMeansCall("Документация talk.kontur.ru"))
    }

    func testZoomHasNoWebDetectionSoBrowserTitlesNeverMatchIt() {
        XCTAssertFalse(MeetingPlatform.zoom.browserTitleMeansCall("Zoom Meeting — zoom.us"))
    }

    /// 1.15, живой тестер: Толк держит display-sleep assertion, пока кто-нибудь
    /// на звонке демонстрирует экран. Пока этот ассерт считался звонком,
    /// автозапись включалась на старте шера и останавливалась на его остановке —
    /// запись куска чужой демонстрации и обрыв посреди разговора.
    func testTalkNeverCountsADisplaySleepAssertionAsACall() {
        XCTAssertFalse(MeetingPlatform.konturTalk.sleepAssertionMeansCall)
    }

    /// Zoom's fallback behind `CptHost` — shipped since phase 6, must stay.
    func testZoomStillTrustsTheDisplaySleepAssertion() {
        XCTAssertTrue(MeetingPlatform.zoom.sleepAssertionMeansCall)
    }

    /// The assertion is held by whichever process took it, and Electron helpers
    /// are named after the app: attribution has to see through the suffix.
    func testAnAssertionIsAttributedToTheAppWhoseHelperHoldsIt() {
        let talk = MeetingPlatform.konturTalk
        XCTAssertTrue(talk.ownsProcess(named: "Толк"))
        XCTAssertTrue(talk.ownsProcess(named: "Толк Helper (Renderer)"))
        XCTAssertFalse(talk.ownsProcess(named: "zoom.us"))
        XCTAssertTrue(MeetingPlatform.zoom.ownsProcess(named: "zoom.us"))
        XCTAssertFalse(MeetingPlatform.zoom.ownsProcess(named: "Толк Helper"))
    }

    /// A platform that trusts the assertion must be identifiable by process
    /// name — otherwise the signal is held by somebody the table cannot name and
    /// fires for nobody.
    func testEveryPlatformTrustingTheAssertionCanBeAttributedByProcessName() {
        for platform in MeetingPlatform.all where platform.sleepAssertionMeansCall {
            XCTAssertFalse(
                platform.windowOwners.isEmpty && platform.bundleIDs.isEmpty,
                platform.id
            )
        }
    }

    // MARK: - Registry

    func testEveryPlatformIsDistinctAndFindable() {
        let ids = MeetingPlatform.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        for id in ids {
            XCTAssertEqual(MeetingPlatform.platform(id: id)?.id, id)
        }
        XCTAssertNil(MeetingPlatform.platform(id: "teams"))
    }

    func testIdentifiersAreStoredLowercasedSoMatchingWorks() {
        // `owns` lowercases its input, not the table — a capital letter in the
        // table would make a platform silently undetectable.
        for platform in MeetingPlatform.all {
            // Helper process names belong here too: the real one is spelled
            // `CptHost`, and a table holding it that way would only match on a
            // system where the kernel agreed about capitals.
            for value in platform.bundleIDs + platform.windowOwners
                + platform.meetingTitleMarkers + platform.callHelperProcesses {
                XCTAssertEqual(value, value.lowercased(), "\(platform.id): \(value)")
            }
        }
    }

    /// The name Zoom actually spawns for a call. Confirmed on a live meeting
    /// 2026-07-29: `CptHost` appeared the second the call was joined, while
    /// `caphost` — one letter apart and idle-safe — had been running for hours.
    func testZoomCallHelperIsTheProcessThatAppearsWithTheCall() {
        XCTAssertTrue(MeetingPlatform.zoom.callHelperProcesses.contains("cpthost"))
        XCTAssertFalse(MeetingPlatform.zoom.callHelperProcesses.contains("caphost"))
    }

    // MARK: - Debounce

    func testACallIsOnlyStartedAfterTwoConsecutiveSightings() {
        var debounce = MeetingDebounce()
        let seen = MeetingSnapshot(platformID: "zoom", appRunning: true, signals: ["helper"])
        XCTAssertEqual(debounce.observe(seen), .none, "one frame could be a flicker")
        XCTAssertEqual(debounce.observe(seen), .started(platformID: "zoom"))
        XCTAssertEqual(debounce.observe(seen), .none, "already started — no repeat")
    }

    /// A momentary blind spot mid-call (window hidden, helper restarting) must
    /// not stop the recording.
    func testASingleMissedFrameDoesNotEndACall() {
        var debounce = MeetingDebounce()
        let seen = MeetingSnapshot(platformID: "zoom", appRunning: true, signals: [])
        _ = debounce.observe(seen)
        _ = debounce.observe(seen)
        XCTAssertEqual(debounce.observe(.idle), .none)
        XCTAssertEqual(debounce.observe(.idle), .none)
        XCTAssertEqual(debounce.observe(.idle), .ended, "three in a row does end it")
        XCTAssertFalse(debounce.isInMeeting)
    }

    func testQuittingTheAppEndsTheCallImmediately() {
        var debounce = MeetingDebounce()
        let seen = MeetingSnapshot(platformID: "kontur-talk", appRunning: true, signals: [])
        _ = debounce.observe(seen)
        _ = debounce.observe(seen)
        XCTAssertEqual(debounce.reset(), .ended)
        XCTAssertEqual(debounce.reset(), .none, "already ended")
    }

    func testStartReportsWhichPlatformSoTheRecordingCanBeLabelled() {
        var debounce = MeetingDebounce()
        let talk = MeetingSnapshot(platformID: "kontur-talk", appRunning: true, signals: ["window"])
        _ = debounce.observe(talk)
        XCTAssertEqual(debounce.observe(talk), .started(platformID: "kontur-talk"))
    }
}

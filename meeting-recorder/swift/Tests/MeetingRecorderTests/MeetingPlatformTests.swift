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

    // MARK: - VK Звонки

    /// Снято 2026-08-11 на живом звонке с выключенными камерой и микрофоном:
    /// ассерт был. Значит он про звонок, а не про видео, и автозапись не
    /// проспит разговор голосом.
    func testVKTrustsTheAssertionBecauseItIsHeldForTheCallNotTheCamera() {
        XCTAssertTrue(MeetingPlatform.vkCalls.sleepAssertionMeansCall)
        XCTAssertTrue(MeetingPlatform.vkCalls.assertionNameMeansCall("VK video call in progress"))
    }

    /// Имя — это и есть сигнал. «Приложение держит экран не спящим» само по
    /// себе звонком не считается: у Толка ровно это и оказалось демонстрацией
    /// экрана, и запись включалась не на встречу.
    func testVKIgnoresAnyOtherAssertionTheAppMightHold() {
        let vk = MeetingPlatform.vkCalls
        XCTAssertFalse(vk.assertionNameMeansCall("VK Calls"))
        XCTAssertFalse(vk.assertionNameMeansCall("Playing media"))
        XCTAssertFalse(vk.assertionNameMeansCall(nil), "имени нет — доказательства нет")
    }

    /// Zoom маркеров не имеет, и это поведение, которое уже отгружено: любой
    /// его display-sleep ассерт считается звонком с шестой фазы.
    func testZoomStillCountsAnyAssertionItHolds() {
        XCTAssertTrue(MeetingPlatform.zoom.sleepAssertionNameMarkers.isEmpty)
        XCTAssertTrue(MeetingPlatform.zoom.assertionNameMeansCall("zoom.us"))
        XCTAssertTrue(MeetingPlatform.zoom.assertionNameMeansCall(nil))
    }

    func testVKIsIdentifiedByBundleIDAndByBothOfItsNames() {
        let vk = MeetingPlatform.vkCalls
        XCTAssertTrue(vk.owns(bundleID: "com.vk.calls.native.1", appName: nil))
        XCTAssertTrue(vk.owns(bundleID: nil, appName: "VK Звонки"))
        XCTAssertTrue(vk.owns(bundleID: nil, appName: "VK Calls"))
        XCTAssertTrue(vk.ownsProcess(named: "VK Calls"))
    }

    /// `com.vk.calls.native.1` кончается цифрой, и правило «последний компонент
    /// bundle id — это имя процесса» без защиты отдало бы VK любой процесс с
    /// единицей в имени. Держащий display-sleep `python3.11` начинал бы звонок.
    func testANumericBundleSuffixNeverAttributesAForeignProcess() {
        let vk = MeetingPlatform.vkCalls
        XCTAssertFalse(vk.ownsProcess(named: "python3.11"))
        XCTAssertFalse(vk.ownsProcess(named: "WindowServer"))
        XCTAssertFalse(vk.ownsProcess(named: "Толк Helper"))
    }

    /// У VK нет процесса, который появляется только на звонке: и `VK Calls`, и
    /// `crashpad_handler` подняты с запуска приложения (замерено 2026-08-11).
    /// Вписать сюда обычный процесс — значит начинать запись на открытие окна.
    func testVKHasNoCallOnlyHelperProcess() {
        XCTAssertTrue(MeetingPlatform.vkCalls.callHelperProcesses.isEmpty)
    }

    /// Ни одного заголовка окна VK никто не видел — без «Записи экрана» они
    /// пустые. Пустой список маркеров это и означает; правдоподобные слова в
    /// таблице были бы непроверенным правилом, включающим запись.
    func testVKHasNoTitleRuleSoNoTitleCanStartARecording() {
        for title in ["Звонок", "VK Звонки", "Настройки", ""] {
            XCTAssertFalse(MeetingPlatform.vkCalls.titleMeansCall(title), title)
        }
    }

    // MARK: - Чей ассерт считается звонком

    /// Замерено 2026-08-11: у человека постоянно открыт простаивающий Zoom, и
    /// живой звонок VK не был опознан за все 76 секунд — детектор считал
    /// запущенные приложения, а не держателей ассерта.
    func testAnIdleSecondAppNoLongerHidesACall() {
        let id = MeetingPlatform.callFromAssertion(
            live: [.zoom, .vkCalls],
            holdingAssertion: ["vk-calls"]
        )
        XCTAssertEqual(id, "vk-calls")
    }

    /// Запись одна: выбрать из двух держателей значит угадать, в какой встрече
    /// человек.
    func testTwoAppsHoldingAnAssertionAreNobodysCall() {
        XCTAssertNil(MeetingPlatform.callFromAssertion(
            live: [.zoom, .vkCalls],
            holdingAssertion: ["zoom", "vk-calls"]
        ))
    }

    /// Толк ассерту не верит, и держателем его делать нельзя — это и был баг
    /// 1.15: запись включалась на старте чужой демонстрации экрана.
    func testAPlatformThatDistrustsTheAssertionIsNeverTheCall() {
        XCTAssertNil(MeetingPlatform.callFromAssertion(
            live: [.konturTalk],
            holdingAssertion: ["kontur-talk"]
        ))
        // И не мешает опознать того, кто ему верит.
        XCTAssertEqual(
            MeetingPlatform.callFromAssertion(
                live: [.konturTalk, .zoom],
                holdingAssertion: ["kontur-talk", "zoom"]
            ),
            "zoom"
        )
    }

    func testNobodyHoldingAnAssertionIsNoCall() {
        XCTAssertNil(MeetingPlatform.callFromAssertion(live: MeetingPlatform.all, holdingAssertion: []))
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
                + platform.meetingTitleMarkers + platform.callHelperProcesses
                + platform.sleepAssertionNameMarkers {
                XCTAssertEqual(value, value.lowercased(), "\(platform.id): \(value)")
            }
        }
    }

    /// Маркеры имени сужают ассерт, а не включают его: платформа, которая
    /// ассерту не верит, с непустым списком читалась бы как «сигнал настроен»,
    /// хотя детектор до имени вообще не доходит.
    func testAssertionNameMarkersOnlyExistWhereTheAssertionIsTrusted() {
        for platform in MeetingPlatform.all where !platform.sleepAssertionNameMarkers.isEmpty {
            XCTAssertTrue(platform.sleepAssertionMeansCall, platform.id)
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

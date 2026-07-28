import XCTest
import PropellerPure

/// The catalogue is the redesign reference and the gallery's index. Its whole
/// value is being *complete*, so completeness is what these check.
final class UIStateCatalogTests: XCTestCase {

    /// Add a stage without giving it a screen and this goes red — rather than
    /// the gap surfacing halfway through a redesign.
    func testEveryStageIsEitherShownOrDeclaredUnreachable() {
        let shown = Set(UIStateCatalog.meetingStates.map(\.stage))
        let excused = UIStateCatalog.stagesWithoutOwnScreen
        for stage in RecordingStage.allCases {
            XCTAssertTrue(shown.contains(stage) || excused.contains(stage),
                          "\(stage) has no screen and isn't declared unreachable")
        }
        // The excuse list must stay honest too: nothing may be both.
        XCTAssertTrue(shown.isDisjoint(with: excused))
    }

    /// Each phase has a progress screen — those are the ones people stare at.
    func testEveryPhaseHasAProgressScreen() {
        let working: Set<PipelineActivity.Phase> = Set(
            UIStateCatalog.meetingStates.compactMap {
                if case .working(let phase) = $0.involvement { return phase }
                return nil
            }
        )
        XCTAssertEqual(working, Set(PipelineActivity.Phase.allCases))
    }

    /// §5 of REFACTOR-PIPELINE-STATE.md enumerates eleven legal states. The
    /// count is asserted so the two cannot drift apart silently.
    func testMatchesTheElevenLegalStates() {
        XCTAssertEqual(UIStateCatalog.meetingStates.count, 11)
    }

    /// The two orthogonal cases from §5: someone else's work, and a failure.
    func testCoversWorkOnAnotherMeetingAndFailure() {
        XCTAssertTrue(UIStateCatalog.meetingStates.contains {
            if case .elsewhere = $0.involvement { return true }
            return false
        })
        XCTAssertTrue(UIStateCatalog.meetingStates.contains(where: \.hasFailure))
    }

    /// IDs become screenshot filenames and Figma frame names — a duplicate would
    /// silently overwrite another state's frame.
    func testScreenIDsAreUniqueAndFilenameSafe() {
        let ids = UIStateCatalog.allScreenIDs
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate screen id")
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        for id in ids {
            XCTAssertTrue(id.unicodeScalars.allSatisfy(allowed.contains),
                          "id \(id) is not filename-safe")
        }
    }
}

import XCTest
@testable import PropellerPure

/// Named after what the user sees on ⌥Tab, not after the functions.
final class MeetingSwitchTests: XCTestCase {

    private let three = ["a", "b", "c"]

    func testTheWalkStartsOnTheMeetingThatIsOpen() throws {
        let walk = try XCTUnwrap(MeetingSwitch(order: three, startingAt: "b"))
        XCTAssertEqual(walk.currentID, "b")
    }

    func testAMeetingThatLeftTheListWalksFromTheTop() throws {
        let walk = try XCTUnwrap(MeetingSwitch(order: three, startingAt: "deleted"))
        XCTAssertEqual(walk.currentID, "a")
    }

    func testNothingToWalkThroughMeansNoPanel() {
        XCTAssertNil(MeetingSwitch(order: [], startingAt: nil))
    }

    func testTabWalksDownTheListAndWrapsAtTheBottom() throws {
        var walk = try XCTUnwrap(MeetingSwitch(order: three, startingAt: "a"))
        walk = walk.stepped(by: 1)
        XCTAssertEqual(walk.currentID, "b")
        walk = walk.stepped(by: 1)
        XCTAssertEqual(walk.currentID, "c")
        walk = walk.stepped(by: 1)
        XCTAssertEqual(walk.currentID, "a")
    }

    func testShiftTabWalksUpAndWrapsAtTheTop() throws {
        var walk = try XCTUnwrap(MeetingSwitch(order: three, startingAt: "a"))
        walk = walk.stepped(by: -1)
        XCTAssertEqual(walk.currentID, "c")
        walk = walk.stepped(by: -1)
        XCTAssertEqual(walk.currentID, "b")
    }

    /// The whole point of the panel: you can see what you are walking away from.
    func testTheMeetingAboveTheCurrentOneIsAtTheTop() throws {
        let walk = try XCTUnwrap(MeetingSwitch(order: three, startingAt: "b"))
        XCTAssertEqual(walk.anchorID, "a")
    }

    func testAtTheHeadOfTheListTheCurrentMeetingIsTheTopRow() throws {
        let walk = try XCTUnwrap(MeetingSwitch(order: three, startingAt: "a"))
        XCTAssertEqual(walk.anchorID, "a")
    }

    /// Wrapping round to the last meeting must still show a neighbour above it,
    /// or the panel jumps from «one row above» to «none» on the last step.
    func testWrappingToTheEndKeepsTheNeighbourAbove() throws {
        let walk = try XCTUnwrap(MeetingSwitch(order: three, startingAt: "a")).stepped(by: -1)
        XCTAssertEqual(walk.currentID, "c")
        XCTAssertEqual(walk.anchorID, "b")
    }

    func testOneMeetingHasNowhereToWalk() throws {
        let walk = try XCTUnwrap(MeetingSwitch(order: ["only"], startingAt: "only"))
        XCTAssertFalse(walk.canWalk)
        XCTAssertEqual(walk.stepped(by: 1).currentID, "only")
        XCTAssertEqual(walk.stepped(by: -1).currentID, "only")
        XCTAssertEqual(walk.anchorID, "only")
    }

    func testTwoMeetingsWalkBackAndForthBetweenThemselves() throws {
        var walk = try XCTUnwrap(MeetingSwitch(order: ["a", "b"], startingAt: "a"))
        XCTAssertTrue(walk.canWalk)
        walk = walk.stepped(by: 1)
        XCTAssertEqual(walk.currentID, "b")
        XCTAssertEqual(walk.anchorID, "a")
        walk = walk.stepped(by: 1)
        XCTAssertEqual(walk.currentID, "a")
    }
}

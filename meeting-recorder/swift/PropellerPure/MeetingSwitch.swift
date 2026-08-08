import Foundation

/// # Walking between meetings on ⌥Tab
///
/// The rule is the one every switcher on the machine has already taught: hold a
/// modifier, tap to walk, let go to land. Walking costs nothing — no meeting is
/// opened until the modifier comes up — which is what makes it safe to run past
/// twenty meetings to reach the twenty-first. Opening each one on the way would
/// stop the player, read the disk and push a history entry twenty times over.
///
/// Two things are decided here and nowhere else: where a step lands, and which
/// row the panel has to put at the top so the walk is legible.
public struct MeetingSwitch: Equatable, Sendable {

    /// The rail's order, flattened — newest first, exactly the sequence the eye
    /// reads down the list. The switcher is another view of the rail, so it must
    /// not invent an order of its own.
    public let order: [String]

    /// How far the walk has got. Always a valid index into `order`.
    public let index: Int

    /// Nil when there is nothing to walk through. Zero meetings is not a state
    /// the app allows, but a switcher that force-unwraps its way to a crash if it
    /// ever happens is a worse answer than one that simply doesn't appear.
    public init?(order: [String], startingAt id: String?) {
        guard !order.isEmpty else { return nil }
        self.order = order
        // An id that has left the list (deleted while the panel was up) walks
        // from the top rather than nowhere.
        self.index = id.flatMap { order.firstIndex(of: $0) } ?? 0
    }

    private init(order: [String], index: Int) {
        self.order = order
        self.index = index
    }

    public var currentID: String { order[index] }

    /// The row that has to sit at the top of the panel, so the current one is the
    /// **second** — one meeting above it, the rest of the list below.
    ///
    /// At the head of the list there is nothing above, so the current one is
    /// first: the panel cannot show a meeting that isn't there, and holding an
    /// empty row open for it would put a gap exactly where the eye goes looking
    /// for the neighbour.
    public var anchorID: String { order[max(0, index - 1)] }

    /// One step, wrapping at both ends — the walk never dead-ends, the same way
    /// ⌘Tab doesn't.
    public func stepped(by delta: Int) -> MeetingSwitch {
        let count = order.count
        var next = (index + delta) % count
        if next < 0 { next += count }
        return MeetingSwitch(order: order, index: next)
    }

    /// Whether a step can go anywhere. One meeting is a real archive and the
    /// panel still shows it — it just has nowhere to walk to.
    public var canWalk: Bool { order.count > 1 }
}

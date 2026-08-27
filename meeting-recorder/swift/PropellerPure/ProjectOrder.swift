import Foundation

/// How the project grid is sorted. The mockup's menu shows «Сначала актуальные»
/// selected and does not open, so the second option is a proposal, not a
/// measurement: alphabetical, because that is the one order a person can
/// predict when they are looking for a project by name rather than by life.
public enum ProjectOrder: String, CaseIterable, Equatable, Sendable {
    /// Last meeting first; a project with no meetings falls back to when it was
    /// made, so a brand-new project appears at the top instead of the bottom.
    case recent
    case alphabetical

    public var title: String {
        switch self {
        case .recent:       return "Сначала актуальные"
        case .alphabetical: return "По алфавиту"
        }
    }

    public static let entry: ProjectOrder = .recent
}

/// A project as the grid sees it: the entity plus the two facts that come from
/// the meetings around it.
///
/// Counted outside, not here, because counting means walking the index and this
/// file is the part a test can hold still.
public struct ProjectSummary: Equatable, Identifiable, Sendable {
    public let project: Project
    public let meetings: Int
    public let last: Date?

    public var id: String { project.id }

    public init(project: Project, meetings: Int, last: Date?) {
        self.project = project
        self.meetings = meetings
        self.last = last
    }
}

public extension Array where Element == ProjectSummary {
    /// Archived projects are not here at all: they leave the field of view but
    /// not the data (`plan-projects.md` §8). Filtering happens before sorting so
    /// the caller cannot forget it and get an archived project in the grid.
    func ordered(by order: ProjectOrder) -> [ProjectSummary] {
        let live = filter { !$0.project.archived }
        switch order {
        case .recent:
            return live.sorted {
                let a = $0.last ?? $0.project.createdAt
                let b = $1.last ?? $1.project.createdAt
                if a != b { return a > b }
                // Two projects made in the same instant is a fixture, not a
                // person — but a sort that flips between redraws is a bug, so
                // the name breaks the tie.
                return $0.project.name.localizedCaseInsensitiveCompare($1.project.name) == .orderedAscending
            }
        case .alphabetical:
            return live.sorted {
                $0.project.name.localizedCaseInsensitiveCompare($1.project.name) == .orderedAscending
            }
        }
    }
}

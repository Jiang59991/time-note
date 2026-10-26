import Foundation

public enum CategoryAssignmentSource: String, Codable, Sendable {
    case manual, learned, rule, unclassified
}

/// A manual lock must be respected by classification adapters, including late results.
public struct CategoryAssignment: Codable, Equatable, Sendable {
    public let categoryID: UUID?
    public let source: CategoryAssignmentSource
    public let manualLock: Bool

    public init(categoryID: UUID?, source: CategoryAssignmentSource, manualLock: Bool) {
        self.categoryID = categoryID
        self.source = source
        self.manualLock = manualLock
    }

    public static let unclassified = CategoryAssignment(
        categoryID: nil, source: .unclassified, manualLock: false
    )
}

public enum EntrySource: String, Codable, Sendable {
    case manual, timer, voice, imported
}

/// Immutable data snapshot. Command implementations must validate drafts before persistence.
public struct TimeEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let categoryAssignment: CategoryAssignment
    public let startAt: Date
    public let endAt: Date?
    public let source: EntrySource
    public let timezoneID: String
    public let revision: Int64

    public init(
        id: UUID,
        title: String,
        categoryAssignment: CategoryAssignment,
        startAt: Date,
        endAt: Date?,
        source: EntrySource,
        timezoneID: String,
        revision: Int64
    ) {
        self.id = id
        self.title = title
        self.categoryAssignment = categoryAssignment
        self.startAt = startAt
        self.endAt = endAt
        self.source = source
        self.timezoneID = timezoneID
        self.revision = revision
    }
}

public enum TimerMode: Codable, Equatable, Sendable {
    case stopwatch
    case pomodoro(targetSeconds: TimeInterval)
}

public enum TimerRunState: String, Codable, Sendable {
    case running, finished, cancelled
}

/// One run references exactly one entry. Starting another round creates new IDs.
/// The persistence adapter must enforce one run per entry and atomic state changes.
public struct TimerRun: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let entryID: UUID
    public let mode: TimerMode
    public let state: TimerRunState
    public let deadline: Date?
    public let scheduleVersion: Int64

    public init(
        id: UUID,
        entryID: UUID,
        mode: TimerMode,
        state: TimerRunState,
        deadline: Date?,
        scheduleVersion: Int64
    ) {
        self.id = id
        self.entryID = entryID
        self.mode = mode
        self.state = state
        self.deadline = deadline
        self.scheduleVersion = scheduleVersion
    }
}

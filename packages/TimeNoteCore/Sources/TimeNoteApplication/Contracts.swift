import Foundation
import TimeNoteDomain

/// UI-owned editable value, never a live persistence model binding.
public struct EntryDraft: Codable, Equatable, Sendable {
    public var title: String
    public var categoryAssignment: CategoryAssignment
    public var startAt: Date
    public var endAt: Date?
    public var timezoneID: String

    public init(
        title: String, categoryAssignment: CategoryAssignment,
        startAt: Date, endAt: Date?, timezoneID: String
    ) {
        self.title = title
        self.categoryAssignment = categoryAssignment
        self.startAt = startAt
        self.endAt = endAt
        self.timezoneID = timezoneID
    }

    public init(entry: TimeEntry) {
        self.init(
            title: entry.title, categoryAssignment: entry.categoryAssignment,
            startAt: entry.startAt, endAt: entry.endAt, timezoneID: entry.timezoneID
        )
    }
}

/// Requires draft.endAt == nil. Another round is a new command and new run/entry IDs.
public struct StartCommand: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let draft: EntryDraft
    public let mode: TimerMode
    public let source: EntrySource

    public init(operationID: UUID, draft: EntryDraft, mode: TimerMode, source: EntrySource) {
        self.operationID = operationID
        self.draft = draft
        self.mode = mode
        self.source = source
    }
}

/// Requires a valid, nonfuture draft.endAt > draft.startAt. No TimerRun is created.
public struct ManualRecordCommand: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let draft: EntryDraft
    public let source: EntrySource

    public init(operationID: UUID, draft: EntryDraft, source: EntrySource) {
        self.operationID = operationID
        self.draft = draft
        self.source = source
    }
}

public enum FinishTrigger: Codable, Equatable, Sendable {
    case manual(endAt: Date, expectedEntryRevision: Int64)
    /// A stale notification version must not finish a rescheduled run.
    /// Read the latest entry inside the transaction; metadata edits do not invalidate expiry.
    case pomodoroDeadline(expectedScheduleVersion: Int64)
}

/// Targets one run only. Timer and entry changes must commit together.
public struct FinishCommand: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let runID: UUID
    public let trigger: FinishTrigger

    public init(
        operationID: UUID, runID: UUID, trigger: FinishTrigger
    ) {
        self.operationID = operationID
        self.runID = runID
        self.trigger = trigger
    }
}

public enum EditCompletionIntent: String, Codable, Sendable {
    case preserveCurrentState
    case finishAtDraftEnd
    case finishAtRecomputedDeadline
}

/// A stale revision must yield a conflict, never silently overwrite a newer record.
public struct EditEntryCommand: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let entryID: UUID
    public let expectedRevision: Int64
    public let draft: EntryDraft
    public let completionIntent: EditCompletionIntent

    public init(
        operationID: UUID, entryID: UUID, expectedRevision: Int64,
        draft: EntryDraft, completionIntent: EditCompletionIntent
    ) {
        self.operationID = operationID
        self.entryID = entryID
        self.expectedRevision = expectedRevision
        self.draft = draft
        self.completionIntent = completionIntent
    }
}

/// Reconciles persisted runs at a supplied time without inventing skipped rounds.
public struct ReconcileCommand: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let asOf: Date

    public init(operationID: UUID, asOf: Date) {
        self.operationID = operationID
        self.asOf = asOf
    }
}

public struct EntryMutationResult: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let entry: TimeEntry
    public let run: TimerRun?

    public init(operationID: UUID, entry: TimeEntry, run: TimerRun?) {
        self.operationID = operationID
        self.entry = entry
        self.run = run
    }
}

public struct ReconcileResult: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let finishedRuns: [TimerRun]
    public let updatedEntries: [TimeEntry]
    public let reconciledAt: Date

    public init(
        operationID: UUID, finishedRuns: [TimerRun],
        updatedEntries: [TimeEntry], reconciledAt: Date
    ) {
        self.operationID = operationID
        self.finishedRuns = finishedRuns
        self.updatedEntries = updatedEntries
        self.reconciledAt = reconciledAt
    }
}

public struct SnapshotQuery: Codable, Equatable, Sendable {
    public let window: DateInterval?
    public let asOf: Date

    public init(window: DateInterval?, asOf: Date) {
        self.window = window
        self.asOf = asOf
    }
}

/// A coherent read of entries and runs, not independently fetched collections.
public struct TimeNoteSnapshot: Codable, Equatable, Sendable {
    public let entries: [TimeEntry]
    public let runs: [TimerRun]
    public let generatedAt: Date

    public init(entries: [TimeEntry], runs: [TimerRun], generatedAt: Date) {
        self.entries = entries
        self.runs = runs
        self.generatedAt = generatedAt
    }
}

public enum TimeNoteApplicationError: Error, Equatable, Sendable {
    case entryNotFound(UUID)
    case runNotFound(UUID)
    case invalidDraft(reason: String)
    case revisionConflict(entryID: UUID, expected: Int64, actual: Int64)
    case explicitFinishRequired(deadline: Date)
    case staleSchedule(runID: UUID)
    case operationConflict(operationID: UUID)
    case storageUnavailable(reason: String)
}

/// Contract only: this package intentionally provides no in-memory or fake store implementation.
///
/// Implementations must persist operationID deduplication, validate and commit entry/run changes
/// atomically, and schedule notifications only after successful commit. Retrying the same command
/// returns the committed result; reusing its operationID for different content is an error.
/// Reconciliation ends expired pomodoros at their own deadlines and leaves stopwatches running.
/// Deadline completion checks scheduleVersion, reads the latest entry, and preserves current
/// metadata; it must not reject expiry just because a title edit changed the entry revision.
/// Automatic completion cannot be undone into a running run. A manual-finish undo (future API)
/// must not revive a pomodoro after its original deadline.
public protocol TimeNoteCommandHandling: Sendable {
    func start(_ command: StartCommand) async throws -> EntryMutationResult
    func manualRecord(_ command: ManualRecordCommand) async throws -> EntryMutationResult
    func finish(_ command: FinishCommand) async throws -> EntryMutationResult
    func edit(_ command: EditEntryCommand) async throws -> EntryMutationResult
    func reconcile(_ command: ReconcileCommand) async throws -> ReconcileResult
}

public protocol TimeNoteSnapshotReading: Sendable {
    /// Includes matching historical entries plus every running run and its entry, even if that
    /// entry lies outside the requested history window, so the global running list stays complete.
    func snapshot(_ query: SnapshotQuery) async throws -> TimeNoteSnapshot
}

import Foundation
import Testing
import TimeNoteDomain
import TimeNoteApplication

struct TimeNoteCoreTests {
    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func run(
        mode: TimerMode, state: TimerRunState = .running, deadline: Date? = nil
    ) -> TimerRun {
        TimerRun(
            id: UUID(), entryID: UUID(), mode: mode, state: state,
            deadline: deadline, scheduleVersion: 1
        )
    }

    @Test func testTwoOverlappingTasksHaveDistinctCumulativeCoverageAndConcurrency() throws {
        let start = date("2026-10-23T14:00:00Z")
        let result = try IntervalAnalytics.summarize(
            intervals: [
                .init(start: start, end: start.addingTimeInterval(3_600)),
                .init(start: start.addingTimeInterval(1_800), end: start.addingTimeInterval(5_400))
            ],
            window: .init(start: start, duration: 14_400),
            asOf: start.addingTimeInterval(14_400)
        )
        #expect(result.cumulativeSeconds == 7_200)
        #expect(result.coveredSeconds == 5_400)
        #expect(result.concurrentSeconds == 1_800)
        #expect(result.unrecordedSeconds == 9_000)
        #expect(result.peakConcurrency == 2)
    }

    @Test func testTripleOverlapIsNotCumulativeMinusCoverage() throws {
        let start = date("2026-10-23T14:00:00Z")
        let interval = ActivityInterval(start: start, end: start.addingTimeInterval(3_600))
        let result = try IntervalAnalytics.summarize(
            intervals: [interval, interval, interval],
            window: .init(start: start, duration: 3_600),
            asOf: start.addingTimeInterval(3_600)
        )
        #expect(result.cumulativeSeconds == 10_800)
        #expect(result.coveredSeconds == 3_600)
        #expect(result.concurrentSeconds == 3_600)
        #expect(result.concurrentSeconds != result.cumulativeSeconds - result.coveredSeconds)
        #expect(result.peakConcurrency == 3)
    }

    @Test func testAdjacentHalfOpenIntervalsDoNotOverlap() throws {
        let start = date("2026-10-23T14:00:00Z")
        let middle = start.addingTimeInterval(3_600)
        let end = start.addingTimeInterval(7_200)
        let result = try IntervalAnalytics.summarize(
            intervals: [.init(start: start, end: middle), .init(start: middle, end: end)],
            window: .init(start: start, end: end), asOf: end
        )
        #expect(result.coveredSeconds == 7_200)
        #expect(result.concurrentSeconds == 0)
        #expect(result.unrecordedSeconds == 0)
        #expect(result.peakConcurrency == 1)
    }

    @Test func testCrossMidnightEntryIsClippedWithoutDuplicatingIt() throws {
        let midnight = date("2026-10-24T00:00:00+08:00")
        let entry = ActivityInterval(
            start: date("2026-10-23T23:00:00+08:00"),
            end: date("2026-10-24T02:00:00+08:00")
        )
        let result = try IntervalAnalytics.summarize(
            intervals: [entry], window: .init(start: midnight, duration: 86_400),
            asOf: date("2026-10-24T12:00:00+08:00")
        )
        #expect(result.cumulativeSeconds == 7_200)
        #expect(result.coveredSeconds == 7_200)
        #expect(result.unrecordedSeconds == 36_000)
        #expect(entry.start == date("2026-10-23T23:00:00+08:00"))
    }

    @Test func testAsOfClipsOpenClosedAndFutureIntervals() throws {
        let midnight = date("2026-10-23T00:00:00Z")
        let result = try IntervalAnalytics.summarize(
            intervals: [
                .init(start: midnight.addingTimeInterval(9 * 3_600), end: nil),
                .init(start: midnight.addingTimeInterval(9.5 * 3_600), end: midnight.addingTimeInterval(12 * 3_600)),
                .init(start: midnight.addingTimeInterval(11 * 3_600), end: midnight.addingTimeInterval(12 * 3_600))
            ],
            window: .init(start: midnight, duration: 86_400),
            asOf: midnight.addingTimeInterval(10 * 3_600)
        )
        #expect(result.elapsedSeconds == 36_000)
        #expect(result.cumulativeSeconds == 5_400)
        #expect(result.coveredSeconds == 3_600)
        #expect(result.concurrentSeconds == 1_800)
        #expect(result.unrecordedSeconds == 32_400)
        #expect(result.peakConcurrency == 2)
    }

    @Test func testEmptyAndEntirelyFutureWindowsDoNotCountFutureAsUnrecorded() throws {
        let start = date("2026-10-23T14:00:00Z")
        let future = try IntervalAnalytics.summarize(
            intervals: [], window: .init(start: start, duration: 3_600),
            asOf: start.addingTimeInterval(-1)
        )
        #expect(future.elapsedSeconds == 0)
        #expect(future.unrecordedSeconds == 0)
        #expect(future.peakConcurrency == 0)
        let elapsed = try IntervalAnalytics.summarize(
            intervals: [], window: .init(start: start, duration: 3_600),
            asOf: start.addingTimeInterval(900)
        )
        #expect(elapsed.unrecordedSeconds == 900)
    }

    @Test func testCalendarDayBoundariesRespectSpringAndFallDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        for (month, day, expectedHours) in [(3, 8, 23), (11, 1, 25)] {
            let noon = try #require(calendar.date(from: DateComponents(
                year: 2026, month: month, day: day, hour: 12
            )))
            let window = try #require(calendar.dateInterval(of: .day, for: noon))
            let result = try IntervalAnalytics.summarize(
                intervals: [.init(start: window.start, end: window.end)],
                window: window, asOf: window.end
            )
            #expect(window.duration == Double(expectedHours * 3_600))
            #expect(result.coveredSeconds == window.duration)
            #expect(result.unrecordedSeconds == 0)
        }
    }

    @Test func testIndependentPomodorosHaveIndependentDeadlinesAndStopwatchHasNone() throws {
        let start = date("2026-10-23T14:00:00Z")
        #expect(try TimerPolicy.deadline(mode: .pomodoro(targetSeconds: 1_500), startAt: start) == start.addingTimeInterval(1_500))
        #expect(try TimerPolicy.deadline(mode: .pomodoro(targetSeconds: 3_000), startAt: start.addingTimeInterval(300)) == start.addingTimeInterval(3_300))
        #expect(try TimerPolicy.deadline(mode: .stopwatch, startAt: start) == nil)
    }

    @Test func testActivePomodoroStartEditPreviewsContinuationOrExplicitFinish() throws {
        let now = date("2026-10-23T14:30:00Z")
        let pomodoro = run(mode: .pomodoro(targetSeconds: 1_500), deadline: now.addingTimeInterval(900))
        let recentStart = now.addingTimeInterval(-600)
        #expect(try TimerPolicy.activeStartEditOutcome(run: pomodoro, newStartAt: recentStart, asOf: now) == .continueRunning(newStartAt: recentStart, newDeadline: recentStart.addingTimeInterval(1_500)))
        let oldStart = now.addingTimeInterval(-1_800)
        #expect(try TimerPolicy.activeStartEditOutcome(run: pomodoro, newStartAt: oldStart, asOf: now) == .requiresExplicitFinish(newStartAt: oldStart, finishAt: oldStart.addingTimeInterval(1_500)))
        let boundary = now.addingTimeInterval(-1_500)
        #expect(try TimerPolicy.activeStartEditOutcome(run: pomodoro, newStartAt: boundary, asOf: now) == .requiresExplicitFinish(newStartAt: boundary, finishAt: now))
        #expect(pomodoro.state == .running, "A policy preview must not mutate its run")
        let earlier = now.addingTimeInterval(-3_600)
        #expect(try TimerPolicy.activeStartEditOutcome(run: run(mode: .stopwatch), newStartAt: earlier, asOf: now) == .continueRunning(newStartAt: earlier, newDeadline: nil))
    }

    @Test func testElapsedOriginalDeadlineCannotBeExtendedByMovingStartForward() throws {
        let now = date("2026-10-23T14:30:00Z")
        let recentStart = now.addingTimeInterval(-60)
        for originalDeadline in [now.addingTimeInterval(-300), now] {
            let expired = run(mode: .pomodoro(targetSeconds: 1_500), deadline: originalDeadline)
            #expect(throws: TimerPolicyError.originalDeadlineElapsed(deadline: originalDeadline)) {
                try TimerPolicy.activeStartEditOutcome(run: expired, newStartAt: recentStart, asOf: now)
            }
        }
    }

    @Test func testPoliciesRejectReversedIntervalsInvalidDurationsFutureStartsAndFinishedRuns() throws {
        let now = date("2026-10-23T14:30:00Z")
        #expect(throws: IntervalAnalyticsError.invalidInterval(index: 0)) {
            try IntervalAnalytics.summarize(
                intervals: [.init(start: now, end: now.addingTimeInterval(-1))],
                window: .init(start: now, duration: 3_600), asOf: now
            )
        }
        for duration in [0.0, -1, .infinity, .nan] {
            #expect(throws: TimerPolicyError.invalidTargetDuration) {
                try TimerPolicy.deadline(mode: .pomodoro(targetSeconds: duration), startAt: now)
            }
        }
        #expect(throws: TimerPolicyError.futureStart) {
            try TimerPolicy.activeStartEditOutcome(
                run: run(mode: .stopwatch), newStartAt: now.addingTimeInterval(1), asOf: now
            )
        }
        #expect(throws: TimerPolicyError.runNotRunning) {
            try TimerPolicy.activeStartEditOutcome(
                run: run(mode: .stopwatch, state: .finished), newStartAt: now, asOf: now
            )
        }
    }

    @Test func testCodableSnapshotsAndEditDraftPreserveIdentityRevisionAndManualLock() throws {
        let entry = TimeEntry(
            id: UUID(), title: "写论文",
            categoryAssignment: .init(categoryID: UUID(), source: .manual, manualLock: true),
            startAt: date("2026-10-23T14:00:00Z"), endAt: nil,
            source: .timer, timezoneID: "Asia/Shanghai", revision: 7
        )
        let timer = TimerRun(
            id: UUID(), entryID: entry.id, mode: .pomodoro(targetSeconds: 1_500),
            state: .running, deadline: entry.startAt.addingTimeInterval(1_500), scheduleVersion: 2
        )
        let snapshot = TimeNoteSnapshot(entries: [entry], runs: [timer], generatedAt: entry.startAt)
        let decoded = try JSONDecoder().decode(TimeNoteSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded == snapshot)
        var draft = EntryDraft(entry: entry)
        draft.title = "修改后的标题"
        let command = EditEntryCommand(
            operationID: UUID(), entryID: entry.id, expectedRevision: entry.revision,
            draft: draft, completionIntent: .preserveCurrentState
        )
        let decodedCommand = try JSONDecoder().decode(
            EditEntryCommand.self, from: JSONEncoder().encode(command)
        )
        #expect(decodedCommand == command)
        #expect(entry.title == "写论文", "Editing a draft cannot mutate a read snapshot")
        #expect(command.draft.categoryAssignment.manualLock)
        #expect(command.expectedRevision == 7)
        let deadlineCommand = FinishCommand(
            operationID: UUID(), runID: timer.id,
            trigger: .pomodoroDeadline(expectedScheduleVersion: timer.scheduleVersion)
        )
        let manualCommand = FinishCommand(
            operationID: UUID(), runID: timer.id,
            trigger: .manual(endAt: entry.startAt.addingTimeInterval(600), expectedEntryRevision: entry.revision)
        )
        for finishCommand in [deadlineCommand, manualCommand] {
            #expect(try JSONDecoder().decode(FinishCommand.self, from: JSONEncoder().encode(finishCommand)) == finishCommand)
        }
    }
}

import Foundation

public enum TimerPolicyError: Error, Equatable, Sendable {
    case invalidDate
    case invalidTargetDuration
    case futureStart
    case runNotRunning
    case originalDeadlineElapsed(deadline: Date)
}

/// A preview, not permission to mutate or finish a run automatically.
public enum ActiveStartEditOutcome: Codable, Equatable, Sendable {
    case continueRunning(newStartAt: Date, newDeadline: Date?)
    case requiresExplicitFinish(newStartAt: Date, finishAt: Date)
}

public enum TimerPolicy {
    public static func deadline(mode: TimerMode, startAt: Date) throws -> Date? {
        guard startAt.timeIntervalSinceReferenceDate.isFinite else {
            throw TimerPolicyError.invalidDate
        }
        switch mode {
        case .stopwatch:
            return nil
        case let .pomodoro(targetSeconds):
            guard targetSeconds.isFinite, targetSeconds > 0 else {
                throw TimerPolicyError.invalidTargetDuration
            }
            let result = startAt.addingTimeInterval(targetSeconds)
            guard result.timeIntervalSinceReferenceDate.isFinite else {
                throw TimerPolicyError.invalidDate
            }
            return result
        }
    }

    public static func activeStartEditOutcome(
        run: TimerRun, newStartAt: Date, asOf: Date
    ) throws -> ActiveStartEditOutcome {
        guard run.state == .running else { throw TimerPolicyError.runNotRunning }
        guard asOf.timeIntervalSinceReferenceDate.isFinite,
              newStartAt.timeIntervalSinceReferenceDate.isFinite else {
            throw TimerPolicyError.invalidDate
        }
        // A stale running snapshot cannot extend a pomodoro whose original deadline elapsed.
        // The caller must reconcile first, then edit the resulting completed entry as history.
        if case .pomodoro = run.mode, let originalDeadline = run.deadline {
            guard originalDeadline.timeIntervalSinceReferenceDate.isFinite else {
                throw TimerPolicyError.invalidDate
            }
            if originalDeadline <= asOf {
                throw TimerPolicyError.originalDeadlineElapsed(deadline: originalDeadline)
            }
        }
        guard newStartAt <= asOf else { throw TimerPolicyError.futureStart }
        let newDeadline = try deadline(mode: run.mode, startAt: newStartAt)
        if let newDeadline, newDeadline <= asOf {
            return .requiresExplicitFinish(newStartAt: newStartAt, finishAt: newDeadline)
        }
        return .continueRunning(newStartAt: newStartAt, newDeadline: newDeadline)
    }
}

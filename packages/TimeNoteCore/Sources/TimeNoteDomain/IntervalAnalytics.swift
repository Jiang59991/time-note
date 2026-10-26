import Foundation

/// All intervals use half-open semantics [start, end). A nil end is open until asOf.
public struct ActivityInterval: Codable, Equatable, Sendable {
    public let start: Date
    public let end: Date?

    public init(start: Date, end: Date?) {
        self.start = start
        self.end = end
    }

    /// This conversion has no TimerRun information. Before analytics, callers must reconcile
    /// expired pomodoros or supply a projected end of min(asOf, run.deadline) for open pomodoros.
    /// Otherwise a stale nil entry.endAt would count time beyond its scheduled deadline.
    public init(entry: TimeEntry) {
        self.init(start: entry.startAt, end: entry.endAt)
    }
}

public struct IntervalSummary: Codable, Equatable, Sendable {
    public let elapsedSeconds: TimeInterval
    public let cumulativeSeconds: TimeInterval
    public let coveredSeconds: TimeInterval
    public let concurrentSeconds: TimeInterval
    public let unrecordedSeconds: TimeInterval
    public let peakConcurrency: Int

    public init(
        elapsedSeconds: TimeInterval,
        cumulativeSeconds: TimeInterval,
        coveredSeconds: TimeInterval,
        concurrentSeconds: TimeInterval,
        unrecordedSeconds: TimeInterval,
        peakConcurrency: Int
    ) {
        self.elapsedSeconds = elapsedSeconds
        self.cumulativeSeconds = cumulativeSeconds
        self.coveredSeconds = coveredSeconds
        self.concurrentSeconds = concurrentSeconds
        self.unrecordedSeconds = unrecordedSeconds
        self.peakConcurrency = peakConcurrency
    }
}

public enum IntervalAnalyticsError: Error, Equatable, Sendable {
    case invalidWindow
    case invalidAsOf
    case invalidInterval(index: Int)
}

public enum IntervalAnalytics {
    /// Counts each supplied interval once; callers must not supply duplicate entry snapshots.
    /// Rejects reversed/nonfinite intervals; zero-length intervals contribute nothing.
    /// Day windows must come from Calendar.dateInterval(of: .day, for:), never 86,400 seconds.
    public static func summarize(
        intervals: [ActivityInterval], window: DateInterval, asOf: Date
    ) throws -> IntervalSummary {
        guard window.start.timeIntervalSinceReferenceDate.isFinite,
              window.end.timeIntervalSinceReferenceDate.isFinite,
              window.duration.isFinite, window.duration >= 0 else {
            throw IntervalAnalyticsError.invalidWindow
        }
        guard asOf.timeIntervalSinceReferenceDate.isFinite else {
            throw IntervalAnalyticsError.invalidAsOf
        }
        for (index, interval) in intervals.enumerated() {
            guard interval.start.timeIntervalSinceReferenceDate.isFinite else {
                throw IntervalAnalyticsError.invalidInterval(index: index)
            }
            if let end = interval.end,
               !end.timeIntervalSinceReferenceDate.isFinite || end < interval.start {
                throw IntervalAnalyticsError.invalidInterval(index: index)
            }
        }

        let cutoff = min(window.end, asOf)
        let elapsed = max(0, cutoff.timeIntervalSince(window.start))
        var events: [Date: Int] = [:]
        var cumulative: TimeInterval = 0
        if elapsed > 0 {
            for interval in intervals {
                let start = max(window.start, interval.start)
                let end = min(cutoff, interval.end ?? asOf)
                guard start < end else { continue }
                cumulative += end.timeIntervalSince(start)
                events[start, default: 0] += 1
                events[end, default: 0] -= 1
            }
        }

        var active = 0
        var peak = 0
        var previous = window.start
        var covered: TimeInterval = 0
        var concurrent: TimeInterval = 0
        for instant in events.keys.sorted() {
            let duration = instant.timeIntervalSince(previous)
            if active >= 1 { covered += duration }
            if active >= 2 { concurrent += duration }
            // Same-instant starts and ends are grouped: adjacent intervals do not overlap.
            active += events[instant, default: 0]
            peak = max(peak, active)
            previous = instant
        }
        return IntervalSummary(
            elapsedSeconds: elapsed,
            cumulativeSeconds: cumulative,
            coveredSeconds: covered,
            concurrentSeconds: concurrent,
            unrecordedSeconds: max(0, elapsed - covered),
            peakConcurrency: peak
        )
    }
}

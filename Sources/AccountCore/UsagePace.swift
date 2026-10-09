import Foundation

/// A linear budget for one rate-limit window. Percentages are on the used scale
/// internally; the UI presents the equivalent remaining scale.
public struct UsagePace: Sendable {
    public let expectedRemaining: Double
    /// Positive means more has been consumed than the linear budget allows.
    public let deficitPoints: Double
    public let projectedExhaustion: Date?
    public let reachesReset: Bool

    public static func calculate(
        remaining: Double,
        reset: Date?,
        windowMinutes: Double?,
        fetchedAt: Date,
        now: Date
    ) -> UsagePace? {
        guard remaining.isFinite, (0...100).contains(remaining),
              let reset, let windowMinutes, windowMinutes.isFinite, windowMinutes > 0,
              now.timeIntervalSince(fetchedAt) >= -60,
              now.timeIntervalSince(fetchedAt) <= 900 else { return nil }

        let duration = windowMinutes * 60
        let timeToReset = reset.timeIntervalSince(now)
        let timeToResetAtFetch = reset.timeIntervalSince(fetchedAt)
        guard duration.isFinite, timeToReset > 0, timeToReset <= duration,
              timeToResetAtFetch > 0, timeToResetAtFetch <= duration else { return nil }
        let elapsed = duration - timeToReset
        let elapsedAtFetch = duration - timeToResetAtFetch
        guard elapsedAtFetch / duration >= 0.03 else { return nil }

        let used = 100 - remaining
        let expectedUsed = 100 * elapsed / duration
        let projected: Date?
        let reachesReset: Bool
        if used == 0 {
            projected = nil
            reachesReset = true
        } else if used == 100 {
            projected = fetchedAt
            reachesReset = false
        } else {
            let secondsToExhaustion = (100 - used) * elapsedAtFetch / used
            let date = fetchedAt.addingTimeInterval(secondsToExhaustion)
            guard date.timeIntervalSince1970.isFinite else { return nil }
            projected = date
            reachesReset = date >= reset
        }
        return UsagePace(expectedRemaining: 100 - expectedUsed,
                         deficitPoints: used - expectedUsed,
                         projectedExhaustion: projected,
                         reachesReset: reachesReset)
    }
}

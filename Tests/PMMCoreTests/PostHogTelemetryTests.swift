import Foundation
import Testing
@testable import PMMCore

@Test func heartbeatIsDueOncePerDay() {
    let now = Date(timeIntervalSince1970: 1_000_000)

    #expect(PostHogTelemetry.heartbeatIsDue(lastCapturedAt: nil, now: now))
    #expect(!PostHogTelemetry.heartbeatIsDue(lastCapturedAt: now.addingTimeInterval(-86_399), now: now))
    #expect(PostHogTelemetry.heartbeatIsDue(lastCapturedAt: now.addingTimeInterval(-86_400), now: now))
}

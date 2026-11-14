import Foundation
import Testing
@testable import QuotaCore

struct AnchorPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func window(_ id: String, minutes: Int?, remaining: Double,
                        resetOffset: TimeInterval? = 18_000) -> QuotaWindow {
        QuotaWindow(id: id, title: id, remaining: remaining,
                    resetsAt: resetOffset.map { now.addingTimeInterval($0) },
                    durationMinutes: minutes)
    }

    private func snapshot(_ windows: [QuotaWindow]) -> QuotaSnapshot {
        QuotaSnapshot(windows: windows, receivedAt: now, plan: "plus")
    }

    private func emptySnapshot() -> QuotaSnapshot {
        snapshot([
            window("codex.primary", minutes: 300, remaining: 100),
            window("codex.secondary", minutes: 10_080, remaining: 18, resetOffset: 500_000)
        ])
    }

    @Test
    func testEmptyTargetWindowRequestsPing() {
        var state = AnchorState(enabled: true)
        let decision = state.observe(emptySnapshot(), now: now)
        #expect(decision.pingWindowIDs == ["codex.primary"])
        #expect(decision.shouldPing)
        #expect(state.windows["codex.primary"]?.armed == true)
    }

    @Test
    func testWeeklyWindowTriggersWhenEmpty() {
        var state = AnchorState(enabled: true)
        let snapshot = snapshot([
            window("codex.primary", minutes: 300, remaining: 40),
            window("codex.secondary", minutes: 10_080, remaining: 100, resetOffset: 604_800)
        ])
        #expect(state.observe(snapshot, now: now).pingWindowIDs == ["codex.secondary"])
    }

    @Test
    func testNonEmptyWindowRearms() {
        var state = AnchorState(enabled: true)
        state.markFailure(["codex.primary"], error: "boom", at: now)
        let used = snapshot([
            window("codex.primary", minutes: 300, remaining: 60),
            window("codex.secondary", minutes: 10_080, remaining: 18)
        ])
        _ = state.observe(used, now: now)
        #expect(state.windows["codex.primary"]?.armed == true)
        #expect(state.windows["codex.primary"]?.attempts == 0)
    }

    @Test
    func testSuccessDisarmsOnlyEmptyWindows() {
        var state = AnchorState(enabled: true)
        let decision = state.observe(emptySnapshot(), now: now)
        state.markStarted(decision.pingWindowIDs, at: now)
        state.markSuccess(decision.pingWindowIDs, usage: TokenUsage(input: 1_000, output: 100), at: now)
        #expect(state.windows["codex.primary"]?.armed == false)
        #expect(state.windows["codex.secondary"]?.armed == true)

        let again = state.observe(emptySnapshot(), now: now.addingTimeInterval(120))
        #expect(again.pingWindowIDs.isEmpty)
    }

    @Test
    func testFailureBacksOffBeforeRetrying() {
        var state = AnchorState(enabled: true)
        let decision = state.observe(emptySnapshot(), now: now)
        state.markStarted(decision.pingWindowIDs, at: now)
        state.markFailure(decision.pingWindowIDs, error: "boom", at: now)
        #expect(state.windows["codex.primary"]?.nextAttemptAt == now.addingTimeInterval(60))

        #expect(state.observe(emptySnapshot(), now: now.addingTimeInterval(30)).pingWindowIDs.isEmpty)
        #expect(state.observe(emptySnapshot(), now: now.addingTimeInterval(61)).pingWindowIDs == ["codex.primary"])
    }

    @Test
    func testFailureStopsAfterMaximumAttempts() {
        var state = AnchorState(enabled: true)
        _ = state.observe(emptySnapshot(), now: now)
        for _ in 0..<AnchorState.maximumAttempts {
            state.markFailure(["codex.primary"], error: "boom", at: now)
        }
        #expect(state.windows["codex.primary"]?.armed == false)
        let later = now.addingTimeInterval(100_000)
        #expect(state.observe(emptySnapshot(), now: later).pingWindowIDs.isEmpty)
    }

    @Test
    func testDisabledNeverPings() {
        var state = AnchorState(enabled: false)
        #expect(state.observe(emptySnapshot(), now: now).shouldPing == false)
    }

    @Test
    func testEmptyThreshold() {
        var almost = AnchorState(enabled: true)
        let nearlyEmpty = snapshot([window("codex.primary", minutes: 300, remaining: 99.5)])
        #expect(almost.observe(nearlyEmpty, now: now).shouldPing == false)

        var empty = AnchorState(enabled: true)
        let threshold = snapshot([window("codex.primary", minutes: 300, remaining: 99.95)])
        #expect(empty.observe(threshold, now: now).pingWindowIDs == ["codex.primary"])
    }

    @Test
    func testIgnoresOtherBucketsAndDurations() {
        var state = AnchorState(enabled: true)
        let snapshot = snapshot([
            window("spark.primary", minutes: 300, remaining: 100),
            window("codex.primary", minutes: 60, remaining: 100)
        ])
        #expect(state.observe(snapshot, now: now).shouldPing == false)
    }

    @Test
    func testStartedCooldownBlocksDuplicateDecision() {
        var state = AnchorState(enabled: true)
        let decision = state.observe(emptySnapshot(), now: now)
        state.markStarted(decision.pingWindowIDs, at: now)
        #expect(state.observe(emptySnapshot(), now: now.addingTimeInterval(10)).shouldPing == false)
    }

    @Test
    func testAnchoredWindowWithRoundedUsageIsNotEmpty() {
        // Usage that rounds to 0% still leaves a fixed resetsAt, ten minutes in the past
        // relative to the sliding placeholder.
        var state = AnchorState(enabled: true)
        let anchored = snapshot([
            window("codex.primary", minutes: 300, remaining: 100, resetOffset: 18_000 - 600)
        ])
        #expect(state.observe(anchored, now: now).shouldPing == false)
        #expect(state.windows["codex.primary"]?.armed == true)
    }

    @Test
    func testRearmsAfterPingAgesOut() {
        var state = AnchorState(enabled: true)
        let decision = state.observe(emptySnapshot(), now: now)
        state.markStarted(decision.pingWindowIDs, at: now)
        state.markSuccess(decision.pingWindowIDs, usage: TokenUsage(input: 20_000, output: 10), at: now)

        // Ten minutes later the window is anchored, so it must re-arm for the next reset.
        let anchored = snapshot([
            window("codex.primary", minutes: 300, remaining: 100, resetOffset: 18_000 - 600),
            window("codex.secondary", minutes: 10_080, remaining: 18, resetOffset: 500_000)
        ])
        let decisionLater = state.observe(anchored, now: now.addingTimeInterval(600))
        #expect(decisionLater.shouldPing == false)
        #expect(state.windows["codex.primary"]?.armed == true)
    }

    @Test
    func testPersistenceRoundTrip() {
        var state = AnchorState(enabled: true)
        let decision = state.observe(emptySnapshot(), now: now)
        state.markSuccess(decision.pingWindowIDs, usage: TokenUsage(input: 10, output: 1), at: now)
        let restored = AnchorState(data: state.encoded)
        #expect(restored == state)
    }
}

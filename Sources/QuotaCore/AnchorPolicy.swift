import Foundation

/// Persistent per-window state for the "anchor the reset time" automation.
public struct AnchorWindowState: Codable, Equatable, Sendable {
    public var id: String
    public var durationMinutes: Int?
    public var remaining: Double
    public var resetsAt: Date?
    /// `true` when the window may be pinged the next time it is empty.
    public var armed: Bool
    public var attempts: Int
    public var lastAttemptAt: Date?
    public var nextAttemptAt: Date?
    public var lastOutcome: String?

    public init(id: String, durationMinutes: Int? = nil, remaining: Double = 100,
                resetsAt: Date? = nil, armed: Bool = true, attempts: Int = 0,
                lastAttemptAt: Date? = nil, nextAttemptAt: Date? = nil,
                lastOutcome: String? = nil) {
        self.id = id
        self.durationMinutes = durationMinutes
        self.remaining = remaining
        self.resetsAt = resetsAt
        self.armed = armed
        self.attempts = attempts
        self.lastAttemptAt = lastAttemptAt
        self.nextAttemptAt = nextAttemptAt
        self.lastOutcome = lastOutcome
    }
}

public struct AnchorDecision: Equatable, Sendable {
    public let pingWindowIDs: [String]
    public let reason: String

    public var shouldPing: Bool { !pingWindowIDs.isEmpty }

    public init(pingWindowIDs: [String] = [], reason: String = "") {
        self.pingWindowIDs = pingWindowIDs
        self.reason = reason
    }
}

/// Decides when to send one "你好" turn so an empty quota window gets anchored again.
///
/// Both the 5-hour and the weekly Codex windows report `usedPercent == 0` together with a
/// `resetsAt` that slides forward while the window is empty. Sending a message fixes
/// `resetsAt` at "send time + window duration"; the window becomes non-empty and stays armed
/// for the next cycle.
public struct AnchorState: Codable, Equatable, Sendable {
    public static let targetDurations: Set<Int> = [300, 10_080]
    /// `remaining` at or above this value means the window has no measurable usage.
    public static let emptyThreshold = 99.9
    /// An empty window reports `resetsAt ≈ now + duration`; this is how far it may differ.
    public static let emptyTolerance: TimeInterval = 180
    public static let maximumAttempts = 10

    public private(set) var windows: [String: AnchorWindowState]
    public var enabled: Bool

    public init(windows: [String: AnchorWindowState] = [:], enabled: Bool = true) {
        self.windows = windows
        self.enabled = enabled
    }

    public static func isTarget(_ window: QuotaWindow) -> Bool {
        guard window.id.hasPrefix("codex."), let duration = window.durationMinutes else { return false }
        return targetDurations.contains(duration)
    }

    /// A window is empty when it has no measurable usage *and* its `resetsAt` is the
    /// sliding placeholder (`now + duration`). Usage that rounds to 0% still leaves a
    /// fixed `resetsAt`, so it is not mistaken for an empty window after a ping.
    public static func isEmpty(_ window: QuotaWindow, now: Date) -> Bool {
        guard window.remaining >= emptyThreshold, let duration = window.durationMinutes,
              let reset = window.resetsAt else { return false }
        let windowLength = TimeInterval(duration * 60)
        return abs(reset.timeIntervalSince(now) - windowLength) <= emptyTolerance
    }

    /// Folds one quota snapshot into the state and returns the windows to ping now.
    public mutating func observe(_ snapshot: QuotaSnapshot, now: Date = Date()) -> AnchorDecision {
        var pingIDs: [String] = []
        var labels: [String] = []
        for window in snapshot.windows where Self.isTarget(window) {
            var state = windows[window.id]
                ?? AnchorWindowState(id: window.id, durationMinutes: window.durationMinutes)
            state.durationMinutes = window.durationMinutes
            state.remaining = window.remaining
            state.resetsAt = window.resetsAt
            if Self.isEmpty(window, now: now) {
                let ready = enabled
                    && state.armed
                    && state.attempts < Self.maximumAttempts
                    && (state.nextAttemptAt.map { now >= $0 } ?? true)
                if ready {
                    pingIDs.append(window.id)
                    labels.append(window.title)
                }
            } else {
                // Usage exists, so this window is anchored: prepare for its next empty phase.
                state.armed = true
                state.attempts = 0
                state.nextAttemptAt = nil
            }
            windows[window.id] = state
        }
        return AnchorDecision(pingWindowIDs: pingIDs, reason: labels.joined(separator: "、"))
    }

    public mutating func markStarted(_ ids: [String], at now: Date) {
        for id in ids {
            guard var state = windows[id] else { continue }
            state.lastAttemptAt = now
            state.nextAttemptAt = now.addingTimeInterval(60)
            state.lastOutcome = "发送中"
            windows[id] = state
        }
    }

    public mutating func markSuccess(_ ids: [String], usage: TokenUsage?, at now: Date) {
        let suffix = usage.map { "（\(TokenUsage.compact($0.total)) tokens）" } ?? ""
        for id in ids {
            guard var state = windows[id] else { continue }
            state.armed = false
            state.attempts = 0
            state.nextAttemptAt = nil
            state.lastAttemptAt = now
            state.lastOutcome = "成功" + suffix
            windows[id] = state
        }
    }

    public mutating func markFailure(_ ids: [String], error: String, at now: Date) {
        for id in ids {
            guard var state = windows[id] else { continue }
            state.attempts += 1
            state.lastAttemptAt = now
            state.lastOutcome = "失败：\(error)"
            state.nextAttemptAt = now.addingTimeInterval(Self.backoff(attempt: state.attempts))
            if state.attempts >= Self.maximumAttempts { state.armed = false }
            windows[id] = state
        }
    }

    public static func backoff(attempt: Int) -> TimeInterval {
        switch attempt {
        case ...1: return 60
        case 2: return 300
        case 3: return 900
        default: return 1_800
        }
    }

    public var encoded: Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    public init(data: Data) {
        guard let decoded = try? JSONDecoder().decode(AnchorState.self, from: data) else {
            self.init()
            return
        }
        self = decoded
    }
}

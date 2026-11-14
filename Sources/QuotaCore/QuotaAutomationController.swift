import Combine
import Foundation

/// Watches quota snapshots and sends one "你好" turn whenever a target window is empty,
/// so its reset time is anchored to the send time.
@MainActor
public final class QuotaAutomationController: ObservableObject {
    @Published public private(set) var enabled: Bool
    @Published public private(set) var isRunning = false
    @Published public private(set) var lastOutcome: String?
    @Published public private(set) var lastOutcomeAt: Date?

    private static let enabledKey = "automation.enabled"
    private static let stateKey = "automation.state"
    private static let outcomeKey = "automation.lastOutcome"
    private static let outcomeAtKey = "automation.lastOutcomeAt"

    private let defaults: UserDefaults
    private let executableProvider: @MainActor () -> URL?
    private let workingDirectory: URL
    private var state: AnchorState
    private var runner: CodexPingRunner?
    private var checkTimer: Timer?
    private var nextCheckAt: Date?

    public var onChange: (() -> Void)?
    public var onRefreshNeeded: (() -> Void)?
    public var onEnabledChanged: ((Bool) -> Void)?

    public init(defaults: UserDefaults = .standard,
         workingDirectory: URL? = nil,
         executableProvider: (@MainActor () -> URL?)? = nil) {
        self.defaults = defaults
        self.workingDirectory = workingDirectory ?? Self.defaultWorkingDirectory
        self.executableProvider = executableProvider ?? { nil }
        let storedEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        self.enabled = storedEnabled
        self.state = defaults.data(forKey: Self.stateKey).map { AnchorState(data: $0) }
            ?? AnchorState(enabled: storedEnabled)
        self.state.enabled = storedEnabled
        self.lastOutcome = defaults.string(forKey: Self.outcomeKey)
        self.lastOutcomeAt = defaults.object(forKey: Self.outcomeAtKey) as? Date
    }

    public static var defaultWorkingDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("QuotaCompanion/ping", isDirectory: true)
    }

    public func handle(_ snapshot: QuotaSnapshot) {
        state.enabled = enabled
        let decision = state.observe(snapshot)
        persistState()
        guard enabled else { return }
        scheduleCheck(for: snapshot)
        guard decision.shouldPing, !isRunning else { return }
        start(decision)
    }

    public func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        state.enabled = value
        defaults.set(value, forKey: Self.enabledKey)
        persistState()
        if value {
            onRefreshNeeded?()
        } else {
            checkTimer?.invalidate()
            checkTimer = nil
            nextCheckAt = nil
        }
        onEnabledChanged?(value)
        onChange?()
    }

    public func stop() {
        runner?.cancel()
        runner = nil
        checkTimer?.invalidate()
        checkTimer = nil
    }

    private func start(_ decision: AnchorDecision) {
        guard let executable = executableProvider() else {
            record(failure: "找不到 Codex 可执行文件", ids: decision.pingWindowIDs)
            return
        }
        try? FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let runner = CodexPingRunner(executable: executable, workingDirectory: workingDirectory)
        self.runner = runner
        isRunning = true
        state.markStarted(decision.pingWindowIDs, at: Date())
        persistState()
        onChange?()

        let ids = decision.pingWindowIDs
        Task {
            let result = await runner.run()
            finish(result, ids: ids)
        }
    }

    private func finish(_ result: PingResult, ids: [String]) {
        let now = Date()
        isRunning = false
        runner = nil
        if result.succeeded {
            state.markSuccess(ids, usage: result.usage, at: now)
            var text = "成功"
            if let usage = result.usage {
                text += "（\(TokenUsage.compact(usage.total)) tokens）"
            }
            text += result.archived ? "，已归档" : "，归档失败"
            lastOutcome = text
        } else {
            let message = result.errorDescription ?? "未知错误"
            state.markFailure(ids, error: message, at: now)
            lastOutcome = "失败：\(message)"
        }
        lastOutcomeAt = now
        persistState()
        persistOutcome()
        onChange?()
    }

    private func record(failure: String, ids: [String]) {
        let now = Date()
        state.markFailure(ids, error: failure, at: now)
        lastOutcome = "失败：\(failure)"
        lastOutcomeAt = now
        persistState()
        persistOutcome()
        onChange?()
    }

    /// Wakes the quota client a few seconds after a window is expected to empty, so the
    /// next cycle is anchored within seconds instead of drifting with the 60-second poll.
    private func scheduleCheck(for snapshot: QuotaSnapshot) {
        let now = Date()
        var candidates: [Date] = []
        for window in snapshot.windows where AnchorState.isTarget(window) {
            guard let reset = window.resetsAt else { continue }
            // An empty window is pinged right away; anchored windows are checked at their reset.
            if AnchorState.isEmpty(window, now: now) { continue }
            if reset > now {
                candidates.append(reset.addingTimeInterval(5))
            } else if now.timeIntervalSince(reset) < 120 {
                candidates.append(now.addingTimeInterval(10))
            }
        }
        guard let next = candidates.min() else {
            checkTimer?.invalidate()
            checkTimer = nil
            nextCheckAt = nil
            return
        }
        guard nextCheckAt != next else { return }
        nextCheckAt = next
        checkTimer?.invalidate()
        checkTimer = Timer.scheduledTimer(withTimeInterval: max(1, next.timeIntervalSinceNow),
                                          repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.nextCheckAt = nil
                self?.onRefreshNeeded?()
            }
        }
    }

    private func persistState() {
        defaults.set(state.encoded, forKey: Self.stateKey)
    }

    private func persistOutcome() {
        if let lastOutcome { defaults.set(lastOutcome, forKey: Self.outcomeKey) }
        if let lastOutcomeAt { defaults.set(lastOutcomeAt, forKey: Self.outcomeAtKey) }
    }
}

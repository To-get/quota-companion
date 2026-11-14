import Foundation

public struct PingResult: Equatable, Sendable {
    public var threadID: String?
    public var usage: TokenUsage?
    public var turnCompleted: Bool
    public var archived: Bool
    public var errorDescription: String?
    public var warning: String?
    public var duration: TimeInterval

    public var succeeded: Bool { turnCompleted && errorDescription == nil }

    public init(threadID: String? = nil, usage: TokenUsage? = nil, turnCompleted: Bool = false,
                archived: Bool = false, errorDescription: String? = nil,
                warning: String? = nil, duration: TimeInterval = 0) {
        self.threadID = threadID
        self.usage = usage
        self.turnCompleted = turnCompleted
        self.archived = archived
        self.errorDescription = errorDescription
        self.warning = warning
        self.duration = duration
    }
}

/// Runs one `codex exec` turn with the prompt "你好" and archives the resulting session.
///
/// The CLI is the documented automation surface: `exec --json` emits `thread.started`
/// (with `thread_id`), `turn.completed` (with `usage`) and `turn.failed`; `archive <id>`
/// hides the session again. `--ignore-user-config` keeps the turn small by skipping the
/// user's MCP servers and plugins; authentication still comes from `CODEX_HOME/auth.json`.
public final class CodexPingRunner: @unchecked Sendable {
    public var executable: URL
    public var workingDirectory: URL
    public var timeout: TimeInterval
    public var archiveTimeout: TimeInterval
    public var prompt: String

    private let lock = NSLock()
    private var currentProcess: Process?

    public init(executable: URL, workingDirectory: URL, timeout: TimeInterval = 120,
                archiveTimeout: TimeInterval = 30, prompt: String = "你好") {
        self.executable = executable
        self.workingDirectory = workingDirectory
        self.timeout = timeout
        self.archiveTimeout = archiveTimeout
        self.prompt = prompt
    }

    public var execArguments: [String] {
        ["exec", "--json", "--color", "never", "--ignore-user-config",
         "-c", #"forced_login_method="chatgpt""#,
         "-c", #"approval_policy="never""#,
         "-c", #"model_reasoning_effort="low""#,
         "-s", "read-only", "--skip-git-repo-check",
         "-C", workingDirectory.path,
         prompt]
    }

    public func archiveArguments(_ threadID: String) -> [String] { ["archive", threadID] }

    public func run() async -> PingResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: self.runSync())
            }
        }
    }

    /// Terminates a turn that is still running; called when the app quits.
    public func cancel() {
        lock.lock()
        let process = currentProcess
        lock.unlock()
        if let process, process.isRunning { process.terminate() }
    }

    private func runSync() -> PingResult {
        let started = Date()
        let exec = runProcess(arguments: execArguments, timeout: timeout)
        let parsed = Self.parse(exec.stdout)
        var failure: String?
        if exec.timedOut {
            failure = "发送超时"
        } else if let launchError = exec.launchError {
            failure = "无法启动 Codex：\(launchError)"
        } else if !parsed.completed {
            if let turnFailure = parsed.failure {
                failure = turnFailure
            } else if exec.exitCode != 0 {
                failure = "发送失败（退出码 \(exec.exitCode)）\(Self.stderrTail(exec.stderr))"
            } else {
                failure = "发送未完成"
            }
        }

        var archived = false
        var warning: String?
        if let threadID = parsed.threadID {
            for attempt in 0..<2 {
                let archive = runProcess(arguments: archiveArguments(threadID), timeout: archiveTimeout)
                if archive.exitCode == 0, !archive.timedOut, archive.launchError == nil {
                    archived = true
                    break
                }
                if attempt == 0 { Thread.sleep(forTimeInterval: 2) }
            }
            if !archived { warning = "会话已发送，但归档失败" }
        } else if parsed.completed {
            warning = "未拿到会话 id，无法归档"
        }

        return PingResult(threadID: parsed.threadID, usage: parsed.usage, turnCompleted: parsed.completed,
                          archived: archived, errorDescription: failure, warning: warning,
                          duration: Date().timeIntervalSince(started))
    }

    // MARK: - Process

    private struct ProcessOutcome {
        var exitCode: Int32 = -1
        var stdout = Data()
        var stderr = Data()
        var timedOut = false
        var launchError: String?
    }

    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var stdoutData = Data()
        private var stderrData = Data()

        var stdout: Data {
            lock.lock(); defer { lock.unlock() }
            return stdoutData
        }

        var stderr: Data {
            lock.lock(); defer { lock.unlock() }
            return stderrData
        }

        func setStdout(_ data: Data) {
            lock.lock(); stdoutData = data; lock.unlock()
        }

        func setStderr(_ data: Data) {
            lock.lock(); stderrData = data; lock.unlock()
        }
    }

    private func runProcess(arguments: [String], timeout: TimeInterval) -> ProcessOutcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        var outcome = ProcessOutcome()
        do {
            try process.run()
        } catch {
            outcome.launchError = error.localizedDescription
            return outcome
        }

        lock.lock(); currentProcess = process; lock.unlock()
        defer { lock.lock(); currentProcess = nil; lock.unlock() }

        let collector = OutputCollector()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            collector.setStdout(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            collector.setStderr(stderrPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            outcome.timedOut = true
            process.terminate()
            let killDeadline = Date().addingTimeInterval(5)
            while process.isRunning && Date() < killDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        group.wait()
        outcome.exitCode = process.terminationStatus
        outcome.stdout = collector.stdout
        outcome.stderr = collector.stderr
        return outcome
    }

    // MARK: - Event parsing

    private struct ParsedExec {
        var threadID: String?
        var usage: TokenUsage?
        var completed = false
        var failure: String?
    }

    private static func parse(_ stdout: Data) -> ParsedExec {
        var parsed = ParsedExec()
        for line in stdout.split(separator: 0x0A) {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let type = object["type"] as? String else { continue }
            switch type {
            case "thread.started":
                parsed.threadID = object["thread_id"] as? String ?? object["threadId"] as? String
            case "turn.completed":
                parsed.completed = true
                parsed.usage = usage(object["usage"])
            case "turn.failed":
                parsed.failure = (object["error"] as? String)
                    ?? (object["message"] as? String)
                    ?? (object["error"] as? [String: Any]).flatMap { $0["message"] as? String }
                    ?? "回合失败"
            default:
                continue
            }
        }
        return parsed
    }

    private static func usage(_ value: Any?) -> TokenUsage? {
        guard let dictionary = value as? [String: Any] else { return nil }
        return TokenUsage(
            input: RolloutLine.int64(dictionary["input_tokens"]) ?? 0,
            cachedInput: RolloutLine.int64(dictionary["cached_input_tokens"]) ?? 0,
            cacheWriteInput: RolloutLine.int64(dictionary["cache_write_input_tokens"]) ?? 0,
            output: RolloutLine.int64(dictionary["output_tokens"]) ?? 0,
            reasoning: RolloutLine.int64(dictionary["reasoning_output_tokens"]) ?? 0,
            total: RolloutLine.int64(dictionary["total_tokens"])
        )
    }

    private static func stderrTail(_ data: Data) -> String {
        let text = String(decoding: data.suffix(400), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "" : "：\(text)"
    }
}

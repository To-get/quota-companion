import Foundation
import Testing
@testable import QuotaCore

@MainActor
struct QuotaAutomationTests {
    private func makeEnvironment(failTurn: Bool = false) throws
        -> (directory: URL, executable: URL, log: URL, defaults: UserDefaults, suite: String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let log = directory.appendingPathComponent("invocations.log")
        let executable = directory.appendingPathComponent("fake-codex")
        let failure = failTurn ? """
        print(json.dumps({"type":"thread.started","thread_id":"abc-123"}), flush=True)
        print(json.dumps({"type":"turn.failed","error":"boom"}), flush=True)
        sys.exit(1)
        """ : """
        print(json.dumps({"type":"thread.started","thread_id":"abc-123"}), flush=True)
        print(json.dumps({"type":"turn.completed","usage":{"input_tokens":200,"cached_input_tokens":100,"output_tokens":20,"total_tokens":220}}), flush=True)
        """
        let script = """
        #!/usr/bin/python3
        import sys, json
        with open("\(log.path)", "a") as f:
            f.write(" ".join(sys.argv[1:]) + "\\n")
        if sys.argv[1:2] == ["archive"]:
            sys.exit(0)
        \(failure)
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let suite = "quota-automation-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (directory, executable, log, defaults, suite)
    }

    private func snapshot(remaining: Double = 100, resetOffset: TimeInterval = 18_000) -> QuotaSnapshot {
        let now = Date()
        return QuotaSnapshot(windows: [
            QuotaWindow(id: "codex.primary", title: "5 小时额度", remaining: remaining,
                        resetsAt: now.addingTimeInterval(resetOffset), durationMinutes: 300),
            QuotaWindow(id: "codex.secondary", title: "每周额度", remaining: 18,
                        resetsAt: now.addingTimeInterval(500_000), durationMinutes: 10_080)
        ], receivedAt: now, plan: "plus")
    }

    private func waitForIdle(_ controller: QuotaAutomationController,
                             timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !controller.isRunning, controller.lastOutcome != nil { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }

    private func archiveCount(_ log: URL) -> Int {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return 0 }
        return text.components(separatedBy: "archive abc-123").count - 1
    }

    @Test
    func testEmptyWindowSendsAndArchives() async throws {
        let env = try makeEnvironment()
        defer {
            try? FileManager.default.removeItem(at: env.directory)
            env.defaults.removePersistentDomain(forName: env.suite)
        }
        let controller = QuotaAutomationController(defaults: env.defaults,
                                                   workingDirectory: env.directory,
                                                   executableProvider: { env.executable })
        defer { controller.stop() }

        controller.handle(snapshot())
        #expect(await waitForIdle(controller))
        #expect(controller.lastOutcome?.contains("成功") == true)
        #expect(controller.lastOutcome?.contains("已归档") == true)
        #expect(archiveCount(env.log) == 1)

        let invocations = try String(contentsOf: env.log, encoding: .utf8)
        #expect(invocations.contains("--ignore-user-config"))
        #expect(invocations.contains("你好"))
    }

    @Test
    func testSecondSnapshotDoesNotSendAgain() async throws {
        let env = try makeEnvironment()
        defer {
            try? FileManager.default.removeItem(at: env.directory)
            env.defaults.removePersistentDomain(forName: env.suite)
        }
        let controller = QuotaAutomationController(defaults: env.defaults,
                                                   workingDirectory: env.directory,
                                                   executableProvider: { env.executable })
        defer { controller.stop() }

        controller.handle(snapshot())
        #expect(await waitForIdle(controller))
        controller.handle(snapshot())
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(controller.isRunning == false)
        #expect(archiveCount(env.log) == 1)
    }

    @Test
    func testNonEmptyWindowDoesNotSend() async throws {
        let env = try makeEnvironment()
        defer {
            try? FileManager.default.removeItem(at: env.directory)
            env.defaults.removePersistentDomain(forName: env.suite)
        }
        let controller = QuotaAutomationController(defaults: env.defaults,
                                                   workingDirectory: env.directory,
                                                   executableProvider: { env.executable })
        defer { controller.stop() }

        controller.handle(snapshot(remaining: 50))
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(controller.lastOutcome == nil)
        #expect(archiveCount(env.log) == 0)
    }

    @Test
    func testDisabledDoesNotSend() async throws {
        let env = try makeEnvironment()
        defer {
            try? FileManager.default.removeItem(at: env.directory)
            env.defaults.removePersistentDomain(forName: env.suite)
        }
        let controller = QuotaAutomationController(defaults: env.defaults,
                                                   workingDirectory: env.directory,
                                                   executableProvider: { env.executable })
        defer { controller.stop() }
        controller.setEnabled(false)
        controller.handle(snapshot())
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(archiveCount(env.log) == 0)
    }

    @Test
    func testStatePersistsAcrossControllers() async throws {
        let env = try makeEnvironment()
        defer {
            try? FileManager.default.removeItem(at: env.directory)
            env.defaults.removePersistentDomain(forName: env.suite)
        }
        let first = QuotaAutomationController(defaults: env.defaults,
                                              workingDirectory: env.directory,
                                              executableProvider: { env.executable })
        first.handle(snapshot())
        #expect(await waitForIdle(first))
        first.stop()
        #expect(archiveCount(env.log) == 1)

        let second = QuotaAutomationController(defaults: env.defaults,
                                               workingDirectory: env.directory,
                                               executableProvider: { env.executable })
        defer { second.stop() }
        #expect(second.enabled)
        #expect(second.lastOutcome != nil)
        second.handle(snapshot())
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(archiveCount(env.log) == 1)
    }

    @Test
    func testFailureIsRecorded() async throws {
        let env = try makeEnvironment(failTurn: true)
        defer {
            try? FileManager.default.removeItem(at: env.directory)
            env.defaults.removePersistentDomain(forName: env.suite)
        }
        let controller = QuotaAutomationController(defaults: env.defaults,
                                                   workingDirectory: env.directory,
                                                   executableProvider: { env.executable })
        defer { controller.stop() }

        controller.handle(snapshot())
        #expect(await waitForIdle(controller))
        #expect(controller.lastOutcome?.contains("失败") == true)
        #expect(controller.lastOutcome?.contains("boom") == true)
    }

    @Test
    func testMissingExecutableIsReported() async throws {
        let suite = "quota-automation-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = QuotaAutomationController(defaults: defaults,
                                                   workingDirectory: FileManager.default.temporaryDirectory,
                                                   executableProvider: { nil })
        defer { controller.stop() }

        controller.handle(snapshot())
        #expect(await waitForIdle(controller))
        #expect(controller.lastOutcome?.contains("找不到 Codex 可执行文件") == true)
    }
}

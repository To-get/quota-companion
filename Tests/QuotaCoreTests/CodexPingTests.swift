import Foundation
import Testing
@testable import QuotaCore

struct CodexPingTests {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func install(_ body: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("fake-codex")
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private func script(_ events: String, log: URL, archiveExitCode: Int = 0) -> String {
        """
        #!/usr/bin/python3
        import sys, json, time
        with open("\(log.path)", "a") as f:
            f.write(" ".join(sys.argv[1:]) + "\\n")
        if sys.argv[1:2] == ["archive"]:
            sys.exit(\(archiveExitCode))
        \(events)
        """
    }

    @Test
    func testSuccessParsesThreadAndArchives() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("invocations.log")
        let events = """
        print(json.dumps({"type":"thread.started","thread_id":"abc-123"}), flush=True)
        print(json.dumps({"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":50,"output_tokens":10,"total_tokens":110}}), flush=True)
        """
        let executable = try install(script(events, log: log), in: directory)
        let runner = CodexPingRunner(executable: executable, workingDirectory: directory,
                                     timeout: 5, archiveTimeout: 5)
        let result = await runner.run()

        #expect(result.succeeded)
        #expect(result.threadID == "abc-123")
        #expect(result.archived)
        #expect(result.usage?.total == 110)
        #expect(result.usage?.cachedInput == 50)

        let invocations = try String(contentsOf: log, encoding: .utf8)
        #expect(invocations.contains("archive abc-123"))
        #expect(invocations.contains("--ignore-user-config"))
        #expect(invocations.contains("你好"))
    }

    @Test
    func testTurnFailureStillArchives() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("invocations.log")
        let events = """
        print(json.dumps({"type":"thread.started","thread_id":"def-456"}), flush=True)
        print(json.dumps({"type":"turn.failed","error":"boom"}), flush=True)
        sys.exit(1)
        """
        let executable = try install(script(events, log: log), in: directory)
        let result = await CodexPingRunner(executable: executable, workingDirectory: directory,
                                           timeout: 5, archiveTimeout: 5).run()

        #expect(result.succeeded == false)
        #expect(result.errorDescription?.contains("boom") == true)
        #expect(result.archived)
        let invocations = try String(contentsOf: log, encoding: .utf8)
        #expect(invocations.contains("archive def-456"))
    }

    @Test
    func testTimeoutIsReportedAndBounded() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("invocations.log")
        let executable = try install(script("time.sleep(30)", log: log), in: directory)
        let started = Date()
        let result = await CodexPingRunner(executable: executable, workingDirectory: directory,
                                           timeout: 0.5, archiveTimeout: 5).run()

        #expect(result.succeeded == false)
        #expect(result.errorDescription == "发送超时")
        #expect(Date().timeIntervalSince(started) < 15)
    }

    @Test
    func testArchiveFailureIsAWarningNotAFailedTurn() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("invocations.log")
        let events = """
        print(json.dumps({"type":"thread.started","thread_id":"ghi-789"}), flush=True)
        print(json.dumps({"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":1,"total_tokens":11}}), flush=True)
        """
        let executable = try install(script(events, log: log, archiveExitCode: 1), in: directory)
        let result = await CodexPingRunner(executable: executable, workingDirectory: directory,
                                           timeout: 5, archiveTimeout: 5).run()

        #expect(result.succeeded)
        #expect(result.archived == false)
        #expect(result.warning?.contains("归档失败") == true)
    }

    @Test
    func testMissingThreadIDIsReported() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("invocations.log")
        let events = """
        print(json.dumps({"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":1,"total_tokens":11}}), flush=True)
        """
        let executable = try install(script(events, log: log), in: directory)
        let result = await CodexPingRunner(executable: executable, workingDirectory: directory,
                                           timeout: 5, archiveTimeout: 5).run()

        #expect(result.succeeded)
        #expect(result.archived == false)
        #expect(result.warning?.contains("会话 id") == true)
    }

    @Test
    func testMalformedLinesAreIgnored() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("invocations.log")
        let events = """
        print("not json", flush=True)
        print(json.dumps({"type":"thread.started","thread_id":"jkl-012"}), flush=True)
        print(json.dumps({"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":1,"total_tokens":11}}), flush=True)
        """
        let executable = try install(script(events, log: log), in: directory)
        let result = await CodexPingRunner(executable: executable, workingDirectory: directory,
                                           timeout: 5, archiveTimeout: 5).run()

        #expect(result.succeeded)
        #expect(result.threadID == "jkl-012")
    }

    @Test
    func testExecArgumentsAreStable() {
        let runner = CodexPingRunner(executable: URL(fileURLWithPath: "/usr/bin/true"),
                                     workingDirectory: URL(fileURLWithPath: "/tmp"))
        let arguments = runner.execArguments
        #expect(arguments.first == "exec")
        #expect(arguments.contains("--json"))
        #expect(arguments.contains("--ignore-user-config"))
        #expect(arguments.contains("read-only"))
        #expect(arguments.contains("--skip-git-repo-check"))
        #expect(arguments.contains("你好"))
        #expect(arguments.contains(where: { $0.contains("forced_login_method") }))
        #expect(arguments.contains("-C"))
    }
}

import Foundation
import Testing
@testable import QuotaCore

struct SessionUsageTests {
    // MARK: - Fixtures

    private func makeHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    private func meta(_ id: String, cwd: String = "/tmp/project", parent: String? = nil,
                      started: String = "2026-01-01T10:00:00.000Z") -> String {
        var payload: [String: Any] = [
            "id": id, "session_id": id, "cwd": cwd, "timestamp": started,
            "thread_source": parent == nil ? "user" : "subagent"
        ]
        if let parent {
            payload["source"] = ["subagent": ["thread_spawn": ["parent_thread_id": parent]]]
        }
        return json(["timestamp": started, "type": "session_meta", "payload": payload])
    }

    private func turn(_ turnID: String, model: String) -> String {
        json(["timestamp": "2026-01-01T10:00:01.000Z", "type": "turn_context",
              "payload": ["turn_id": turnID, "model": model]])
    }

    private func record(_ turnID: String, input: Int, cached: Int = 0, output: Int,
                        reasoning: Int = 0) -> String {
        let usage: [String: Any] = [
            "input_tokens": input, "cached_input_tokens": cached,
            "output_tokens": output, "reasoning_output_tokens": reasoning,
            "total_tokens": input + output
        ]
        return json(["timestamp": "2026-01-01T10:00:02.000Z", "type": "token_usage_record",
                     "payload": ["turn_id": turnID, "usage": usage, "thread_token_usage": usage]])
    }

    private func tokenCount(input: Int, output: Int) -> String {
        let usage: [String: Any] = [
            "input_tokens": input, "cached_input_tokens": 0, "output_tokens": output,
            "reasoning_output_tokens": 0, "total_tokens": input + output
        ]
        return json(["timestamp": "2026-01-01T10:00:03.000Z", "type": "event_msg",
                     "payload": ["type": "token_count", "info": ["total_token_usage": usage]]])
    }

    private func write(_ lines: [String], to url: URL, append: Bool = false) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let text = lines.map { $0 + "\n" }.joined()
        if append {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        } else {
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func sessionURL(home: URL, id: String, day: String = "2026/01/01") -> URL {
        home.appendingPathComponent("sessions").appendingPathComponent(day)
            .appendingPathComponent("rollout-2026-01-01T00-00-00-\(id).jsonl")
    }

    private func feed(_ lines: [String], into accumulator: inout RolloutAccumulator) {
        accumulator.consume(Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    // MARK: - Accumulator

    @Test
    func testSumsResponsesWithoutDoubleCountingCache() {
        var accumulator = RolloutAccumulator()
        feed([meta("A"), turn("t1", model: "gpt-a"),
              record("t1", input: 100, cached: 40, output: 20, reasoning: 5),
              record("t1", input: 50, output: 10)], into: &accumulator)
        #expect(accumulator.usage.input == 150)
        #expect(accumulator.usage.cachedInput == 40)
        #expect(accumulator.usage.output == 30)
        #expect(accumulator.usage.reasoning == 5)
        #expect(accumulator.usage.total == 180)
        #expect(accumulator.usage.cachedShare == 40.0 / 150.0)
        #expect(accumulator.models.map(\.model) == ["gpt-a"])
        #expect(accumulator.sessionID == "A")
    }

    @Test
    func testAttributesModelsPerTurnAndSortsByTotal() {
        var accumulator = RolloutAccumulator()
        feed([meta("A"), turn("t1", model: "gpt-a"), record("t1", input: 100, output: 10),
              turn("t2", model: "gpt-b"), record("t2", input: 200, output: 20)], into: &accumulator)
        #expect(accumulator.models.map(\.model) == ["gpt-b", "gpt-a"])
        #expect(accumulator.models.map(\.usage.total) == [220, 110])
        #expect(accumulator.usage.total == 330)
    }

    @Test
    func testUnknownTurnFallsBackToLatestModel() {
        var accumulator = RolloutAccumulator()
        feed([meta("A"), turn("t1", model: "gpt-a"), record("t-missing", input: 50, output: 5)],
             into: &accumulator)
        #expect(accumulator.models.map(\.model) == ["gpt-a"])
        #expect(accumulator.usage.total == 55)
    }

    @Test
    func testCumulativeFallbackWithoutUsageRecords() {
        var accumulator = RolloutAccumulator()
        feed([meta("A"), turn("t1", model: "gpt-a"), tokenCount(input: 1_000, output: 100)],
             into: &accumulator)
        #expect(accumulator.models.map(\.model) == ["gpt-a"])
        #expect(accumulator.usage.total == 1_100)
    }

    @Test
    func testPartialLineIsIgnoredUntilCompleted() {
        var accumulator = RolloutAccumulator()
        feed([meta("A"), turn("t1", model: "gpt-a")], into: &accumulator)
        accumulator.consume(Data(record("t1", input: 50, output: 5).utf8))
        #expect(accumulator.usage.total == 0)
        accumulator.consume(Data("\n".utf8))
        #expect(accumulator.usage.total == 55)
    }

    @Test
    func testMalformedRelevantLineIsSkipped() {
        var accumulator = RolloutAccumulator()
        feed([meta("A"), turn("t1", model: "gpt-a"),
              #"{"type":"token_usage_record","payload":{}}"#,
              record("t1", input: 10, output: 1)], into: &accumulator)
        #expect(accumulator.usage.total == 11)
        #expect(accumulator.skippedLines == 1)
    }

    @Test
    func testCompactFormatting() {
        #expect(TokenUsage.compact(999) == "999")
        #expect(TokenUsage.compact(12_300) == "12.3k")
        #expect(TokenUsage.compact(12_000) == "12k")
        #expect(TokenUsage.compact(1_200_000) == "1.2M")
        #expect(TokenUsage.compact(1_000_000_000) == "1B")
        #expect(TokenUsage(input: 10, output: 5).total == 15)
        #expect(TokenUsage(input: 10, output: 5, total: 3).total == 15)
    }

    // MARK: - Scanner

    @Test
    func testScannerReportsMessageWhenCodexHomeMissing() async {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let snapshot = await SessionUsageScanner(codexHome: home).refresh()
        #expect(snapshot.sessions.isEmpty)
        #expect(snapshot.message != nil)
    }

    @Test
    func testIncrementalAppendMatchesFullParse() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = sessionURL(home: home, id: "A")
        try write([meta("A"), turn("t1", model: "gpt-a"), record("t1", input: 100, output: 10)], to: file)

        let scanner = SessionUsageScanner(codexHome: home)
        let first = await scanner.refresh()
        #expect(first.sessions.count == 1)
        #expect(first.sessions[0].total.total == 110)

        try write([record("t1", input: 50, output: 5)], to: file, append: true)
        let second = await scanner.refresh()
        #expect(second.sessions[0].total.total == 165)

        let fresh = await SessionUsageScanner(codexHome: home).refresh()
        #expect(fresh.sessions[0].models == second.sessions[0].models)
    }

    @Test
    func testTruncatedFileIsParsedAgain() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = sessionURL(home: home, id: "A")
        try write([meta("A"), turn("t1", model: "gpt-a"),
                   record("t1", input: 100, output: 10), record("t1", input: 50, output: 5)], to: file)

        let scanner = SessionUsageScanner(codexHome: home)
        #expect(await scanner.refresh().sessions[0].total.total == 165)

        try write([meta("A"), turn("t1", model: "gpt-a"), record("t1", input: 10, output: 1)], to: file)
        #expect(await scanner.refresh().sessions[0].total.total == 11)
    }

    @Test
    func testSubagentThreadIsAggregatedIntoParent() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write([meta("P"), turn("t1", model: "gpt-a"), record("t1", input: 100, output: 10)],
                  to: sessionURL(home: home, id: "P"))
        try write([meta("C", parent: "P"), turn("t1", model: "gpt-a"), record("t1", input: 50, output: 5)],
                  to: sessionURL(home: home, id: "C"))

        let snapshot = await SessionUsageScanner(codexHome: home).refresh()
        #expect(snapshot.sessions.count == 1)
        #expect(snapshot.sessions[0].id == "P")
        #expect(snapshot.sessions[0].subagentCount == 1)
        #expect(snapshot.sessions[0].total.input == 150)
        #expect(snapshot.sessions[0].total.total == 165)
    }

    @Test
    func testTitleFromIndexAndFallbackLabel() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write([#"{"id":"A","thread_name":"测试会话","updated_at":"2026-01-01T10:00:00Z"}"#],
                  to: home.appendingPathComponent("session_index.jsonl"))
        try write([meta("A"), turn("t1", model: "gpt-a"), record("t1", input: 10, output: 1)],
                  to: sessionURL(home: home, id: "A"))
        try write([meta("B", cwd: "/tmp/另一个项目"), turn("t1", model: "gpt-a"),
                   record("t1", input: 10, output: 1)],
                  to: sessionURL(home: home, id: "B"))

        let snapshot = await SessionUsageScanner(codexHome: home).refresh()
        let titles = Dictionary(uniqueKeysWithValues: snapshot.sessions.map { ($0.id, $0.title) })
        #expect(titles["A"] == "测试会话")
        #expect(titles["B"]?.hasPrefix("另一个项目 · ") == true)
    }

    @Test
    func testSessionsAreOrderedByModificationDate() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let older = sessionURL(home: home, id: "A")
        let newer = sessionURL(home: home, id: "B")
        try write([meta("A"), turn("t1", model: "gpt-a"), record("t1", input: 10, output: 1)], to: older)
        try write([meta("B"), turn("t1", model: "gpt-a"), record("t1", input: 10, output: 1)], to: newer)
        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-600)],
                                              ofItemAtPath: older.path)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: newer.path)

        let snapshot = await SessionUsageScanner(codexHome: home).refresh()
        #expect(snapshot.sessions.map(\.id) == ["B", "A"])
    }
}

import Foundation
import Testing
@testable import QuotaCore

struct QuotaTests {
    private func window(_ used: Any, minutes: Int? = 300, reset: Double? = nil) -> [String: Any] {
        var value: [String: Any] = ["usedPercent": used]
        if let minutes { value["windowDurationMins"] = minutes }
        if let reset { value["resetsAt"] = reset }
        return value
    }

    @Test
    func testRealResponseAndRemainingInsteadOfUsed() throws {
        let snapshot = try QuotaSnapshot.parse(["rateLimitsByLimitId": ["codex": [
            "primary": window(39), "secondary": window(22, minutes: 10080), "planType": "plus"
        ]]])
        #expect(snapshot.windows.map(\.remaining) == [61, 78])
        #expect(snapshot.remaining == 61)
        #expect(snapshot.plan == "plus")
    }

    @Test
    func testWeeklyInPrimaryAndMonthlyDuration() throws {
        let snapshot = try QuotaSnapshot.parse(["rateLimits": [
            "primary": window(20, minutes: 10080), "secondary": window(10, minutes: 43200)
        ]])
        #expect(snapshot.windows.map(\.title) == ["每周额度", "30 天额度"])
    }

    @Test
    func testMapTakesPrecedenceOverLegacyAndKeepsModelBuckets() throws {
        let snapshot = try QuotaSnapshot.parse([
            "rateLimits": ["primary": window(99)],
            "rateLimitsByLimitId": [
                "codex": ["primary": window(10)],
                "spark": ["primary": window(60), "limitName": "Spark"]
            ]
        ])
        #expect(snapshot.windows.count == 2)
        #expect(snapshot.remaining == 40)
        #expect(snapshot.windows.last?.title == "Spark · 5 小时额度")
    }

    @Test
    func testMissingFieldsNeverBecomeFullQuota() {
        for payload: [String: Any] in [[:], ["rateLimits": NSNull()],
                                      ["rateLimits": ["primary": ["windowDurationMins": 300]]],
                                      ["rateLimits": ["primary": window(true)]],
                                      ["rateLimits": ["primary": window(Double.nan)]]
        ] { #expect(throws: (any Error).self) { try QuotaSnapshot.parse(payload) } }
    }

    @Test
    func testEmptyMapFallsBackToLegacy() throws {
        let snapshot = try QuotaSnapshot.parse(["rateLimitsByLimitId": [:], "rateLimits": ["primary": window(25)]])
        #expect(snapshot.remaining == 75)
    }

    @Test
    func testClampingAndZeroQuota() throws {
        let snapshot = try QuotaSnapshot.parse(["rateLimits": ["primary": window(120), "secondary": window(-5)]])
        #expect(snapshot.windows.map(\.remaining) == [0, 100])
    }

    @Test
    func testMissingDurationAndResetStayUnknown() throws {
        let snapshot = try QuotaSnapshot.parse(["rateLimits": ["primary": window(12.5, minutes: nil)]])
        #expect(snapshot.windows[0].remaining == 87.5)
        #expect(snapshot.windows[0].title.contains("未提供"))
        #expect(snapshot.windows[0].resetDescription() == "未提供重置时间")
    }

    @Test
    func testElapsedResetDoesNotInventNewQuota() throws {
        let now = Date(timeIntervalSince1970: 10000)
        let snapshot = try QuotaSnapshot.parse(["rateLimits": ["primary": window(100, reset: 9000)]], now: now)
        #expect(snapshot.remaining == 0)
        #expect(snapshot.windows[0].resetDescription(now: now) == "重置时间已到，等待服务确认")
    }

    @Test
    func testResetCountdown() throws {
        let now = Date(timeIntervalSince1970: 10000)
        let snapshot = try QuotaSnapshot.parse(["rateLimits": ["primary": window(20, reset: 13601)]])
        #expect(snapshot.windows[0].resetDescription(now: now) == "1小时 1分钟后重置")
    }

    @MainActor
    @Test
    func testRPCHandshakeAndFragmentedResponse() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = directory.appendingPathComponent("fake-codex")
        let script = #"""
        #!/usr/bin/python3
        import sys,json,time
        assert sys.argv[1:]==['app-server','--stdio']
        init=json.loads(sys.stdin.readline())
        assert init['method']=='initialize'
        print(json.dumps({'id':init['id'],'result':{}}),flush=True)
        assert json.loads(sys.stdin.readline())['method']=='initialized'
        request=json.loads(sys.stdin.readline())
        assert request['method']=='account/rateLimits/read'
        response=json.dumps({'id':request['id'],'result':{'rateLimits':{'primary':{'usedPercent':37,'windowDurationMins':10080}}}})+'\n'
        sys.stdout.write(response[:20]);sys.stdout.flush();time.sleep(0.05)
        sys.stdout.write(response[20:]);sys.stdout.flush()
        for line in sys.stdin: pass
        """#
        try script.write(to: server, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: server.path)
        let client = QuotaClient(executable: server)
        defer { client.stop() }
        let snapshot: QuotaSnapshot = try await withCheckedThrowingContinuation { continuation in
            client.onSnapshot = { snapshot in
                client.stop()
                continuation.resume(returning: snapshot)
            }
            client.onError = { _ in
                client.stop()
                continuation.resume(throwing: QuotaError.connection)
            }
            client.refresh()
            client.refresh() // Duplicate refreshes must not interrupt initialization.
        }
        #expect(snapshot.remaining == 63)
        #expect(snapshot.windows[0].title == "每周额度")
    }
}

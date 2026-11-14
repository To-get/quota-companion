import Foundation
import CoreFoundation

public struct RolloutSessionMeta: Equatable, Sendable {
    public var id: String?
    public var cwd: String?
    public var startedAt: Date?
    public var isSubagent: Bool
    public var parentID: String?
    public var originator: String?
    public var cliVersion: String?

    public init(id: String?, cwd: String?, startedAt: Date?, isSubagent: Bool,
                parentID: String?, originator: String?, cliVersion: String?) {
        self.id = id
        self.cwd = cwd
        self.startedAt = startedAt
        self.isSubagent = isSubagent
        self.parentID = parentID
        self.originator = originator
        self.cliVersion = cliVersion
    }
}

public enum RolloutEvent: Equatable, Sendable {
    case sessionMeta(RolloutSessionMeta)
    case turnContext(turnID: String, model: String)
    case tokenUsageRecord(turnID: String?, usage: TokenUsage)
    case cumulativeUsage(TokenUsage)
    case threadSettings(model: String)
}

/// Parses one JSONL line of a Codex rollout file.
///
/// Only lines that can carry session metadata, a model or a token counter are decoded.
/// Message bodies and tool payloads are skipped before `JSONSerialization` runs, which
/// keeps multi-megabyte base64 lines cheap.
public enum RolloutLine {
    static let needles: [Data] = ["session_meta", "turn_context", "token_usage_record", "token_count"]
        .map { Data($0.utf8) }

    public static func isRelevant(_ line: Data) -> Bool {
        needles.contains { line.range(of: $0) != nil }
    }

    public static func parse(_ line: Data) -> RolloutEvent? {
        guard isRelevant(line) else { return nil }
        return parseBody(line)
    }

    static func parseBody(_ line: Data) -> RolloutEvent? {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        switch type {
        case "session_meta":
            guard let payload = object["payload"] as? [String: Any] else { return nil }
            let source = payload["source"] as? [String: Any]
            let spawn = (source?["subagent"] as? [String: Any])?["thread_spawn"] as? [String: Any]
            return .sessionMeta(RolloutSessionMeta(
                id: payload["id"] as? String,
                cwd: payload["cwd"] as? String,
                startedAt: date(payload["timestamp"]),
                isSubagent: (payload["thread_source"] as? String) == "subagent",
                parentID: spawn?["parent_thread_id"] as? String,
                originator: payload["originator"] as? String,
                cliVersion: payload["cli_version"] as? String
            ))
        case "turn_context":
            guard let payload = object["payload"] as? [String: Any],
                  let model = payload["model"] as? String, !model.isEmpty else { return nil }
            return .turnContext(turnID: payload["turn_id"] as? String ?? "", model: model)
        case "token_usage_record":
            guard let payload = object["payload"] as? [String: Any] else { return nil }
            let turnID = payload["turn_id"] as? String
            if let usage = usage(payload["usage"]) {
                return .tokenUsageRecord(turnID: turnID, usage: usage)
            }
            if let cumulative = usage(payload["thread_token_usage"]) {
                return .cumulativeUsage(cumulative)
            }
            return nil
        case "event_msg":
            guard let payload = object["payload"] as? [String: Any] else { return nil }
            switch payload["type"] as? String {
            case "token_count":
                guard let info = payload["info"] as? [String: Any],
                      let cumulative = usage(info["total_token_usage"]) else { return nil }
                return .cumulativeUsage(cumulative)
            case "thread_settings_applied":
                guard let settings = payload["thread_settings"] as? [String: Any],
                      let model = settings["model"] as? String, !model.isEmpty else { return nil }
                return .threadSettings(model: model)
            default:
                return nil
            }
        default:
            return nil
        }
    }

    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return iso8601.date(from: text) ?? iso8601Plain.date(from: text)
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601Plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func int64(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite else { return nil }
        return Int64(double)
    }

    static func usage(_ value: Any?) -> TokenUsage? {
        guard let dictionary = value as? [String: Any] else { return nil }
        let known = ["input_tokens", "output_tokens", "total_tokens"]
        guard known.contains(where: { dictionary[$0] != nil }) else { return nil }
        return TokenUsage(
            input: int64(dictionary["input_tokens"]) ?? 0,
            cachedInput: int64(dictionary["cached_input_tokens"]) ?? 0,
            cacheWriteInput: int64(dictionary["cache_write_input_tokens"]) ?? 0,
            output: int64(dictionary["output_tokens"]) ?? 0,
            reasoning: int64(dictionary["reasoning_output_tokens"]) ?? 0,
            total: int64(dictionary["total_tokens"])
        )
    }
}

/// Incremental reader for one rollout file.
///
/// Callers feed appended bytes; the accumulator keeps the unparsed tail, attributes each
/// response to the model of its turn and sums the per-response usage records. A session
/// without usage records falls back to the last cumulative `token_count` snapshot.
public struct RolloutAccumulator: Equatable, Sendable {
    /// Token records are far smaller than this; longer lines are message or image payloads.
    public static let maximumLineBytes = 1 << 20

    public private(set) var offset: Int64 = 0
    public private(set) var skippedLines = 0
    public private(set) var sessionID: String?
    public private(set) var cwd: String?
    public private(set) var startedAt: Date?
    public private(set) var isSubagent = false
    public private(set) var parentID: String?
    public private(set) var sawUsageRecord = false

    private var partial = Data()
    private var usageByModel: [String: TokenUsage] = [:]
    private var turnModels: [String: String] = [:]
    private var currentModel: String?
    private var lastCumulative: TokenUsage?

    public init() {}

    public mutating func reset() {
        self = RolloutAccumulator()
    }

    public mutating func consume(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        offset += Int64(bytes.count)
        partial.append(bytes)
        var lineStart = partial.startIndex
        var scan = partial.startIndex
        while scan < partial.endIndex {
            guard partial[scan] == 0x0A else {
                scan = partial.index(after: scan)
                continue
            }
            let length = partial.distance(from: lineStart, to: scan)
            if length > 0 {
                if length <= Self.maximumLineBytes {
                    ingest(Data(partial[lineStart..<scan]))
                } else {
                    skippedLines += 1
                }
            }
            scan = partial.index(after: scan)
            lineStart = scan
        }
        if lineStart > partial.startIndex {
            partial.removeSubrange(partial.startIndex..<lineStart)
        }
        if partial.count > Self.maximumLineBytes {
            partial.removeAll()
            skippedLines += 1
        }
    }

    /// Per-model totals, highest first. Empty until the first response is recorded.
    public var models: [ModelUsage] {
        if sawUsageRecord {
            return usageByModel
                .map { ModelUsage(model: $0.key, usage: $0.value) }
                .sorted { lhs, rhs in
                    lhs.usage.total == rhs.usage.total ? lhs.model < rhs.model : lhs.usage.total > rhs.usage.total
                }
        }
        guard let lastCumulative else { return [] }
        return [ModelUsage(model: currentModel ?? "未知模型", usage: lastCumulative)]
    }

    public var usage: TokenUsage { models.reduce(.zero) { $0 + $1.usage } }

    private mutating func ingest(_ line: Data) {
        guard RolloutLine.isRelevant(line) else { return }
        guard let event = RolloutLine.parseBody(line) else {
            skippedLines += 1
            return
        }
        apply(event)
    }

    private mutating func apply(_ event: RolloutEvent) {
        switch event {
        case let .sessionMeta(meta):
            if sessionID == nil { sessionID = meta.id }
            if cwd == nil { cwd = meta.cwd }
            if startedAt == nil { startedAt = meta.startedAt }
            if isSubagent == false { isSubagent = meta.isSubagent }
            if parentID == nil { parentID = meta.parentID }
        case let .turnContext(turnID, model):
            if !turnID.isEmpty { turnModels[turnID] = model }
            currentModel = model
        case let .tokenUsageRecord(turnID, usage):
            let model = turnID.flatMap { turnModels[$0] } ?? currentModel ?? "未知模型"
            usageByModel[model, default: .zero] = usageByModel[model, default: .zero] + usage
            sawUsageRecord = true
        case let .cumulativeUsage(usage):
            lastCumulative = usage
        case let .threadSettings(model):
            if currentModel == nil { currentModel = model }
        }
    }
}

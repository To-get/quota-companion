import Foundation

/// Token counters for one model in one session, as reported by the Codex service.
///
/// The server counts `cachedInput` inside `input` and `reasoning` inside `output`,
/// so neither may be added to `total` a second time. `total` is never smaller than
/// `input + output`, and falls back to it when the server did not provide one.
public struct TokenUsage: Equatable, Sendable {
    public var input: Int64
    public var cachedInput: Int64
    public var cacheWriteInput: Int64
    public var output: Int64
    public var reasoning: Int64
    public var total: Int64

    public init(input: Int64 = 0, cachedInput: Int64 = 0, cacheWriteInput: Int64 = 0,
                output: Int64 = 0, reasoning: Int64 = 0, total: Int64? = nil) {
        let input = max(0, input)
        let cachedInput = max(0, cachedInput)
        let cacheWriteInput = max(0, cacheWriteInput)
        let output = max(0, output)
        let reasoning = max(0, reasoning)
        self.input = input
        self.cachedInput = cachedInput
        self.cacheWriteInput = cacheWriteInput
        self.output = output
        self.reasoning = reasoning
        self.total = max(total ?? 0, input + output)
    }

    public static let zero = TokenUsage()

    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(input: lhs.input + rhs.input,
                   cachedInput: lhs.cachedInput + rhs.cachedInput,
                   cacheWriteInput: lhs.cacheWriteInput + rhs.cacheWriteInput,
                   output: lhs.output + rhs.output,
                   reasoning: lhs.reasoning + rhs.reasoning,
                   total: lhs.total + rhs.total)
    }

    public var isEmpty: Bool { total == 0 && input == 0 && output == 0 }

    /// Share of the input that was served from cache, in `0...1`.
    public var cachedShare: Double {
        guard input > 0 else { return 0 }
        return min(1, Double(cachedInput) / Double(input))
    }

    /// `12.3k` / `1.2M`, with trailing zeros trimmed for a compact panel.
    public static func compact(_ value: Int64) -> String {
        let magnitude = abs(Double(value))
        let scaled: Double
        let suffix: String
        let digits: Int
        switch magnitude {
        case ..<1_000:
            return value.formatted()
        case ..<1_000_000:
            scaled = Double(value) / 1_000
            suffix = "k"
            digits = 1
        case ..<1_000_000_000:
            scaled = Double(value) / 1_000_000
            suffix = "M"
            digits = 2
        default:
            scaled = Double(value) / 1_000_000_000
            suffix = "B"
            digits = 2
        }
        var text = String(format: "%.\(digits)f", scaled)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text + suffix
    }

    public var compactTotal: String { Self.compact(total) }
}

public struct ModelUsage: Equatable, Identifiable, Sendable {
    public let model: String
    public var usage: TokenUsage

    public var id: String { model }

    public init(model: String, usage: TokenUsage) {
        self.model = model
        self.usage = usage
    }
}

/// One session as shown in the panel: a user thread plus every sub-agent thread it spawned.
public struct SessionUsage: Equatable, Identifiable, Sendable {
    public let id: String
    public var title: String
    public var cwd: String?
    public var updatedAt: Date
    public var isSubagent: Bool
    public var models: [ModelUsage]
    public var subagentCount: Int

    public init(id: String, title: String, cwd: String?, updatedAt: Date,
                isSubagent: Bool, models: [ModelUsage], subagentCount: Int) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.updatedAt = updatedAt
        self.isSubagent = isSubagent
        self.models = models
        self.subagentCount = subagentCount
    }

    public var total: TokenUsage { models.reduce(.zero) { $0 + $1.usage } }

    public var usesMultipleModels: Bool { models.count > 1 }

    public var modelNames: [String] { models.map(\.model) }
}

public struct SessionUsageSnapshot: Equatable, Sendable {
    public var sessions: [SessionUsage]
    public var scannedAt: Date
    public var archivedCount: Int
    public var codexHome: URL
    /// Explains why no session could be listed; `nil` when the scan succeeded.
    public var message: String?

    public init(sessions: [SessionUsage], scannedAt: Date, archivedCount: Int,
                codexHome: URL, message: String?) {
        self.sessions = sessions
        self.scannedAt = scannedAt
        self.archivedCount = archivedCount
        self.codexHome = codexHome
        self.message = message
    }
}

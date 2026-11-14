import Foundation

/// Builds session token totals from the local Codex rollout files.
///
/// The scanner never reads the service over the network: it lists
/// `<CODEX_HOME>/sessions/**/rollout-*.jsonl`, reads each file's first `session_meta`
/// line and appends only the new bytes of the files it has already seen.
public actor SessionUsageScanner {
    public struct Limits: Sendable {
        public var recentLimit: Int
        public var maximumIndexedFiles: Int
        public var firstLineBytes: Int
        public var chunkBytes: Int

        public init(recentLimit: Int = 10, maximumIndexedFiles: Int = 200,
                    firstLineBytes: Int = 65_536, chunkBytes: Int = 262_144) {
            self.recentLimit = recentLimit
            self.maximumIndexedFiles = maximumIndexedFiles
            self.firstLineBytes = firstLineBytes
            self.chunkBytes = chunkBytes
        }
    }

    private struct FileRecord {
        var url: URL
        var id: String
        var isSubagent: Bool
        var parentID: String?
        var cwd: String?
        var startedAt: Date?
        var modified: Date
        var size: Int64
        var accumulator: RolloutAccumulator?
    }

    public static var defaultCodexHome: URL {
        if let custom = ProcessInfo.processInfo.environment["CODEX_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    }

    private static let fileKeys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]

    private static let fallbackFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    private let codexHome: URL
    private let limits: Limits
    private var records: [String: FileRecord] = [:]
    private var titles: [String: String] = [:]
    private var titleStamp: Date?

    public init(codexHome: URL = SessionUsageScanner.defaultCodexHome, limits: Limits = Limits()) {
        self.codexHome = codexHome
        self.limits = limits
    }

    /// Rescans the index and reads whatever was appended since the previous call.
    public func refresh() -> SessionUsageSnapshot {
        refreshIndex()
        let all = records.values.sorted { lhs, rhs in
            lhs.modified == rhs.modified ? lhs.id < rhs.id : lhs.modified > rhs.modified
        }
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var sessions: [SessionUsage] = []
        for parent in all.filter({ !$0.isSubagent }).prefix(max(1, limits.recentLimit)) {
            let children = all.filter { $0.parentID == parent.id && $0.id != parent.id }
            sessions.append(makeSession(parent: parent, children: children, forceSubagent: false))
        }
        let orphans = all.filter { record in
            guard record.isSubagent else { return false }
            guard let parentID = record.parentID else { return true }
            return byID[parentID] == nil
        }
        for orphan in orphans.prefix(limits.recentLimit) {
            sessions.append(makeSession(parent: orphan, children: [], forceSubagent: true))
        }
        sessions.sort { lhs, rhs in
            lhs.updatedAt == rhs.updatedAt ? lhs.title < rhs.title : lhs.updatedAt > rhs.updatedAt
        }
        return SessionUsageSnapshot(sessions: sessions, scannedAt: Date(),
                                    archivedCount: archivedCount(), codexHome: codexHome,
                                    message: statusMessage())
    }

    private func makeSession(parent: FileRecord, children: [FileRecord], forceSubagent: Bool) -> SessionUsage {
        var usageByModel: [String: TokenUsage] = [:]
        var updatedAt = parent.modified
        var group = [parent]
        group.append(contentsOf: children)
        for var record in group {
            readAppended(into: &record)
            records[record.url.path] = record
            updatedAt = max(updatedAt, record.modified)
            for model in record.accumulator?.models ?? [] {
                usageByModel[model.model, default: .zero] = usageByModel[model.model, default: .zero] + model.usage
            }
        }
        let models = usageByModel
            .map { ModelUsage(model: $0.key, usage: $0.value) }
            .sorted { lhs, rhs in
                lhs.usage.total == rhs.usage.total ? lhs.model < rhs.model : lhs.usage.total > rhs.usage.total
            }
        return SessionUsage(id: parent.id, title: title(for: parent), cwd: parent.cwd,
                            updatedAt: updatedAt, isSubagent: forceSubagent || parent.isSubagent,
                            models: models, subagentCount: children.count)
    }

    private func refreshIndex() {
        refreshTitles()
        let sessionsDirectory = codexHome.appendingPathComponent("sessions", isDirectory: true)
        var found: [String: (url: URL, modified: Date, size: Int64)] = [:]
        if let enumerator = FileManager.default.enumerator(at: sessionsDirectory,
                                                          includingPropertiesForKeys: Array(Self.fileKeys),
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let url as URL in enumerator {
                guard url.lastPathComponent.hasPrefix("rollout-"), url.pathExtension == "jsonl",
                      let values = try? url.resourceValues(forKeys: Self.fileKeys),
                      values.isRegularFile == true else { continue }
                found[url.path] = (url, values.contentModificationDate ?? .distantPast,
                                   Int64(values.fileSize ?? 0))
            }
        }
        let ordered = found.sorted { lhs, rhs in
            lhs.value.modified == rhs.value.modified ? lhs.key < rhs.key : lhs.value.modified > rhs.value.modified
        }.prefix(limits.maximumIndexedFiles)
        var next: [String: FileRecord] = [:]
        for (path, entry) in ordered {
            if var existing = records[path] {
                existing.modified = entry.modified
                existing.size = entry.size
                if entry.size < (existing.accumulator?.offset ?? 0) {
                    // The file was truncated or replaced: parse it again from the start.
                    existing.accumulator = nil
                }
                next[path] = existing
            } else {
                var record = FileRecord(url: entry.url, id: Self.identifier(from: entry.url),
                                        isSubagent: false, parentID: nil, cwd: nil, startedAt: nil,
                                        modified: entry.modified, size: entry.size, accumulator: nil)
                if let meta = readMeta(entry.url) {
                    if let id = meta.id, !id.isEmpty { record.id = id }
                    record.isSubagent = meta.isSubagent
                    record.parentID = meta.parentID
                    record.cwd = meta.cwd
                    record.startedAt = meta.startedAt
                }
                next[path] = record
            }
        }
        records = next
    }

    private func readMeta(_ url: URL) -> RolloutSessionMeta? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: limits.firstLineBytes),
              let newline = prefix.firstIndex(of: 0x0A) else { return nil }
        guard case let .sessionMeta(meta)? = RolloutLine.parse(Data(prefix[..<newline])) else { return nil }
        return meta
    }

    private func readAppended(into record: inout FileRecord) {
        if record.accumulator == nil { record.accumulator = RolloutAccumulator() }
        guard var accumulator = record.accumulator, accumulator.offset < record.size,
              let handle = try? FileHandle(forReadingFrom: record.url) else { return }
        defer { try? handle.close() }
        if accumulator.offset > 0 { try? handle.seek(toOffset: UInt64(accumulator.offset)) }
        while let chunk = try? handle.read(upToCount: limits.chunkBytes) {
            guard !chunk.isEmpty else { break }
            accumulator.consume(chunk)
        }
        record.accumulator = accumulator
    }

    private func refreshTitles() {
        let url = codexHome.appendingPathComponent("session_index.jsonl")
        let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if stamp == titleStamp, stamp != nil { return }
        titleStamp = stamp
        guard let data = try? Data(contentsOf: url) else {
            titles.removeAll()
            return
        }
        var map: [String: String] = [:]
        for line in data.split(separator: 0x0A) {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let id = object["id"] as? String,
                  let name = object["thread_name"] as? String, !name.isEmpty else { continue }
            map[id] = name
        }
        titles = map
    }

    private func title(for record: FileRecord) -> String {
        if let name = titles[record.id], !name.isEmpty { return name }
        let folder = record.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        let name = folder.isEmpty ? "未命名会话" : folder
        let date = record.startedAt ?? record.modified
        return "\(name) · \(Self.fallbackFormatter.string(from: date))"
    }

    private func archivedCount() -> Int {
        let directory = codexHome.appendingPathComponent("archived_sessions", isDirectory: true)
        guard let items = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                       includingPropertiesForKeys: nil) else { return 0 }
        return items.filter { $0.lastPathComponent.hasPrefix("rollout-") }.count
    }

    private func statusMessage() -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: codexHome.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return "未找到 Codex 目录：\(codexHome.path)"
        }
        guard !records.isEmpty else { return "未找到本地 Codex 会话记录" }
        return nil
    }

    static func identifier(from url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        if name.hasPrefix("rollout-") { name.removeFirst("rollout-".count) }
        let parts = name.split(separator: "-")
        guard parts.count >= 5 else { return url.lastPathComponent }
        return parts.suffix(5).joined(separator: "-")
    }
}

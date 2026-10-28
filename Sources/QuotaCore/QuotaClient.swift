import Foundation

/// Speaks only initialize, initialized and account/rateLimits/read. Never starts a model turn.
@MainActor
public final class QuotaClient {
    public var onSnapshot: ((QuotaSnapshot) -> Void)?
    public var onError: ((String) -> Void)?
    public var onAccountChanged: (() -> Void)?
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var buffer = Data()
    private var generation = UUID()
    private var initialized = false
    private var pendingID: Int?
    private var nextID = 1
    private var lastRead = Date.distantPast
    private var deadline: Timer?
    private let executable: URL

    public init(executable: URL) { self.executable = executable }

    public static func bundledExecutable(appURL: URL) -> URL? {
        ["Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex", "Contents/Resources/codex"]
            .map { appURL.appendingPathComponent($0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public func refresh() {
        guard pendingID == nil else { return }
        if process == nil { start() }
        else if initialized { requestQuota() }
    }

    public func stop() {
        generation = UUID()
        deadline?.invalidate()
        deadline = nil
        output?.fileHandleForReading.readabilityHandler = nil
        try? input?.fileHandleForWriting.close()
        let old = process
        old?.terminationHandler = nil
        if let old, old.isRunning {
            old.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if old.isRunning { kill(old.processIdentifier, SIGKILL) }
            }
        }
        process = nil
        input = nil
        output = nil
        initialized = false
        pendingID = nil
        buffer.removeAll()
    }

    private func start() {
        let child = Process()
        let stdin = Pipe(), stdout = Pipe()
        child.executableURL = executable
        child.arguments = ["app-server", "--stdio"]
        child.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        // The bundled service owns authentication. This app never reads or copies its tokens.
        let token = generation
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.receive(bytes)
            }
        }
        child.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.fail(.connection)
            }
        }
        process = child
        input = stdin
        output = stdout
        do { try child.run() }
        catch { fail(.missingApp); return }
        pendingID = 0
        armDeadline()
        send(["id": 0, "method": "initialize", "params": ["clientInfo": [
            "name": "quota_companion", "title": "Quota Companion", "version": "1.0.0"
        ]]])
    }

    private func send(_ value: [String: Any]) {
        guard let input, var data = try? JSONSerialization.data(withJSONObject: value) else { return }
        data.append(0x0A)
        do { try input.fileHandleForWriting.write(contentsOf: data) }
        catch { fail(.connection) }
    }

    private func requestQuota() {
        let id = nextID
        nextID += 1
        pendingID = id
        lastRead = Date()
        armDeadline()
        send(["id": id, "method": "account/rateLimits/read", "params": [:]])
    }

    private func armDeadline() {
        deadline?.invalidate()
        deadline = Timer.scheduledTimer(withTimeInterval: 25, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.fail(.timeout) }
        }
    }

    private func receive(_ bytes: Data) {
        guard !bytes.isEmpty else { fail(.connection); return }
        buffer.append(bytes)
        guard buffer.count <= 2_000_000 else { fail(.server); return }
        while let end = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<end])
            buffer.removeSubrange(...end)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            handle(object)
        }
    }

    private func handle(_ message: [String: Any]) {
        if let id = message["id"] as? Int, id == pendingID {
            deadline?.invalidate()
            pendingID = nil
            if let error = message["error"] as? [String: Any] {
                let text = (error["message"] as? String ?? "").lowercased()
                fail(text.contains("auth") || text.contains("login") ? .signedOut : .server)
                return
            }
            guard let result = message["result"] as? [String: Any] else { fail(.server); return }
            if id == 0 {
                initialized = true
                send(["method": "initialized", "params": [:]])
                requestQuota()
            } else { publish(result) }
        } else if let method = message["method"] as? String {
            if method == "account/rateLimits/updated" {
                // Notifications can omit the multi-bucket view. Re-read it to avoid losing other limits.
                if initialized && pendingID == nil && Date().timeIntervalSince(lastRead) >= 5 { requestQuota() }
            } else if method == "account/updated" {
                onAccountChanged?()
                if initialized && pendingID == nil { requestQuota() }
            }
        }
    }

    private func publish(_ value: [String: Any]) {
        do { onSnapshot?(try QuotaSnapshot.parse(value)) }
        catch { onError?(QuotaError.noQuota.localizedDescription) }
    }

    private func fail(_ error: QuotaError) {
        stop()
        onError?(error.localizedDescription)
    }
}

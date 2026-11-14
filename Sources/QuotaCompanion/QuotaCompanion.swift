import AppKit
import SwiftUI
import ServiceManagement
import QuotaCore

@MainActor
final class Monitor: ObservableObject {
    @Published var snapshot: QuotaSnapshot?
    @Published var error: String?
    @Published var loading = false
    @Published var chatGPTRunning = false
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    private var client: QuotaClient?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    var onChange: (() -> Void)?
    var onSnapshot: ((QuotaSnapshot) -> Void)?
    /// Keeps the quota client alive after ChatGPT quits so the automation can still run.
    private(set) var keepsRunningWithoutChatGPT = false

    var statusTitle: String {
        guard let snapshot, let remaining = snapshot.remaining,
              Date().timeIntervalSince(snapshot.receivedAt) < 120 else { return "GPT —" }
        return String(format: "GPT %.0f%%", remaining)
    }

    var fresh: Bool {
        guard let snapshot else { return false }
        return Date().timeIntervalSince(snapshot.receivedAt) < 120
    }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification, NSWorkspace.didWakeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                Task { @MainActor in
                    guard let self else { return }
                    let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                    let relevant = app.map { Self.isChatGPT($0.bundleIdentifier) } ?? true
                    if relevant { self.checkApplication(refresh: true) }
                }
            })
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkApplication(refresh: true) }
        }
        checkApplication(refresh: true)
    }

    private static func isChatGPT(_ bundle: String?) -> Bool {
        ["com.openai.codex", "com.openai.chat"].contains(bundle ?? "")
    }

    private func checkApplication(refresh: Bool) {
        chatGPTRunning = NSWorkspace.shared.runningApplications.contains { Self.isChatGPT($0.bundleIdentifier) }
        if !chatGPTRunning && !keepsRunningWithoutChatGPT {
            client?.stop()
            client = nil
            snapshot = nil
            error = nil
            loading = false
        } else if refresh { self.refresh() }
        onChange?()
    }

    func refresh() {
        guard chatGPTRunning || keepsRunningWithoutChatGPT else { return }
        if client == nil {
            let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")
                ?? URL(fileURLWithPath: "/Applications/ChatGPT.app")
            guard let binary = QuotaClient.bundledExecutable(appURL: appURL) else {
                error = QuotaError.missingApp.localizedDescription
                snapshot = nil
                onChange?()
                return
            }
            let client = QuotaClient(executable: binary)
            client.onSnapshot = { [weak self] snapshot in
                self?.snapshot = snapshot
                self?.error = nil
                self?.loading = false
                self?.onSnapshot?(snapshot)
                self?.onChange?()
            }
            client.onError = { [weak self] error in
                self?.error = error
                self?.snapshot = nil
                self?.loading = false
                self?.onChange?()
            }
            client.onAccountChanged = { [weak self] in
                self?.snapshot = nil
                self?.onChange?()
            }
            self.client = client
        }
        loading = true
        error = nil
        client?.refresh()
        onChange?()
    }

    func setKeepsRunning(_ value: Bool) {
        guard keepsRunningWithoutChatGPT != value else { return }
        keepsRunningWithoutChatGPT = value
        checkApplication(refresh: true)
    }

    func setLoginEnabled(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            if enabled && !loginEnabled {
                error = "请到系统设置 → 通用 → 登录项中允许额度助手启动。"
            }
        } catch {
            loginEnabled = SMAppService.mainApp.status == .enabled
            self.error = "无法修改登录项。请先将额度助手放入“应用程序”文件夹。"
        }
    }

    func stop() {
        timer?.invalidate()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        client?.stop()
    }
}

struct QuotaPanel: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var sessionMonitor: SessionUsageMonitor
    @ObservedObject var automation: QuotaAutomationController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            quotaSection
            Divider()
            SessionUsageSection(monitor: sessionMonitor)
            Divider()
            AutomationSection(automation: automation)
            Divider()
            footer
        }
        .padding(20)
        .frame(width: 420)
    }

    private var header: some View {
        HStack {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.title2).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("ChatGPT 额度").font(.headline)
                Text("Work / Codex 共用额度").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let plan = monitor.snapshot?.plan { Text(plan.capitalized).font(.caption).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder
    private var quotaSection: some View {
        if let snapshot = monitor.snapshot {
            if !monitor.fresh {
                Label("数据已过期，等待刷新", systemImage: "clock.badge.exclamationmark")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(snapshot.windows) { window in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(window.title).font(.callout)
                        Spacer()
                        Text("剩余 \(window.percentage)").font(.system(.body, design: .rounded).weight(.semibold))
                            .monospacedDigit()
                    }
                    ProgressView(value: window.remaining, total: 100)
                        .tint(window.remaining <= 10 ? .red : .accentColor)
                        .accessibilityLabel("\(window.title)，剩余 \(window.percentage)")
                    HStack {
                        Text(window.resetDescription())
                        if let reset = window.resetsAt {
                            Spacer()
                            Text(reset, format: .dateTime.month().day().hour().minute())
                        }
                    }.font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("更新于 \(snapshot.receivedAt.formatted(date: .omitted, time: .standard)) · 每 60 秒刷新")
                .font(.caption).foregroundStyle(.secondary)
        } else if monitor.loading {
            HStack { ProgressView().controlSize(.small); Text("正在读取真实额度…").font(.callout) }
        } else if monitor.error == nil {
            Text("等待 ChatGPT 启动").font(.callout).foregroundStyle(.secondary)
        }
        if let error = monitor.error {
            Label(error, systemImage: "exclamationmark.circle")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("登录 macOS 时启动", isOn: Binding(
                get: { monitor.loginEnabled }, set: { monitor.setLoginEnabled($0) }
            )).toggleStyle(.checkbox).font(.callout)
            HStack {
                Button("刷新", systemImage: "arrow.clockwise") {
                    monitor.refresh()
                    sessionMonitor.refresh()
                }
                .keyboardShortcut("r", modifiers: .command)
                Spacer()
                Button("退出助手") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            }
        }
    }
}

struct SessionUsageSection: View {
    @ObservedObject var monitor: SessionUsageMonitor

    private var selection: Binding<String?> {
        Binding(get: { monitor.followLatest ? nil : monitor.selectedID },
                set: { monitor.select($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("会话 Token 用量").font(.subheadline).fontWeight(.semibold)
                Spacer()
                if !monitor.sessions.isEmpty {
                    Picker("会话", selection: selection) {
                        Text("自动跟随最新").tag(String?.none)
                        ForEach(monitor.sessions) { session in
                            Text(session.title).tag(String?.some(session.id))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(width: 200)
                }
            }
            if let summary = monitor.summary {
                summaryView(summary)
            } else if let message = monitor.message {
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack { ProgressView().controlSize(.small); Text("正在统计会话…").font(.callout) }
            }
        }
    }

    @ViewBuilder
    private func summaryView(_ summary: SessionUsage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(summary.title).font(.callout).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(summary.total.compactTotal)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .accessibilityLabel("本会话共 \(summary.total.total.formatted()) tokens")
            }
            if summary.total.isEmpty {
                Text("尚无 token 记录，等待首次响应").font(.caption).foregroundStyle(.secondary)
            } else {
                Text(detailLine(summary.total))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                ForEach(summary.models) { model in
                    modelRow(model, total: summary.total.total)
                }
                if summary.usesMultipleModels {
                    Text("按模型拆分，共 \(summary.models.count) 个模型")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            HStack {
                if summary.subagentCount > 0 {
                    Text("含 \(summary.subagentCount) 个子代理会话")
                }
                Spacer()
                if let updated = monitor.lastUpdated {
                    Text("更新于 \(updated.formatted(date: .omitted, time: .standard))")
                }
            }.font(.caption2).foregroundStyle(.secondary)
            if monitor.archivedCount > 0 {
                Text("另有 \(monitor.archivedCount) 个已归档会话未统计")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func detailLine(_ usage: TokenUsage) -> String {
        "输入 \(TokenUsage.compact(usage.input))（缓存 \(TokenUsage.compact(usage.cachedInput))） · 输出 \(TokenUsage.compact(usage.output)) · 推理 \(TokenUsage.compact(usage.reasoning))"
    }

    private func modelRow(_ model: ModelUsage, total: Int64) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(model.model).font(.caption).lineLimit(1)
                Spacer()
                Text(TokenUsage.compact(model.usage.total)).font(.caption).monospacedDigit()
                Text(share(model.usage.total, of: total)).font(.caption2)
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            ProgressView(value: shareValue(model.usage.total, of: total))
                .controlSize(.mini)
                .tint(.accentColor)
                .accessibilityLabel("\(model.model)，\(model.usage.total.formatted()) tokens")
        }
    }

    private func shareValue(_ value: Int64, of total: Int64) -> Double {
        guard total > 0 else { return 0 }
        return Double(value) / Double(total)
    }

    private func share(_ value: Int64, of total: Int64) -> String {
        String(format: "%.0f%%", shareValue(value, of: total) * 100)
    }
}

@MainActor
enum CodexExecutable {
    static func locate() -> URL? {
        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")
            ?? URL(fileURLWithPath: "/Applications/ChatGPT.app")
        return QuotaClient.bundledExecutable(appURL: appURL)
    }
}

struct AutomationSection: View {
    @ObservedObject var automation: QuotaAutomationController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("自动固定刷新时间").font(.subheadline).fontWeight(.semibold)
                Spacer()
                if automation.isRunning {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("发送中…").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Toggle("窗口空出时自动发「你好」", isOn: Binding(
                get: { automation.enabled }, set: { automation.setEnabled($0) }
            )).toggleStyle(.checkbox).font(.callout)
            Text("仅 5 小时/每周额度；每次约 1–3 万 token；发送后归档该会话。")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let outcome = automation.lastOutcome, !automation.isRunning {
                Text(outcomeLine(outcome)).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func outcomeLine(_ outcome: String) -> String {
        guard let date = automation.lastOutcomeAt else { return "上次：\(outcome)" }
        return "上次 \(date.formatted(date: .omitted, time: .shortened))：\(outcome)"
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let monitor = Monitor()
    let sessionMonitor = SessionUsageMonitor()
    let automation = QuotaAutomationController(executableProvider: { CodexExecutable.locate() })
    private var item: NSStatusItem!
    private let popover = NSPopover()
    private var checkClient: QuotaClient?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--check") { checkConnection(); return }
        if CommandLine.arguments.contains("--sessions") { dumpSessions(); return }
        if CommandLine.arguments.contains("--ping") { pingOnce(); return }
        let duplicates = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !duplicates.isEmpty { NSApplication.shared.terminate(nil); return }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        item.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: QuotaPanel(monitor: monitor, sessionMonitor: sessionMonitor, automation: automation)
        )
        monitor.onChange = { [weak self] in self?.updateItem() }
        sessionMonitor.onChange = { [weak self] in self?.updateItem() }
        automation.onChange = { [weak self] in self?.updateItem() }
        monitor.onSnapshot = { [weak self] snapshot in self?.automation.handle(snapshot) }
        automation.onRefreshNeeded = { [weak self] in self?.monitor.refresh() }
        automation.onEnabledChanged = { [weak self] enabled in self?.monitor.setKeepsRunning(enabled) }
        monitor.start()
        sessionMonitor.start()
        monitor.setKeepsRunning(automation.enabled)
    }

    private func updateItem() {
        let visible = monitor.chatGPTRunning || sessionMonitor.hasRecentActivity || automation.enabled
        item.isVisible = visible
        item.button?.title = monitor.statusTitle
        var description = "Work / Codex 最低剩余额度：\(monitor.statusTitle)。"
        if let summary = sessionMonitor.summary, !summary.total.isEmpty {
            description += "当前会话 \(summary.total.total.formatted()) tokens"
            if !summary.modelNames.isEmpty {
                description += "（\(summary.modelNames.joined(separator: "、"))）"
            }
            description += "。"
        }
        description += "点击查看所有窗口。"
        item.button?.toolTip = description
        item.button?.setAccessibilityLabel(description)
        if !visible { popover.performClose(nil) }
    }

    @objc private func togglePanel() {
        guard let button = item.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            monitor.refresh()
            sessionMonitor.refresh()
            sessionMonitor.setFastPolling(true)
            NSApplication.shared.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func pingOnce() {
        guard let executable = CodexExecutable.locate() else {
            print("找不到 ChatGPT 内置的 Codex 服务，请更新桌面端。")
            exit(1)
        }
        let directory = QuotaAutomationController.defaultWorkingDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let runner = CodexPingRunner(executable: executable, workingDirectory: directory)
        Task {
            let result = await runner.run()
            if let threadID = result.threadID { print("会话：\(threadID)") }
            if let usage = result.usage {
                print("用量：\(usage.total.formatted()) tokens（输入 \(usage.input.formatted()) / 缓存 \(usage.cachedInput.formatted()) / 输出 \(usage.output.formatted()) / 推理 \(usage.reasoning.formatted())）")
            }
            print(result.succeeded ? "发送成功" : "发送失败：\(result.errorDescription ?? "未知错误")")
            print(result.archived ? "已归档" : (result.warning ?? "未归档"))
            exit(result.succeeded ? 0 : 1)
        }
    }

    private func dumpSessions() {
        let scanner = SessionUsageScanner()
        Task {
            let snapshot = await scanner.refresh()
            print("Codex 目录：\(snapshot.codexHome.path)")
            if let message = snapshot.message { print(message) }
            for session in snapshot.sessions {
                let time = session.updatedAt.formatted(date: .numeric, time: .shortened)
                var heading = "■ \(session.title)（\(session.id)） 更新于 \(time)"
                if session.subagentCount > 0 { heading += "，含 \(session.subagentCount) 个子代理会话" }
                print(heading)
                let usage = session.total
                print("  总计 \(usage.total.formatted()) tokens（输入 \(usage.input.formatted()) / 缓存 \(usage.cachedInput.formatted()) / 输出 \(usage.output.formatted()) / 推理 \(usage.reasoning.formatted())）")
                for model in session.models {
                    print("  · \(model.model)：\(model.usage.total.formatted()) tokens（输入 \(model.usage.input.formatted()) / 输出 \(model.usage.output.formatted())）")
                }
            }
            if snapshot.archivedCount > 0 {
                print("另有 \(snapshot.archivedCount) 个已归档会话未统计。")
            }
            exit(snapshot.message == nil ? 0 : 1)
        }
    }

    private func checkConnection() {
        let app = URL(fileURLWithPath: "/Applications/ChatGPT.app")
        guard let binary = QuotaClient.bundledExecutable(appURL: app) else {
            print(QuotaError.missingApp.localizedDescription); exit(1)
        }
        let client = QuotaClient(executable: binary)
        checkClient = client
        client.onSnapshot = { snapshot in
            for window in snapshot.windows { print("\(window.title)：剩余 \(window.percentage)；\(window.resetDescription())") }
            client.stop()
            exit(0)
        }
        client.onError = { error in print(error); client.stop(); exit(1) }
        client.refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
        sessionMonitor.stop()
        automation.stop()
        checkClient?.stop()
    }
}

extension AppDelegate: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        sessionMonitor.setFastPolling(false)
    }
}

@main
struct QuotaCompanion {
    @MainActor static func main() {
        signal(SIGPIPE, SIG_IGN)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

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
        if !chatGPTRunning {
            client?.stop()
            client = nil
            snapshot = nil
            error = nil
            loading = false
        } else if refresh { self.refresh() }
        onChange?()
    }

    func refresh() {
        guard chatGPTRunning else { return }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
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
            Divider()
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
            Divider()
            Toggle("登录 macOS 时启动", isOn: Binding(
                get: { monitor.loginEnabled }, set: { monitor.setLoginEnabled($0) }
            )).toggleStyle(.checkbox).font(.callout)
            HStack {
                Button("刷新", systemImage: "arrow.clockwise") { monitor.refresh() }
                    .disabled(monitor.loading || !monitor.chatGPTRunning)
                    .keyboardShortcut("r", modifiers: .command)
                Spacer()
                Button("退出助手") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let monitor = Monitor()
    private var item: NSStatusItem!
    private let popover = NSPopover()
    private var checkClient: QuotaClient?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--check") { checkConnection(); return }
        let duplicates = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !duplicates.isEmpty { NSApplication.shared.terminate(nil); return }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        item.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: QuotaPanel(monitor: monitor))
        monitor.onChange = { [weak self] in self?.updateItem() }
        monitor.start()
    }

    private func updateItem() {
        item.isVisible = monitor.chatGPTRunning
        item.button?.title = monitor.statusTitle
        let description = "Work / Codex 最低剩余额度：\(monitor.statusTitle)。点击查看所有窗口。"
        item.button?.toolTip = description
        item.button?.setAccessibilityLabel(description)
        if !monitor.chatGPTRunning { popover.performClose(nil) }
    }

    @objc private func togglePanel() {
        guard let button = item.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            monitor.refresh()
            NSApplication.shared.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
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
        checkClient?.stop()
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

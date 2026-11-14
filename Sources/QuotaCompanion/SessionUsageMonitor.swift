import Combine
import Foundation
import QuotaCore

/// Keeps the panel's session token section fresh while the popover is open.
@MainActor
final class SessionUsageMonitor: ObservableObject {
    @Published private(set) var sessions: [SessionUsage] = []
    @Published private(set) var summary: SessionUsage?
    @Published private(set) var message: String?
    @Published private(set) var archivedCount = 0
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var followLatest: Bool
    @Published private(set) var selectedID: String?

    private static let followKey = "sessionUsage.followLatest"
    private static let selectionKey = "sessionUsage.selectedID"

    private let scanner: SessionUsageScanner
    private let defaults: UserDefaults
    private var timer: Timer?
    private var interval: TimeInterval = 20
    private var refreshing = false
    var onChange: (() -> Void)?

    init(scanner: SessionUsageScanner = SessionUsageScanner(), defaults: UserDefaults = .standard) {
        self.scanner = scanner
        self.defaults = defaults
        let storedFollow = defaults.object(forKey: Self.followKey) as? Bool ?? true
        self.followLatest = storedFollow
        self.selectedID = storedFollow ? nil : defaults.string(forKey: Self.selectionKey)
    }

    /// The menu bar stays visible for an hour after the latest session update.
    var hasRecentActivity: Bool {
        guard let latest = sessions.first else { return false }
        return Date().timeIntervalSince(latest.updatedAt) < 3600
    }

    func start() {
        schedule(interval: 20)
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func setFastPolling(_ fast: Bool) {
        let next: TimeInterval = fast ? 2 : 20
        guard next != interval else { return }
        interval = next
        schedule(interval: next)
        if fast { refresh() }
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task {
            let snapshot = await scanner.refresh()
            apply(snapshot)
            refreshing = false
        }
    }

    func select(_ id: String?) {
        followLatest = id == nil
        selectedID = followLatest ? nil : id
        persist()
        applySelection()
        onChange?()
    }

    private func schedule(interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func apply(_ snapshot: SessionUsageSnapshot) {
        sessions = snapshot.sessions
        archivedCount = snapshot.archivedCount
        message = snapshot.message
        lastUpdated = snapshot.scannedAt
        applySelection()
        onChange?()
    }

    private func applySelection() {
        if !followLatest, let selectedID, let match = sessions.first(where: { $0.id == selectedID }) {
            summary = match
            return
        }
        if !followLatest {
            // The selected session was archived or removed: fall back to following the latest.
            followLatest = true
            selectedID = nil
            persist()
        }
        summary = sessions.first
    }

    private func persist() {
        defaults.set(followLatest, forKey: Self.followKey)
        if let selectedID, !followLatest {
            defaults.set(selectedID, forKey: Self.selectionKey)
        } else {
            defaults.removeObject(forKey: Self.selectionKey)
        }
    }
}

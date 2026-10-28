import Foundation

public struct QuotaWindow: Equatable, Identifiable {
    public let id: String
    public let title: String
    public let remaining: Double
    public let resetsAt: Date?

    public var percentage: String { String(format: "%.0f%%", remaining) }

    public func resetDescription(now: Date = Date()) -> String {
        guard let resetsAt else { return "未提供重置时间" }
        let seconds = resetsAt.timeIntervalSince(now)
        guard seconds > 0 else { return "重置时间已到，等待服务确认" }
        let minutes = max(1, Int(ceil(seconds / 60)))
        if minutes >= 1440 { return "\(minutes / 1440)天 \(minutes % 1440 / 60)小时后重置" }
        if minutes >= 60 { return "\(minutes / 60)小时 \(minutes % 60)分钟后重置" }
        return "\(minutes)分钟后重置"
    }
}

public struct QuotaSnapshot: Equatable {
    public let windows: [QuotaWindow]
    public let receivedAt: Date
    public let plan: String?

    public var remaining: Double? { windows.map(\.remaining).min() }

    /// A window's role comes from its actual duration, never from primary/secondary position.
    public static func parse(_ payload: [String: Any], now: Date = Date()) throws -> Self {
        var buckets: [(String, [String: Any])] = []
        if let mapped = payload["rateLimitsByLimitId"] as? [String: [String: Any]], !mapped.isEmpty {
            buckets = mapped.sorted { $0.key < $1.key }
        } else if let legacy = payload["rateLimits"] as? [String: Any] {
            buckets = [(legacy["limitId"] as? String ?? "codex", legacy)]
        }
        var windows: [QuotaWindow] = []
        for (key, bucket) in buckets {
            for slot in ["primary", "secondary"] {
                guard let value = bucket[slot] as? [String: Any],
                      let used = value["usedPercent"] as? NSNumber,
                      CFGetTypeID(used) != CFBooleanGetTypeID(), used.doubleValue.isFinite else { continue }
                let duration = value["windowDurationMins"] as? Int
                let title: String
                switch duration {
                case 300: title = "5 小时额度"
                case 10080: title = "每周额度"
                case let mins? where mins > 0 && mins % 1440 == 0: title = "\(mins / 1440) 天额度"
                case let mins? where mins > 0 && mins % 60 == 0: title = "\(mins / 60) 小时额度"
                case let mins? where mins > 0: title = "\(mins) 分钟额度"
                default: title = "额度窗口（时长未提供）"
                }
                let prefix = key == "codex" ? "" : "\(bucket["limitName"] as? String ?? key) · "
                let reset = (value["resetsAt"] as? NSNumber).flatMap { number -> Date? in
                    let seconds = number.doubleValue
                    return seconds.isFinite && seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
                }
                windows.append(QuotaWindow(id: "\(key).\(slot)", title: prefix + title,
                                           remaining: min(100, max(0, 100 - used.doubleValue)), resetsAt: reset))
            }
        }
        guard !windows.isEmpty else { throw QuotaError.noQuota }
        return Self(windows: windows, receivedAt: now, plan: buckets.first?.1["planType"] as? String)
    }
}

import CoreFoundation

public enum QuotaError: LocalizedError {
    case noQuota, missingApp, connection, timeout, signedOut, server

    public var errorDescription: String? {
        switch self {
        case .noQuota: return "服务未返回可用额度。请确认使用 ChatGPT 订阅登录。"
        case .missingApp: return "找不到 ChatGPT 内置的 Codex 服务，请更新桌面端。"
        case .connection: return "本地额度服务已断开，将自动重连。"
        case .timeout: return "读取额度超时，将在下次刷新时重试。"
        case .signedOut: return "请在 ChatGPT / Codex 中登录订阅账号后刷新。"
        case .server: return "暂时无法读取额度。请检查网络或重新登录后刷新。"
        }
    }
}

import Foundation

/// 升级漏斗事件（spec §5）。参数只含版本号/阶段/耗时，绝不含序列号、MAC、指纹或配对数据。
public enum TelemetryEvent {
    case fwCheck(deviceVersion: String, latestVersion: String, updateAvailable: Bool)
    case fwPromptShown(from: String, to: String)
    case fwUpdateStarted(from: String, to: String, hops: Int)
    case fwHopDone(hop: String, durationMs: Int)                      // "bridge" | "final"
    case fwUpdateSuccess(from: String, to: String, totalDurationMs: Int, retries: Int)
    case fwUpdateFailed(stage: String, errorCode: String, hop: String) // stage: download/preflight/transfer/verify/reconnect
    case fwUpdateResumed(pendingHop: String)

    public var name: String {
        switch self {
        case .fwCheck: return "fw_check"
        case .fwPromptShown: return "fw_prompt_shown"
        case .fwUpdateStarted: return "fw_update_started"
        case .fwHopDone: return "fw_hop_done"
        case .fwUpdateSuccess: return "fw_update_success"
        case .fwUpdateFailed: return "fw_update_failed"
        case .fwUpdateResumed: return "fw_update_resumed"
        }
    }

    var params: [String: Any] {
        switch self {
        case let .fwCheck(d, l, a):
            return ["device_version": d, "latest_version": l, "update_available": a]
        case let .fwPromptShown(f, t):
            return ["from_version": f, "to_version": t]
        case let .fwUpdateStarted(f, t, h):
            return ["from_version": f, "to_version": t, "hops": h]
        case let .fwHopDone(hop, ms):
            return ["hop": hop, "duration_ms": ms]
        case let .fwUpdateSuccess(f, t, ms, r):
            return ["from_version": f, "to_version": t, "total_duration_ms": ms, "retries": r]
        case let .fwUpdateFailed(stage, code, hop):
            return ["stage": stage, "error_code": code, "hop": hop]
        case let .fwUpdateResumed(hop):
            return ["pending_hop": hop]
        }
    }
}

/// fire-and-forget 遥测客户端。sender 注入实际发送（App 侧 = URLSession POST 官网代理）。
/// 失败即丢弃，绝不影响升级流程。
public final class TelemetryClient {
    private let clientID: String
    private let appVersion: String
    private let isEnabled: () -> Bool
    private let sender: (Data) -> Void

    public init(clientID: String, appVersion: String,
                isEnabled: @escaping () -> Bool,
                sender: @escaping (Data) -> Void) {
        self.clientID = clientID
        self.appVersion = appVersion
        self.isEnabled = isEnabled
        self.sender = sender
    }

    public func send(_ event: TelemetryEvent) {
        guard isEnabled() else { return }
        var params = event.params
        params["app_version"] = appVersion
        let payload: [String: Any] = [
            "client_id": clientID,
            "events": [["name": event.name, "params": params]]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        sender(data)
    }
}

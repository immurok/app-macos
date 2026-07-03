import Foundation

public enum UpdatePlan: Equatable {
    case upToDate       // 无需升级
    case direct         // 一跳：直接推 latest
    case bridgeOnly     // 一跳：latest 就是桥版本，推桥包
    case twoHops        // 两跳：桥包 → latest
    case unknown        // 版本号解析失败，UI 提示重连/重试
}

public enum UpdatePlanner {
    public static let fallbackMinDirect = "1.6.0"

    public static func plan(device: String, latest: String, minDirect: String?) -> UpdatePlan {
        guard let dev = FirmwareVersion(device),
              let tgt = FirmwareVersion(latest),
              let gate = FirmwareVersion(minDirect ?? fallbackMinDirect) else { return .unknown }
        if dev >= tgt { return .upToDate }
        if dev >= gate { return .direct }
        // dev < gate：需要经桥
        return tgt == gate ? .bridgeOnly : .twoHops
    }
}

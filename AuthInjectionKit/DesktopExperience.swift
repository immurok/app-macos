import Foundation

public enum SetupFeature: String, CaseIterable, Codable, Hashable {
    case screenUnlock, administrator, ssh
    public var titleKey: String { "experience.feature.\(rawValue).title" }
    public var detailKey: String { "experience.feature.\(rawValue).detail" }
    public var symbol: String {
        switch self {
        case .screenUnlock: return "lock.open"
        case .administrator: return "person.badge.key"
        case .ssh: return "terminal"
        }
    }
}

public struct SetupPlan: Equatable {
    public let features: Set<SetupFeature>
    public init(features: Set<SetupFeature>) { self.features = features }
    public var needsPassword: Bool { features.contains(.screenUnlock) }
    public var needsAccessibility: Bool { features.contains(.screenUnlock) }
    public var needsPAM: Bool { features.contains(.administrator) }
}

public enum DeviceReadiness: String, CaseIterable {
    case bluetoothPermission, bluetoothOff, unsupported, disconnected, pairing, unverified
    case enroll, password, accessibility, administrator, chooseFeatures, lowBattery, ready
    public var titleKey: String { "experience.status.\(rawValue).title" }
    public var detailKey: String { "experience.status.\(rawValue).detail" }
    public var actionKey: String { "experience.status.\(rawValue).action" }
    public var symbol: String {
        switch self {
        case .ready: return "checkmark.shield.fill"
        case .lowBattery: return "battery.25percent"
        case .disconnected, .bluetoothOff: return "antenna.radiowaves.left.and.right.slash"
        case .pairing, .unverified: return "lock.shield"
        case .enroll: return "touchid"
        default: return "exclamationmark.circle"
        }
    }
}

/// Pure prioritization: transport and identity always take precedence over convenience.
public struct DeviceReadinessInput {
    public var permissionDenied = false
    public var poweredOff = false
    public var unsupported = false
    public var connected = false
    public var paired = false
    public var verified = false
    public var fingerprintCount = 0
    public var features: Set<SetupFeature> = []
    public var hasPassword = false
    public var passwordSuspended = false
    public var accessibility = false
    public var pamReady = false
    public var battery: Int?
    public init() {}
    public var status: DeviceReadiness {
        if permissionDenied { return .bluetoothPermission }
        if poweredOff { return .bluetoothOff }
        if unsupported { return .unsupported }
        if !connected { return .disconnected }
        if !paired { return .pairing }
        if !verified { return .unverified }
        if fingerprintCount == 0 { return .enroll }
        if features.isEmpty { return .chooseFeatures }
        let plan = SetupPlan(features: features)
        if plan.needsPassword && (!hasPassword || passwordSuspended) { return .password }
        if plan.needsAccessibility && !accessibility { return .accessibility }
        if plan.needsPAM && !pamReady { return .administrator }
        if let battery, battery <= 15 { return .lowBattery }
        return .ready
    }
}

/// Escape invisible controls before presenting requester-supplied text. Never
/// silently truncate a command: the review surface must expose the full value.
public enum ApprovalPresentation {
    public static func visible(_ value: String) -> String {
        var result = ""
        for scalar in value.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7f ||
                (0x202a...0x202e).contains(scalar.value) ||
                (0x2066...0x2069).contains(scalar.value) {
                result += String(format: "\\u{%04X}", scalar.value)
            } else { result.unicodeScalars.append(scalar) }
        }
        return result
    }
}

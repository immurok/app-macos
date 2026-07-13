import Foundation

/// Process-wide mutual exclusion between fingerprint-gated auth flows and
/// keystore maintenance (storage-mutating / batch) operations.
///
/// The BLE command queue only serializes individual GATT commands. A batch
/// delete is a multi-command transaction whose swap-delete reindexing, cache
/// digests, and device-side FP-gate state are all torn apart if another
/// gated flow (PAM AUTH, AGENT_APPROVE, `imk get`, SSH sign, QuickFill)
/// interleaves. Every such entry point must `tryBegin` here first and reject
/// fast when someone else owns the device.
///
/// Same-kind flows are also mutually exclusive — this generalizes the old
/// PAMSocketServer-private `authInFlight` lock to the whole app.
public final class DeviceActivityCoordinator {
    public static let shared = DeviceActivityCoordinator()

    public enum Activity: String {
        case auth
        case keystoreMaintenance
    }

    /// Opaque ownership proof. `end` only releases when the token matches
    /// the current owner, so a stale completion path of a finished flow
    /// can never release a lock that a newer flow has since acquired.
    public struct Token {
        public let activity: Activity
        fileprivate let id: UInt64
    }

    private let lock = NSLock()
    private var current: Token?
    private var nextID: UInt64 = 0

    public init() {}

    /// Becomes the exclusive device-flow owner, or returns nil if any
    /// activity (either kind) is already in flight.
    public func tryBegin(_ activity: Activity) -> Token? {
        lock.lock()
        defer { lock.unlock() }
        guard current == nil else { return nil }
        nextID &+= 1
        let token = Token(activity: activity, id: nextID)
        current = token
        return token
    }

    /// Releases ownership. No-op if `token` is not the current owner.
    public func end(_ token: Token) {
        lock.lock()
        defer { lock.unlock() }
        if current?.id == token.id {
            current = nil
        }
    }

    /// Kind of the activity currently holding the device, if any.
    public var currentActivity: Activity? {
        lock.lock()
        defer { lock.unlock() }
        return current?.activity
    }
}

import Foundation
import Darwin
import AuthInjectionKit

/// A best-effort kernel peer/process snapshot, not an attestation of the command
/// or a request-bound authorization token. Unknown identity stays explicitly unknown.
struct ApprovalRequester: Equatable {
    let name: String
    let detail: String
    static var unknown: Self {
        Self(name: "experience.approval.unknown".localized, detail: "experience.approval.unknown.detail".localized)
    }
    static func capture(socketFD: Int32) -> Self {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(socketFD, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0 else { return .unknown }
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return .unknown }
        let executable = String(cString: path)
        return Self(name: ApprovalPresentation.visible((executable as NSString).lastPathComponent),
                    detail: "PID \(pid) · \(ApprovalPresentation.visible(executable))")
    }
}

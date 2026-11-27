import Foundation

/// 录入失败原因：固件 1.8.9+ 在 `[0x11][0xFF]` 失败帧的 current 字节里带，旧固件恒为 0。
/// 与 firmware/APP/include/fingerprint.h 的 FP_ENROLL_FAIL_* 保持一致。
enum EnrollFailReason {
    static let generic = 0
    static let duplicate = 1   // 这根手指已录在别的槽位

    /// 只有 0xFF 帧的 byte[2] 是原因码；其余被归为失败的状态字节一律按通用失败，
    /// 免得把别的含义的数值误读成「重复指纹」。
    static func fromFrame(status: UInt8, byte2: Int) -> Int {
        status == 0xFF ? byte2 : generic
    }
}

/// 「验证旧指纹 → 换手指 → 采集新指纹」之间的过渡，只做帧裁决，不碰界面和计时器。
///
/// 设备上已有认证指纹时，ENROLL_START 先回 WAIT_FP，用户用旧手指过门。门过的那一刻
/// 旧手指必然还按在传感器上：固件先推一帧 LiftFinger（请抬起），抬起后再推一帧
/// LiftFinger（已抬起），然后才等新手指。界面如果门一过就摆出采集引导，用户看不出
/// 「验证」已经结束、「采集」已经开始，会抬起再按回同一根手指——固件 1.8.9 起这会被
/// 判成重复指纹，整次录入中止。所以门过之后先停在「验证通过，换成新手指」上，至少
/// 停留 `minDwell`，这期间到达的帧只留最新一帧，停留够了再处理。
///
/// 没有 WAIT_FP（首次录入，或门在冷却期内被固件跳过）就没有过渡。
struct EnrollHandoff {
    /// 过渡画面的最短停留时间。与 Windows 端 EnrollDialog.HandoffMinMs 一致。
    static let minDwell: TimeInterval = 1.8

    enum Decision: Equatable {
        case apply    // 照常交给录入界面处理
        case swallow  // 过渡画面已经表达了这一帧，丢弃
        case hold     // 先压着，停留时间到了由 dwellDidElapse() 交出
    }

    private enum Phase { case idle, armed, active }

    private var phase: Phase = .idle
    private var liftPromptSeen = false
    private var dwellElapsed = false
    private var held: EnrollStatusPayload?

    /// 过渡画面是否应该显示。
    var isActive: Bool { phase == .active }

    /// 门已挂起、还没过（期间到达的帧也要交给 `frame(_:)`）。
    var isArmed: Bool { phase == .armed }

    /// 设备对 ENROLL_START 回了 WAIT_FP。
    mutating func arm() {
        reset()
        phase = .armed
    }

    /// 门过了、录入开始。返回是否进入过渡（没挂过门就不进）。
    @discardableResult
    mutating func begin() -> Bool {
        guard phase == .armed else { return false }
        phase = .active
        return true
    }

    mutating func reset() {
        phase = .idle
        liftPromptSeen = false
        dwellElapsed = false
        held = nil
    }

    mutating func frame(_ payload: EnrollStatusPayload) -> Decision {
        switch phase {
        case .idle:
            return .apply

        case .armed:
            // 「请抬起」帧可能比门的完成回调先到主线程。录入界面此时还没开始，
            // 这帧没处显示，但要记下来，否则后面的「已抬起」会被当成它吞掉。
            if payload.event == .liftFinger { liftPromptSeen = true }
            return .swallow

        case .active:
            if payload.event == .complete || payload.event == .failed {
                reset()
                return .apply
            }
            if !liftPromptSeen && payload.event == .liftFinger {
                liftPromptSeen = true
                return .swallow
            }
            if !dwellElapsed {
                held = payload
                return .hold
            }
            reset()
            return .apply
        }
    }

    /// 停留时间到。有压着的帧就交出来并结束过渡；没有（用户还没抬手）就继续
    /// 停在过渡画面，等下一帧到达时由 `frame(_:)` 结束。
    mutating func dwellDidElapse() -> EnrollStatusPayload? {
        guard phase == .active else { return nil }
        dwellElapsed = true
        guard let payload = held else { return nil }
        reset()
        return payload
    }
}

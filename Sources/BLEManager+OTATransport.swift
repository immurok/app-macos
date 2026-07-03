// Sources/BLEManager+OTATransport.swift
import Foundation
import FirmwareUpdateKit

/// BLEManager 的 OTA 原语桥接为 OTAEngine 所需的 async 接口。
/// 注意：otaWriteAndRead/otaWriteOnly 内部已在 BLE 队列上排他执行，
/// 这里不额外加锁；FirmwareUpdateService 保证同一时刻只有一个 push 在跑。
extension BLEManager: OTATransport {
    func writeAndRead(_ data: Data, timeout: TimeInterval) async -> Data? {
        await withCheckedContinuation { cont in
            otaWriteAndRead(data: data, timeout: timeout) { resp in
                cont.resume(returning: resp)
            }
        }
    }

    func writeNoResponse(_ data: Data) async -> Bool {
        await withCheckedContinuation { cont in
            otaWriteOnly(data: data) { ok in
                cont.resume(returning: ok)
            }
        }
    }
}

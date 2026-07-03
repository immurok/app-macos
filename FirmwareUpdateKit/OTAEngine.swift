import Foundation

/// OTA 传输抽象：App 侧由 BLEManager 实现，测试用 Mock
public protocol OTATransport {
    /// write-then-read（INFO/ERASE/HEADER/END），nil = 超时/无响应
    func writeAndRead(_ data: Data, timeout: TimeInterval) async -> Data?
    /// write-without-response（PROM 数据块）
    func writeNoResponse(_ data: Data) async -> Bool
}

public enum OTAEngineError: Error, Equatable {
    case noResponse(stage: String)
    case eraseFailed(code: UInt8)
    case headerRejected(code: UInt8)   // 含 v2 拒收 / SVN 反降级
    case writeFailed(offset: Int)
    case sha256Mismatch                // END 0xF1
    case signatureMismatch             // END 0xF2（HMAC/ECDSA 失败）
}

/// WCH IAP OTA 推送引擎。协议对照 PAMSocketServer.swift OTA handlers 与 ota/ota-update.py。
public final class OTAEngine {
    public static let chunkSize = 240        // ≤243 且 16B 对齐
    public static let imageBBlocks: UInt16 = 54  // 216KB / 4KB

    private let transport: OTATransport

    public init(transport: OTATransport) {
        self.transport = transport
    }

    /// 推送一个 .imfw。progress ∈ [0,1]（按数据块字节数计）。
    /// 成功返回 = END 已接受或设备已重启；调用方负责等待重连并核对版本。
    public func push(_ pkg: IMFWPackage, progress: @escaping (Double) -> Void) async throws {
        // 1. INFO（结果仅日志用途，握手确认 OTA 通道活着）
        guard await transport.writeAndRead(Data([0x84, 0x02, 0x00, 0x00]), timeout: 5.0) != nil else {
            throw OTAEngineError.noResponse(stage: "info")
        }

        // 2. ERASE Image B（3-5s）
        let erase = Data([0x81, 0x04, 0x00, 0x00,
                          UInt8(Self.imageBBlocks & 0xFF), UInt8(Self.imageBBlocks >> 8)])
        guard let eraseResp = await transport.writeAndRead(erase, timeout: 15.0) else {
            throw OTAEngineError.noResponse(stage: "erase")
        }
        guard eraseResp.first == 0x00 else {
            throw OTAEngineError.eraseFailed(code: eraseResp.first ?? 0xFF)
        }

        // 3. HEADER（v2 拒收/反降级在此报错）
        var headerCmd = Data([0x85, UInt8(pkg.header.count)])
        headerCmd.append(pkg.header)
        guard let hdrResp = await transport.writeAndRead(headerCmd, timeout: 5.0) else {
            throw OTAEngineError.noResponse(stage: "header")
        }
        guard hdrResp.first == 0x00 else {
            throw OTAEngineError.headerRejected(code: hdrResp.first ?? 0xFF)
        }

        // 4. PROM 分块写入（write-without-response）
        let fw = pkg.encryptedFirmware
        let total = fw.count
        var offset = 0
        while offset < total {
            let end = min(offset + Self.chunkSize, total)
            let chunk = fw.subdata(in: fw.startIndex + offset ..< fw.startIndex + end)
            let addr = UInt16(offset / 16)
            var cmd = Data([0x80, UInt8(chunk.count), UInt8(addr & 0xFF), UInt8(addr >> 8)])
            cmd.append(chunk)
            guard await transport.writeNoResponse(cmd) else {
                throw OTAEngineError.writeFailed(offset: offset)
            }
            offset = end
            progress(Double(offset) / Double(total))
        }

        // 5. END：设备 defer 验签（ECDSA ~2s）后重启。无响应 = 已重启 = 成功。
        let endResp = await transport.writeAndRead(Data([0x83, 0x02, 0x00, 0x00]), timeout: 15.0)
        if let resp = endResp, let code = resp.first {
            switch code {
            case 0xF1: throw OTAEngineError.sha256Mismatch
            case 0xF2: throw OTAEngineError.signatureMismatch
            default: break  // 0x00 或其他 = 接受
            }
        }
    }
}

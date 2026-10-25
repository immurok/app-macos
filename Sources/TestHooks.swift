//
// 真机自动化测试控制面（docs/superpowers/specs/2026-09-20-device-e2e-test-design.md）。
// 整文件只在 `swift build -Xswiftc -DTEST_HOOKS` 下编译；发行构建不含。
// 协议：文本行。中间行是事件，最后一行 OK:/ERR: 开头后关连接。
#if TEST_HOOKS
import Foundation
import AuthInjectionKit
import FirmwareUpdateKit

struct TestRequest {
    let name: String
    let args: [String]
    /// 命令名之后的原文（含冒号），给 OTA:<path> 这类参数用
    let rest: String

    static func parse(_ request: String) -> TestRequest? {
        guard request.hasPrefix("TEST:") else { return nil }
        let body = String(request.dropFirst("TEST:".count))
        guard !body.isEmpty else { return nil }
        let parts = body.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let name = parts[0]
        guard !name.isEmpty else { return nil }
        let rest = parts.count > 1 ? String(body.dropFirst(name.count + 1)) : ""
        return TestRequest(name: name, args: Array(parts.dropFirst()), rest: rest)
    }
}

/// 一条客户端连接。send 失败（对端已关）返回 false。
final class TestConn {
    let fd: Int32
    init(fd: Int32) { self.fd = fd }

    @discardableResult
    func send(_ line: String) -> Bool {
        let msg = line + "\n"
        return msg.withCString { ptr in
            Darwin.send(fd, ptr, strlen(ptr), 0) == strlen(ptr)
        }
    }

    /// 对端是否已经关掉（poll 可读且 recv 返回 0）。
    /// 如果对端只是发了数据（没关闭），必须真正读走这几个字节——不然 poll
    /// 会一直报可读，调用方的轮询循环变成 100% CPU 忙等。
    func peerClosed(timeoutMs: Int32) -> Bool {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let n = poll(&p, 1, timeoutMs)
        guard n > 0, p.revents & Int16(POLLIN | POLLHUP) != 0 else { return false }
        var byte: UInt8 = 0
        let peeked = recv(fd, &byte, 1, MSG_PEEK)
        guard peeked > 0 else { return true }
        _ = recv(fd, &byte, 1, 0)
        return false
    }
}

final class TestHooks {
    static let shared = TestHooks()
    private let ble = BLEManager.shared

    private let lock = NSLock()
    private var subscribers: [UUID: (BLEManager.TestLinkEvent) -> Void] = [:]

    private init() {
        ble.testEventTap = { [weak self] ev in self?.broadcast(ev) }
    }

    private func broadcast(_ ev: BLEManager.TestLinkEvent) {
        lock.lock(); let subs = Array(subscribers.values); lock.unlock()
        subs.forEach { $0(ev) }
    }
    private func subscribe(_ f: @escaping (BLEManager.TestLinkEvent) -> Void) -> UUID {
        let id = UUID(); lock.lock(); subscribers[id] = f; lock.unlock(); return id
    }
    private func unsubscribe(_ id: UUID) { lock.lock(); subscribers[id] = nil; lock.unlock() }

    /// 把回调风格的 BLEManager API 同步等出来。handleClient 跑在 global queue，阻塞无妨。
    /// 超时路径也要在锁下把 done 置 true 再读 out——否则超时那一刻若 BLE 回调正好在另一线程
    /// 写 out，会读到撕裂的半写状态；置 done 还能让"超时之后才姗姗来迟"的回调直接作废。
    private func waitFor<T>(_ timeout: TimeInterval, _ body: (@escaping (T) -> Void) -> Void) -> T? {
        let sem = DispatchSemaphore(value: 0)
        var out: T?
        let once = NSLock(); var done = false
        body { v in
            once.lock(); defer { once.unlock() }
            guard !done else { return }
            done = true; out = v; sem.signal()
        }
        _ = sem.wait(timeout: .now() + timeout)
        once.lock()
        done = true
        let result = out
        once.unlock()
        return result
    }

    /// 临时接管一个单值闭包，body 结束后还原。原闭包也照常被调用。
    /// 注：App 自身 UI（FingerprintViewModel 等）也会无条件覆盖 onEnrollStatus 这类闭包，
    /// TEST:ENROLL 期间若打开设置窗口会顶掉这里挂的钩子——已知限制，不处理。
    private func chain<F>(_ kp: ReferenceWritableKeyPath<BLEManager, F?>, _ mine: F,
                          compose: (F, F) -> F, body: () -> Void) {
        let prev = ble[keyPath: kp]
        ble[keyPath: kp] = prev.map { compose($0, mine) } ?? mine
        body()
        ble[keyPath: kp] = prev
    }

    static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
    static func bytes(_ s: String) -> [UInt8]? {
        let clean = s.replacingOccurrences(of: " ", with: "")
        guard clean.count % 2 == 0 else { return nil }
        var out: [UInt8] = []; var i = clean.startIndex
        while i < clean.endIndex {
            let j = clean.index(i, offsetBy: 2)
            guard let b = UInt8(clean[i..<j], radix: 16) else { return nil }
            out.append(b); i = j
        }
        return out
    }
    /// 事件总线一行文本。0x21/0x23/0x34/0xF0 额外派生一行语义事件。
    static func lines(for ev: BLEManager.TestLinkEvent) -> [String] {
        switch ev {
        case .connected(let n): return ["LINK:CONNECTED:\(n)"]
        case .disconnected(let r): return ["LINK:DISCONNECTED:\(r)"]
        case .rx(let d):
            var out = ["RX:\(hex(d))"]
            guard let first = d.first else { return out }
            switch first {
            case 0x21 where d.count == 11:
                out.append("FPMATCH:\(Int(d[1]) | Int(d[2]) << 8)")
            case 0x23 where d.count == 1: out.append("LOCKREQ")
            case 0x34 where d.count == 2: out.append("PAIRBTN:\(String(format: "%02x", d[1]))")
            case 0xF0 where d.count == 6:
                out.append("PARAM:\(Int(d[1]) << 8 | Int(d[2]))/\(d[3])/\(Int(d[4]) << 8 | Int(d[5]))")
            default: break
            }
            return out
        }
    }

    func handle(socket fd: Int32, request: String) {
        let conn = TestConn(fd: fd)
        guard let req = TestRequest.parse(request) else {
            conn.send("ERR:BAD_REQUEST"); return
        }
        Task { @MainActor in LogManager.shared.log("TEST hook: \(req.name) \(req.args)") }
        switch req.name {
        case "PING":
            let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
            conn.send("OK:TEST_HOOKS \(ver)")
        case "STATE": handleState(conn)
        case "CMD": handleCmd(conn, req)
        case "RAW": handleRaw(conn, req)
        case "RX":
            guard req.args.first == "SUB" else { conn.send("ERR:BAD_ARGS"); return }
            handleSubscribe(conn)
        case "GATE": handleGate(conn, req)
        case "GATE_CANCEL": handleGateCancel(conn)
        case "ENROLL": handleEnroll(conn, req)
        case "ENROLL_CANCEL": handleEnrollCancel(conn)
        case "FP_LIST": handleFpList(conn)
        case "FP_DELETE": handleFpDelete(conn, req)
        case "PAIR": handlePair(conn)
        case "UNPAIR": handleUnpair(conn)
        case "SLOT_STATUS": handleSlotStatus(conn)
        case "SLOT_CLEAR": handleSlotClear(conn, req)
        case _ where req.name.hasPrefix("KEY_"): handleKey(conn, req)
        case "OTA": handleOta(conn, req)
        case "OTA_ABORT": handleOtaAbort(conn)
        case "OTA_RAW": handleOtaRaw(conn, req)
        case "DISCONNECT": handleDisconnect(conn)
        case "RECONNECT": handleReconnect(conn)
        default:
            conn.send("ERR:UNKNOWN_TEST_COMMAND")
        }
    }

    private func handleState(_ conn: TestConn) {
        guard ble.testIsConnected else {
            conn.send("OK:{\"connected\":false}"); return
        }
        // getDeviceStatus 内部 sendCommand 超时是 5s，这里给 +1s 余量，避免两个计时器在同一
        // 窗口触发导致误判撕裂读；超时时必须回 ERR:TIMEOUT，不能拿全 0 冒充"未配对"。
        guard let st = waitFor(6.0, { done in ble.getDeviceStatus { b, p, batt, fw in done((b, p, batt, fw)) } }) else {
            conn.send("ERR:TIMEOUT"); return
        }
        let slot = waitFor(6.0) { done in ble.getSlotStatus { bm, ac in done((bm, ac)) } }
        let batt = waitFor(7.0) { done in ble.getBatteryRaw(forceFresh: false) { done($0) } } ?? nil
        let conn_ = waitFor(4.0) { done in ble.getConnParams { done($0) } } ?? nil
        var j: [String: Any] = [
            "connected": true,
            "verified": ble.isDeviceVerified,
            "fw": st.3 ?? ble.testFirmwareVersion ?? "",
            "fp_bitmap": Int(st.0),
            "paired": st.1,
            "slot_bitmap": Int(slot?.0 ?? 0),
            "slot_active": Int(slot?.1 ?? 0),
        ]
        if let b = batt { j["batt_mv"] = b.mv; j["batt_pct"] = b.pct }
        if let c = conn_ { j["conn"] = ["interval": Int(c.interval), "latency": Int(c.latency), "timeout": Int(c.timeout)] }
        let data = try! JSONSerialization.data(withJSONObject: j, options: [.sortedKeys])
        conn.send("OK:" + String(data: data, encoding: .utf8)!)
    }

    private func handleCmd(_ conn: TestConn, _ req: TestRequest) {
        guard let raw = req.args.first, let bytes = TestHooks.bytes(raw), !bytes.isEmpty else {
            conn.send("ERR:BAD_HEX"); return
        }
        guard let op = ImmurokCommand(rawValue: bytes[0]) else {
            conn.send("ERR:UNKNOWN_OPCODE_USE_RAW"); return
        }
        // executeSend 把 payload.count 塞进一个字节（data[1] = UInt8(payload.count)），超过
        // 255 会整数溢出 trap，必须在这里挡住。
        guard bytes.count - 1 <= 255 else {
            conn.send("ERR:PAYLOAD_TOO_LONG"); return
        }
        let ms = req.args.count > 1 ? Double(req.args[1]) ?? 5000 : 5000
        let r = waitFor(ms / 1000 + 1) { done in
            ble.testSendCommand(op, payload: Array(bytes.dropFirst()), timeout: ms / 1000) { done($0) }
        } ?? nil
        if let r = r { conn.send("OK:" + TestHooks.hex(r)) } else { conn.send("ERR:TIMEOUT") }
    }

    private func handleRaw(_ conn: TestConn, _ req: TestRequest) {
        guard let raw = req.args.first, let bytes = TestHooks.bytes(raw) else {
            conn.send("ERR:BAD_HEX"); return
        }
        let ms = req.args.count > 1 ? Double(req.args[1]) ?? 1500 : 1500
        if ble.testCommandInFlight { conn.send("ERR:BUSY"); return }
        let sem = DispatchSemaphore(value: 0)
        let firstLock = NSLock()
        var first: Data?
        let sub = subscribe { ev in
            guard case .rx(let d) = ev else { return }
            firstLock.lock()
            let already = first != nil
            if !already { first = d }
            firstLock.unlock()
            if !already { sem.signal() }
        }
        defer { unsubscribe(sub) }
        guard ble.testRawWrite(Data(bytes)) else { conn.send("ERR:NOT_CONNECTED"); return }
        _ = sem.wait(timeout: .now() + ms / 1000)
        firstLock.lock(); let d = first; firstLock.unlock()
        if let d = d { conn.send("OK:" + TestHooks.hex(d)) } else { conn.send("OK:NORX") }
    }

    private func handleGate(_ conn: TestConn, _ req: TestRequest) {
        guard ble.testIsConnected else { conn.send("ERR:NOT_CONNECTED"); return }
        let timeout = req.args.first.flatMap(Double.init) ?? 30
        guard let token = DeviceActivityCoordinator.shared.tryBegin(.auth) else {
            conn.send("ERR:BUSY"); return
        }
        defer { DeviceActivityCoordinator.shared.end(token) }
        let stateLock = NSLock()
        var live = true            // chain 的 body 结束（即将还原闭包）后置 false，之后不再写 fd
        var sawDeniedFinal = false // 固件在无人触摸的门上以 left==0 的一条 FAIL 收尾，标记为明确拒绝
        var result: Bool?
        chain(\.onFingerprintAttemptFailed, { left in
            stateLock.lock()
            let alive = live
            if left == 0 { sawDeniedFinal = true }
            stateLock.unlock()
            if alive { conn.send("FP:FAIL:\(left)") }
        }, compose: { a, b in { a($0); b($0) } }) {
            result = waitFor(timeout + 2) { done in
                ble.requestUnlock(timeout: timeout) { ok in done(ok) }
            }
            stateLock.lock(); live = false; stateLock.unlock()
        }
        switch result {
        case .some(true): conn.send("FP:OK"); conn.send("OK:PASS")
        case .some(false):
            stateLock.lock(); let denied = sawDeniedFinal; stateLock.unlock()
            conn.send(denied ? "OK:DENIED" : "OK:TIMEOUT")
        case .none: conn.send("OK:TIMEOUT")
        }
    }

    private func handleGateCancel(_ conn: TestConn) {
        // cancelGate() 只是把 GATE_CANCEL 排到 AUTH_REQUEST 的队列 hold 后面，TEST:GATE 期间
        // 永远发不出去；cancelUnlock() 才会真正发送取消、把 pending completion 置 false 并
        // 释放 hold（BLEManager.swift ~453-470）。
        ble.cancelUnlock(); conn.send("OK")
    }

    private var enrollCancelled = false

    private func handleEnroll(_ conn: TestConn, _ req: TestRequest) {
        guard ble.testIsConnected else { conn.send("ERR:NOT_CONNECTED"); return }
        guard let s = req.args.first, let slot = UInt8(s) else { conn.send("ERR:BAD_ARGS"); return }
        guard let token = DeviceActivityCoordinator.shared.tryBegin(.auth) else { conn.send("ERR:BUSY"); return }
        defer { DeviceActivityCoordinator.shared.end(token) }
        enrollCancelled = false
        let sem = DispatchSemaphore(value: 0)
        let stateLock = NSLock()
        var terminal: String?
        var live = true // chain 的 body 结束（即将还原闭包）后置 false，之后不再写 fd
        let mine: (EnrollEvent, Int, Int) -> Void = { ev, cur, total in
            stateLock.lock(); let alive = live; stateLock.unlock()
            guard alive else { return }
            conn.send("STEP:\(ev):\(cur)/\(total)")
            if ev == .complete {
                stateLock.lock(); terminal = "OK:COMPLETE"; stateLock.unlock()
                sem.signal()
            }
            if ev == .failed {
                stateLock.lock(); terminal = "OK:FAILED"; stateLock.unlock()
                sem.signal()
            }
        }
        chain(\.onEnrollStatus, mine, compose: { a, b in { a($0, $1, $2); b($0, $1, $2) } }) {
            // 已有认证指纹时 ENROLL_START 也要过门，主机侧门超时 30s；+5s 余量
            let started = waitFor(35) { done in ble.startEnrollment(slotId: slot) { done($0) } } ?? false
            if !started {
                // 别把设备晾在一个没人接的门上
                ble.cancelGateAndRelease()
                stateLock.lock(); terminal = "ERR:START_FAILED"; stateLock.unlock()
            } else {
                conn.send("STARTED")
                // 登记最长 120s；ENROLL_CANCEL 到达后固件可能不再吐事件，所以每秒看一次取消标志
                let deadline = Date().addingTimeInterval(120)
                while true {
                    stateLock.lock(); let done = terminal != nil; stateLock.unlock()
                    if done || Date() >= deadline { break }
                    if sem.wait(timeout: .now() + 1) == .success { break }
                    if enrollCancelled {
                        stateLock.lock()
                        if terminal == nil { terminal = "OK:CANCELLED" }
                        stateLock.unlock()
                        break
                    }
                }
            }
            stateLock.lock(); live = false; stateLock.unlock()
        }
        stateLock.lock(); let result = terminal; stateLock.unlock()
        conn.send(result ?? "OK:TIMEOUT")
    }

    private func handleEnrollCancel(_ conn: TestConn) {
        enrollCancelled = true
        let ok = waitFor(5) { done in ble.cancelEnrollment { done($0) } } ?? false
        conn.send(ok ? "OK" : "ERR:CANCEL_FAILED")
    }

    private func handleFpList(_ conn: TestConn) {
        guard ble.testIsConnected else { conn.send("ERR:NOT_CONNECTED"); return }
        // sendCommand 内部超时 5s，这里 +1s 余量避免与它撞在同一窗口。
        guard let bm = waitFor(6, { done in ble.getFingerprintBitmap { done($0) } }) else {
            conn.send("ERR:TIMEOUT"); return
        }
        conn.send("OK:" + String(format: "%02x", bm))
    }

    private func handleFpDelete(_ conn: TestConn, _ req: TestRequest) {
        guard ble.testIsConnected else { conn.send("ERR:NOT_CONNECTED"); return }
        guard let s = req.args.first, let slot = UInt8(s) else { conn.send("ERR:BAD_ARGS"); return }
        guard let token = DeviceActivityCoordinator.shared.tryBegin(.auth) else { conn.send("ERR:BUSY"); return }
        defer { DeviceActivityCoordinator.shared.end(token) }
        let stateLock = NSLock()
        var live = true // chain 的 body 结束（即将还原闭包）后置 false，之后不再写 fd
        var ok: Bool?
        chain(\.onFingerprintAttemptFailed, { left in
            stateLock.lock(); let alive = live; stateLock.unlock()
            if alive { conn.send("FP:FAIL:\(left)") }
        }, compose: { a, b in { a($0); b($0) } }) {
            ok = waitFor(35) { done in ble.deleteFingerprint(slotId: slot) { done($0) } }
            stateLock.lock(); live = false; stateLock.unlock()
        }
        switch ok {
        case .some(true): conn.send("OK")
        case .some(false): conn.send("ERR:DENIED")
        case .none: conn.send("ERR:TIMEOUT")
        }
    }

    private func handlePair(_ conn: TestConn) {
        guard ble.testIsConnected else { conn.send("ERR:NOT_CONNECTED"); return }
        guard let token = DeviceActivityCoordinator.shared.tryBegin(.auth) else { conn.send("ERR:BUSY"); return }
        defer { DeviceActivityCoordinator.shared.end(token) }
        let stateLock = NSLock()
        var live = true // 最内层 chain 的 body 结束（即将逐层还原闭包）后置 false，之后不再写 fd
        var reason: PairFailureReason??
        let stage: (String) -> () -> Void = { name in {
            stateLock.lock(); let alive = live; stateLock.unlock()
            if alive { conn.send("STAGE:\(name)") }
        } }
        chain(\.onPairWaitButton, stage("wait_button"), compose: { a, b in { a(); b() } }) {
        chain(\.onPairButtonConfirmed, stage("button_confirmed"), compose: { a, b in { a(); b() } }) {
        chain(\.onPairFingerprintConfirmed, stage("fp_confirmed"), compose: { a, b in { a(); b() } }) {
            stateLock.lock(); let alive = live; stateLock.unlock()
            if alive { conn.send("STAGE:pair_init") }
            // 90s：设备以 0xE1（BLE 连接参数不够跑 ECC）拒绝时 startPairingAttempt
            // 会自动重试（最多 3 次，每次 ~45s 按键窗口 + 5s 重试延迟），比单次
            // 45s 按键等待长得多，外层必须留够一整轮重试的余量。
            reason = waitFor(90) { done in ble.startPairing { done($0) } }
            stateLock.lock(); live = false; stateLock.unlock()
        }}}
        switch reason {
        case .some(.none): conn.send("OK")
        case .some(.some(let r)): conn.send("ERR:\(r)")
        case .none: conn.send("ERR:TIMEOUT")
        }
    }

    private func handleUnpair(_ conn: TestConn) {
        // clearOwnSlot 在未连接时直接回 .cleared（把它当"设备已经不用管了"处理）——
        // 测试钩子这里要的是真实结果，未连接必须先报出来，不能冒充解绑成功。
        guard ble.testIsConnected else { conn.send("ERR:NOT_CONNECTED"); return }
        let r = waitFor(15) { done in ble.clearOwnSlot { done($0) } }
        switch r {
        case .some(.cleared): conn.send("OK:CLEARED")
        case .some(.rejected): conn.send("OK:REJECTED")
        case .none: conn.send("ERR:TIMEOUT")
        }
    }

    private func handleSlotStatus(_ conn: TestConn) {
        // sendCommand 内部默认超时 5.0s，+1s 余量。
        guard let s = waitFor(6, { done in ble.getSlotStatus { bm, ac in done((bm, ac)) } }) else {
            conn.send("ERR:TIMEOUT"); return
        }
        conn.send("OK:\(s.0):\(s.1)")
    }

    private func handleSlotClear(_ conn: TestConn, _ req: TestRequest) {
        guard let s = req.args.first, let slot = UInt8(s) else { conn.send("ERR:BAD_ARGS"); return }
        guard let token = DeviceActivityCoordinator.shared.tryBegin(.auth) else { conn.send("ERR:BUSY"); return }
        defer { DeviceActivityCoordinator.shared.end(token) }
        let stateLock = NSLock()
        var live = true // chain 的 body 结束（即将还原闭包）后置 false，之后不再写 fd
        var ok: Bool?
        chain(\.onFingerprintAttemptFailed, { left in
            stateLock.lock(); let alive = live; stateLock.unlock()
            if alive { conn.send("FP:FAIL:\(left)") }
        }, compose: { a, b in { a($0); b($0) } }) {
            // 门超时 startGateTimeout() 硬编码 30s，+10s 余量。
            ok = waitFor(40) { done in ble.clearSlot(slot) { done($0) } }
            stateLock.lock(); live = false; stateLock.unlock()
        }
        conn.send(ok == true ? "OK" : (ok == false ? "ERR:DENIED" : "ERR:TIMEOUT"))
    }

    private func cat(_ s: String?) -> KeystoreCategory? {
        switch s { case "ssh": return .ssh; case "otp": return .otp; case "api": return .api; default: return nil }
    }

    private func handleKey(_ conn: TestConn, _ req: TestRequest) {
        let sub = String(req.name.dropFirst("KEY_".count))
        let a = req.args
        switch sub {
        case "COUNT":
            guard let c = cat(a.first) else { conn.send("ERR:BAD_CAT"); return }
            // sendCommand 内部默认超时 5.0s，+1s 余量。
            guard let n = waitFor(6, { done in ble.getKeyCount(cat: c) { done($0) } }) else { conn.send("ERR:TIMEOUT"); return }
            conn.send("OK:\(n)")
        case "READ":
            guard let c = cat(a.first), a.count >= 2, let idx = UInt8(a[1]) else { conn.send("ERR:BAD_ARGS"); return }
            // 最坏情况 api 类目 160B / 59B块 ≈ 3 块 × 默认 5s = 15s，+5s 余量。
            let d = waitFor(20) { done in ble.readKeyEntry(cat: c, idx: idx) { done($0) } } ?? nil
            conn.send(d.map { "OK:" + TestHooks.hex($0) } ?? "ERR:READ_FAILED")
        case "WRITE", "WRITE_NOCOMMIT":
            guard let c = cat(a.first), a.count >= 3, let idx = UInt8(a[1]), let bytes = TestHooks.bytes(a[2]) else {
                conn.send("ERR:BAD_ARGS"); return
            }
            // UInt8(off) 在分块循环里会在 off > 255 时 trap；顺带也是条目大小的硬上限。
            guard bytes.count <= c.entrySize else { conn.send("ERR:BAD_ARGS"); return }
            if sub == "WRITE" {
                guard let token = DeviceActivityCoordinator.shared.tryBegin(.auth) else { conn.send("ERR:BUSY"); return }
                defer { DeviceActivityCoordinator.shared.end(token) }
                let stateLock = NSLock()
                var live = true // chain 的 body 结束（即将还原闭包）后置 false，之后不再写 fd
                var ok: Bool?
                chain(\.onFingerprintAttemptFailed, { left in
                    stateLock.lock(); let alive = live; stateLock.unlock()
                    if alive { conn.send("FP:FAIL:\(left)") }
                }, compose: { a, b in { a($0); b($0) } }) {
                    // N 个分块（默认各 5s）+ commit 命中门时最长 30s：api 类目最多
                    // 3 块 → 15s + 30s = 45s，取 50s 留 5s 余量。
                    ok = waitFor(50) { done in ble.writeKeyEntry(cat: c, idx: idx, data: Data(bytes)) { done($0) } }
                    stateLock.lock(); live = false; stateLock.unlock()
                }
                conn.send(ok == true ? "OK" : (ok == false ? "ERR:WRITE_FAILED" : "ERR:TIMEOUT"))
            } else {
                // 只发 KEY_WRITE 分块，不发 COMMIT（测「未 COMMIT 就读 / 单独 COMMIT」）
                var off = 0; var failed = false
                while off < bytes.count, !failed {
                    let len = min(59, bytes.count - off)
                    let payload = [c.rawValue, idx, UInt8(off)] + Array(bytes[off..<off + len])
                    let r = waitFor(6) { done in ble.testSendCommand(.keyWrite, payload: payload, timeout: 5) { done($0) } } ?? nil
                    if r?.first != 0x00 { failed = true } else { off += len }
                }
                conn.send(failed ? "ERR:WRITE_FAILED:\(off)" : "OK")
            }
        case "COMMIT":
            guard let c = cat(a.first), a.count >= 2, let idx = UInt8(a[1]) else { conn.send("ERR:BAD_ARGS"); return }
            // 走 testSendCommand 直发，不经 pendingGateCompletion：设备若回 0x11(WAIT_FP)
            // 说明进了门，但这里不会等指纹也不会转发 FP:FAIL——调用方（测试脚本）自己
            // 决定去摸一下，或者发 TEST:GATE_CANCEL 把设备那边挂着的门撤掉，否则下一条
            // 命令会先撞上这个未清的门。
            let r = waitFor(6) { done in ble.testSendCommand(.keyCommit, payload: [c.rawValue, idx], timeout: 5) { done($0) } } ?? nil
            conn.send(r.map { "OK:" + TestHooks.hex($0) } ?? "ERR:TIMEOUT")
        case "DELETE":
            guard let c = cat(a.first), a.count >= 2, let idx = UInt8(a[1]) else { conn.send("ERR:BAD_ARGS"); return }
            guard let token = DeviceActivityCoordinator.shared.tryBegin(.auth) else { conn.send("ERR:BUSY"); return }
            defer { DeviceActivityCoordinator.shared.end(token) }
            let stateLock = NSLock()
            var live = true // chain 的 body 结束（即将还原闭包）后置 false，之后不再写 fd
            var ok: Bool?
            chain(\.onFingerprintAttemptFailed, { left in
                stateLock.lock(); let alive = live; stateLock.unlock()
                if alive { conn.send("FP:FAIL:\(left)") }
            }, compose: { a, b in { a($0); b($0) } }) {
                // 门超时 30s，+10s 余量，与 SLOT_CLEAR 一致。
                ok = waitFor(40) { done in ble.deleteKeyEntry(cat: c, idx: idx) { done($0) } }
                stateLock.lock(); live = false; stateLock.unlock()
            }
            conn.send(ok == true ? "OK" : (ok == false ? "ERR:DELETE_FAILED" : "ERR:TIMEOUT"))
        case "SIGN":
            guard a.count >= 2, let idx = UInt8(a[0]), let h = TestHooks.bytes(a[1]), h.count == 32 else { conn.send("ERR:BAD_ARGS"); return }
            gatedData(conn) { done in ble.sshSign(idx: idx, hash: Data(h)) { done($0) } }
        case "GETPUB":
            guard let idx = a.first.flatMap(UInt8.init) else { conn.send("ERR:BAD_ARGS"); return }
            // 无门；sendCommand 默认 5s + readResultBuffer 单块默认 5s，+10s 余量。
            let d = waitFor(20) { done in ble.sshGetPublicKey(idx: idx) { done($0) } } ?? nil
            conn.send(d.map { "OK:" + TestHooks.hex($0) } ?? "ERR:FAILED")
        case "GENERATE":
            guard let name = a.first, !name.isEmpty else { conn.send("ERR:BAD_ARGS"); return }
            gatedString(conn) { done in ble.sshGenerateKey(name: name) { done($0.map { "\($0.idx):" + TestHooks.hex($0.publicKey) }) } }
        case "OTP":
            guard let idx = a.first.flatMap(UInt8.init) else { conn.send("ERR:BAD_ARGS"); return }
            gatedString(conn) { done in ble.requestOTP(idx: idx) { done($0) } }
        default: conn.send("ERR:UNKNOWN_TEST_COMMAND")
        }
    }

    /// 门内命令的公共壳（Data 结果）：拿活动锁、转发 FP:FAIL、50s 内等结果。
    /// 泛型版本在 `case .some(.some(let v as Data))` 上会被 Swift 拒绝做 as 转换
    /// （嵌套 Optional<Optional<T>> 里对 T 做 as 转换），所以按结果类型拆成两个具体版本。
    private func gatedData(_ conn: TestConn, _ body: (@escaping (Data?) -> Void) -> Void) {
        guard let token = DeviceActivityCoordinator.shared.tryBegin(.auth) else { conn.send("ERR:BUSY"); return }
        defer { DeviceActivityCoordinator.shared.end(token) }
        let stateLock = NSLock()
        var live = true // chain 的 body 结束（即将还原闭包）后置 false，之后不再写 fd
        var out: Data??
        chain(\.onFingerprintAttemptFailed, { left in
            stateLock.lock(); let alive = live; stateLock.unlock()
            if alive { conn.send("FP:FAIL:\(left)") }
        }, compose: { a, b in { a($0); b($0) } }) {
            // 门超时 30s + readResultBuffer 分块读（默认各 5s，最多约 2 块）
            // ≈ 40s 最坏情况，50s 留 10s 余量。
            out = waitFor(50) { done in body { done($0) } }
            stateLock.lock(); live = false; stateLock.unlock()
        }
        switch out {
        case .some(.some(let v)): conn.send("OK:" + TestHooks.hex(v))
        case .some(.none): conn.send("ERR:DENIED")
        case .none: conn.send("ERR:TIMEOUT")
        }
    }

    /// 门内命令的公共壳（String 结果），同上。
    private func gatedString(_ conn: TestConn, _ body: (@escaping (String?) -> Void) -> Void) {
        guard let token = DeviceActivityCoordinator.shared.tryBegin(.auth) else { conn.send("ERR:BUSY"); return }
        defer { DeviceActivityCoordinator.shared.end(token) }
        let stateLock = NSLock()
        var live = true // chain 的 body 结束（即将还原闭包）后置 false，之后不再写 fd
        var out: String??
        chain(\.onFingerprintAttemptFailed, { left in
            stateLock.lock(); let alive = live; stateLock.unlock()
            if alive { conn.send("FP:FAIL:\(left)") }
        }, compose: { a, b in { a($0); b($0) } }) {
            // 门超时 30s + readResultBuffer（GENERATE 最坏情况约 45s：门 30s +
            // 分块读 ~2 块 × 5s + 若干重试余量），50s 留够。
            out = waitFor(50) { done in body { done($0) } }
            stateLock.lock(); live = false; stateLock.unlock()
        }
        switch out {
        case .some(.some(let v)): conn.send("OK:" + v)
        case .some(.none): conn.send("ERR:DENIED")
        case .none: conn.send("ERR:TIMEOUT")
        }
    }

    private var otaTask: Task<Void, Never>?

    private func handleOta(_ conn: TestConn, _ req: TestRequest) {
        guard ble.testIsConnected else { conn.send("ERR:NOT_CONNECTED"); return }
        let path = req.rest
        guard let data = FileManager.default.contents(atPath: path) else { conn.send("ERR:NO_FILE"); return }
        let pkg: IMFWPackage
        do { pkg = try IMFWPackage(data: data) } catch { conn.send("ERR:BAD_IMFW:\(error)"); return }
        guard let token = DeviceActivityCoordinator.shared.tryBegin(.auth) else { conn.send("ERR:BUSY"); return }
        defer { DeviceActivityCoordinator.shared.end(token) }
        let sem = DispatchSemaphore(value: 0)
        let stateLock = NSLock()
        var live = true      // sem.wait 返回后立即置 false，之后 progress 闭包不再写 fd
        var outcome = "ERR:TIMEOUT"
        var lastPct = -1
        // 不订阅链路 .disconnected 兜底成功/失败：pass path 里固件对 END 命令从不回
        // ACK，只是 ~200ms 后重启——OTAEngine 把 END 的 nil 读当作"已重启=成功"
        // （push() 里的注释：无响应 = 已重启 = 成功）。BLEManager 里
        // testEventTap?(.disconnected(...)) 先于 otaReadCallback?(nil) 触发，若在
        // 这里挂 .disconnected 订阅会让每一次成功的 OTA 都被提前误判成
        // ERR:DISCONNECTED，抢在 push() 真正返回 OK 之前定案（round 1 的回归）。
        // 现在完全靠 push() 自己的 do/catch 决定结果：PROM 阶段断链已经由
        // BLEManager.didDisconnectPeripheral 对 otaWriteReadyCallback 以 false 唤醒
        // 背压等待，push() 会抛 writeFailed；INFO/ERASE/HEADER 断链则是
        // writeAndRead 超时返回 nil，push() 直接抛 noResponse。
        func settle(_ o: String) {
            stateLock.lock()
            outcome = o
            stateLock.unlock()
        }
        lock.lock()
        otaTask = Task {
            do {
                try await OTAEngine(transport: ble).push(pkg) { p in
                    stateLock.lock()
                    let alive = live
                    let pct = Int(p * 100)
                    let changed = pct != lastPct
                    if changed { lastPct = pct }
                    stateLock.unlock()
                    if alive && changed { conn.send("PROGRESS:\(pct)") }
                }
                settle("OK")
            } catch {
                settle("ERR:\(error)")
            }
            sem.signal()
        }
        lock.unlock()
        _ = sem.wait(timeout: .now() + 600)
        stateLock.lock(); live = false; let out = outcome; stateLock.unlock()
        lock.lock(); otaTask = nil; lock.unlock()
        conn.send(out)
    }

    /// 中断推送：断链让 transport 写失败，push 抛错收尾（真正解除阻塞靠
    /// BLEManager.didDisconnectPeripheral 里对 otaWriteReadyCallback 的兜底，
    /// 见该处注释；otaTask.cancel() 本身 OTAEngine.push 不检查，只是清理占位）。
    private func handleOtaAbort(_ conn: TestConn) {
        lock.lock(); let task = otaTask; lock.unlock()
        task?.cancel()
        ble.disconnect()
        conn.send("OK")
    }

    /// 写 OTA 特征并读回（IAP 协议边界用，P8-06）。可选第二段参数覆盖默认 5000ms
    /// 超时（毫秒）——某些边界帧（例如没发任何 PROM 数据的 END）真机判定得比正常
    /// 慢，默认超时会把"还没判完"误报成 NORX。
    private func handleOtaRaw(_ conn: TestConn, _ req: TestRequest) {
        guard ble.testIsConnected else { conn.send("ERR:NOT_CONNECTED"); return }
        guard let raw = req.args.first, let bytes = TestHooks.bytes(raw) else { conn.send("ERR:BAD_HEX"); return }
        let timeoutMs = req.args.count > 1 ? (Double(req.args[1]) ?? 5000) : 5000
        let timeout = timeoutMs / 1000
        let r = waitFor(timeout + 2) { done in ble.otaWriteAndRead(data: Data(bytes), timeout: timeout) { done($0) } } ?? nil
        conn.send(r.map { "OK:" + TestHooks.hex($0) } ?? "OK:NORX")
    }

    private func handleDisconnect(_ conn: TestConn) { ble.disconnect(); conn.send("OK") }
    private func handleReconnect(_ conn: TestConn) { ble.connect(); conn.send("OK") }

    private func handleSubscribe(_ conn: TestConn) {
        let q = DispatchQueue(label: "immurok.testhooks.sub")
        // 先排 OK:SUBSCRIBED 再 subscribe，保证 q 上不会有任何事件行排到确认行前面。
        q.async { conn.send("OK:SUBSCRIBED") }
        var closed = false                       // 只在 q 上读写
        let sub = subscribe { ev in
            q.async { guard !closed else { return }; TestHooks.lines(for: ev).forEach { conn.send($0) } }
        }
        while !conn.peerClosed(timeoutMs: 1000) {}
        unsubscribe(sub)
        // unsubscribe 只挡住新事件；一次 broadcast 若在 unsubscribe 前已经拿到订阅者快照，
        // 它排进 q 的闭包仍可能在下面这次 q.sync 之后才执行——那时 handler 已经返回、
        // CLISocketServer 关掉（甚至复用）了 fd。closed 标志只在 q 上读写，q.sync 把它
        // 置 true 之后，所有排在其后的闭包都能看到并放弃写 fd。
        q.sync { closed = true }
    }
}
#endif

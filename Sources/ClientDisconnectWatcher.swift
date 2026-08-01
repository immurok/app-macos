/*
 * ClientDisconnectWatcher.swift - Notice when a terminal client goes away
 *
 * Every fingerprint-gated flow that originates in a terminal (sudo via the PAM
 * module, `imk get`, `imk run --agent`, ssh/git via the SSH agent) parks the
 * App on a DispatchSemaphore for 30-50 s while the device waits for a touch.
 * If the user hits Ctrl+C, the client process dies immediately — but nothing
 * told the App, so the device kept blinking and the terminal spinner kept
 * repainting over the freshly printed shell prompt until the timeout expired.
 * That is what made Ctrl+C look like it did nothing.
 *
 * This watcher polls the accepted client socket for EOF on a background
 * thread and fires `onDisconnect` the moment the peer is gone, so the caller
 * can drop the device gate (GATE_CANCEL) and stop drawing.
 */

import Foundation

final class ClientDisconnectWatcher {

    private let fd: Int32
    private let onDisconnect: () -> Void
    private let lock = NSLock()
    private var finished = false
    private var wakeRead: Int32 = -1
    private var wakeWrite: Int32 = -1

    /// Start watching `socket` for peer disconnect. The callback runs at most
    /// once, on a background thread, and never after `stop()` returns.
    @discardableResult
    static func start(socket fd: Int32, onDisconnect: @escaping () -> Void) -> ClientDisconnectWatcher {
        let watcher = ClientDisconnectWatcher(fd: fd, onDisconnect: onDisconnect)
        watcher.run()
        return watcher
    }

    private init(fd: Int32, onDisconnect: @escaping () -> Void) {
        self.fd = fd
        self.onDisconnect = onDisconnect

        var fds: [Int32] = [-1, -1]
        if pipe(&fds) == 0 {
            wakeRead = fds[0]
            wakeWrite = fds[1]
        }
    }

    /// Stop watching. Safe to call multiple times, and safe to call from the
    /// normal completion path — it guarantees the callback won't fire
    /// afterwards (which would otherwise cancel a *subsequent* gate).
    func stop() {
        lock.lock()
        finished = true
        if wakeWrite >= 0 {
            // Wake the poll thread so it exits. The read end is only ever
            // closed by that thread under this same lock, so it is still open
            // here — no EPIPE/SIGPIPE.
            var byte: UInt8 = 1
            _ = write(wakeWrite, &byte, 1)
            close(wakeWrite)
            wakeWrite = -1
        }
        lock.unlock()
    }

    // MARK: - Private

    private func run() {
        guard wakeRead >= 0 else {
            // No self-pipe → we could never stop the thread cleanly. Skip
            // watching entirely rather than leak a thread per request.
            NSLog("ClientDisconnectWatcher: pipe() failed, disconnect detection off")
            return
        }

        DispatchQueue.global(qos: .utility).async { [self] in
            var pfds = [
                pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0)
            ]

            loop: while true {
                let ready = poll(&pfds, 2, -1)
                if ready < 0 {
                    if errno == EINTR { continue }
                    break
                }

                // stop() was called — leave without firing.
                if pfds[1].revents != 0 { break }

                if pfds[0].revents != 0 {
                    var byte: UInt8 = 0
                    let n = recv(fd, &byte, 1, MSG_PEEK)
                    if n == 0 {
                        // Clean EOF: the client process is gone.
                        fire()
                        break loop
                    }
                    if n < 0 {
                        if errno == EINTR || errno == EAGAIN { continue }
                        // Socket error — treat the peer as gone.
                        fire()
                        break loop
                    }
                    // Unread data pending. No client sends anything mid-wait,
                    // but if one ever does, drop this fd from the set instead
                    // of spinning on a permanently-readable socket.
                    NSLog("ClientDisconnectWatcher: unexpected client data, stopping EOF watch")
                    pfds[0].fd = -1
                }
            }

            // Thread teardown: just close both ends. Writing a wake byte here
            // would go into a pipe whose read end we are closing — EPIPE, and
            // SIGPIPE in any host that doesn't ignore it.
            lock.lock()
            if wakeRead >= 0 { close(wakeRead); wakeRead = -1 }
            if wakeWrite >= 0 { close(wakeWrite); wakeWrite = -1 }
            lock.unlock()
        }
    }

    private func fire() {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()
        onDisconnect()
    }
}

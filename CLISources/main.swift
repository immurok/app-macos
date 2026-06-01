/*
 * imk - immurok CLI key injection tool
 *
 * Usage:
 *   imk list [ssh|otp|api]              List key names
 *   imk get imk://category/name         Output secret to stdout
 *   imk run [--env-file FILE] -- CMD    Inject secrets and run subprocess
 *   imk version                         Print version
 */

import Foundation

let version = "1.0.0"

// MARK: - Main

func main() -> Int32 {
    let args = Array(CommandLine.arguments.dropFirst())

    guard let command = args.first else {
        printUsage()
        return 1
    }

    switch command {
    case "list":
        return cmdList(Array(args.dropFirst()))
    case "get":
        return cmdGet(Array(args.dropFirst()))
    case "run":
        return cmdRun(Array(args.dropFirst()))
    case "version", "--version", "-v":
        print("imk \(version)")
        return 0
    case "help", "--help", "-h":
        printUsage()
        return 0
    default:
        stderr("Unknown command: \(command)")
        printUsage()
        return 1
    }
}

// MARK: - list

func cmdList(_ args: [String]) -> Int32 {
    let category = args.first ?? ""

    if category.isEmpty {
        stderr("Usage: imk list <ssh|otp|api>")
        return 1
    }

    guard ["ssh", "otp", "api"].contains(category) else {
        stderr("Unknown category: \(category)")
        return 1
    }

    do {
        let response = try CLIClient.send("LIST:\(category)")

        if let error = CLIClient.checkError(response) {
            stderr("Error: \(error)")
            return 1
        }

        // Parse multi-line response: OK:count\nname1\nname2...
        let lines = response.split(separator: "\n", omittingEmptySubsequences: false)
        guard let firstLine = lines.first, firstLine.hasPrefix("OK:") else {
            stderr("Unexpected response")
            return 1
        }

        let countStr = firstLine.dropFirst(3)
        guard let count = Int(countStr) else {
            stderr("Invalid count: \(countStr)")
            return 1
        }

        if count == 0 {
            stderr("No \(category) keys found")
            return 0
        }

        // Print names (lines after the first)
        for i in 1..<lines.count {
            let name = lines[i]
            if !name.isEmpty {
                print(name)
            }
        }

        return 0
    } catch {
        stderr("Error: \(error)")
        return 1
    }
}

// MARK: - get

func cmdGet(_ args: [String]) -> Int32 {
    guard let ref = args.first else {
        stderr("Usage: imk get imk://category/name")
        return 1
    }

    let prefix = "imk://"
    let refBody: String
    if ref.hasPrefix(prefix) {
        refBody = String(ref.dropFirst(prefix.count))
    } else {
        // Also accept category/name directly
        refBody = ref
    }

    let parts = refBody.split(separator: "/", maxSplits: 1)
    guard parts.count == 2 else {
        stderr("Invalid reference: \(ref) (expected imk://category/name)")
        return 1
    }

    let category = String(parts[0])
    let name = String(parts[1])

    do {
        let response = try CLIClient.send("GET:\(category):\(name)")

        if let error = CLIClient.checkError(response) {
            stderr("Error: \(error)")
            return 1
        }

        guard response.hasPrefix("OK:") else {
            stderr("Unexpected response")
            return 1
        }

        // Output value to stdout. Add a trailing newline only when stdout
        // is a TTY (interactive use) — keeps `export X=$(imk get ...)`
        // command-substitution behavior (which strips trailing \n anyway)
        // unchanged while avoiding zsh's "%" no-newline marker on direct
        // calls. Pipes / redirects still get raw bytes only.
        let value = String(response.dropFirst(3))
        if isatty(fileno(stdout)) != 0 {
            print(value)
        } else {
            print(value, terminator: "")
        }

        return 0
    } catch {
        stderr("Error: \(error)")
        return 1
    }
}

// MARK: - run

func cmdRun(_ args: [String]) -> Int32 {
    var envFiles: [String] = []
    var isAgent = false
    var cmdArgs: [String] = []
    var parsingFlags = true

    var i = 0
    while i < args.count {
        if parsingFlags {
            if args[i] == "--" {
                parsingFlags = false
                i += 1
                continue
            } else if args[i] == "--env-file" {
                i += 1
                guard i < args.count else {
                    stderr("--env-file requires an argument")
                    return 1
                }
                envFiles.append(args[i])
                i += 1
                continue
            } else if args[i].hasPrefix("--env-file=") {
                let val = String(args[i].dropFirst("--env-file=".count))
                envFiles.append(val)
                i += 1
                continue
            } else if args[i] == "--agent" {
                isAgent = true
                i += 1
                continue
            }
        }
        cmdArgs.append(args[i])
        i += 1
    }

    guard !cmdArgs.isEmpty else {
        stderr("Usage: imk run [--env-file FILE] [--agent] -- COMMAND [ARGS...]")
        return 1
    }

    // Pre-flight: bail before AgentApproval if the wrapped command would need
    // SSH but no key is configured on the device. Otherwise the subprocess
    // (git push / ssh / scp / rsync) silently falls back to interactive
    // password auth and hangs on stdin — and the user already burned a
    // fingerprint touch on the (now useless) approval.
    if let bail = sshPreflightFailure(cmdArgs: cmdArgs) {
        stderr(bail)
        return 78  // EX_CONFIG
    }

    // Agent mode: ask the App for explicit pre-execution approval BEFORE we
    // launch anything. The overlay surfaces the wrapped command, user
    // fingerprints → App grants approval + sets a sudo pre-auth window so
    // any sudo inside the wrapped command auto-passes without prompting
    // again. User clicks close (or 30s timeout) → we abort with non-zero.
    //
    // This covers commands that don't go through PAM at all (git pull, rm,
    // npm install, ...), which the prior PAM-only overlay missed.
    let cmdString = cmdArgs.joined(separator: " ")
    if isAgent {
        switch AgentApproval.request(command: cmdString) {
        case .approved:
            break
        case .rejected:
            stderr("imk: agent command rejected by user")
            return 77  // EX_NOPERM
        case .error(let msg):
            stderr("imk: agent approval failed: \(msg)")
            return 1
        }
        // Marker is defense-in-depth: if the 5-min sudo pre-auth window
        // expires mid-command and a late sudo arrives, the App-side caller
        // classifier still recognises this as agent-initiated.
        AgentMarker.write(command: cmdString)
    }
    defer { if isAgent { AgentMarker.remove() } }

    // Build environment: start with current process env
    var env = ProcessInfo.processInfo.environment

    // Load .env files (later files override earlier ones)
    for envFile in envFiles {
        do {
            let pairs = try EnvScanner.parseEnvFile(at: envFile)
            for (key, value) in pairs {
                env[key] = value
            }
        } catch {
            stderr("Error loading \(envFile): \(error)")
            return 1
        }
    }

    // Resolve all imk:// references
    do {
        try EnvScanner.resolveReferences(&env)
    } catch {
        stderr("Error: \(error)")
        return 1
    }

    // Launch subprocess
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = cmdArgs
    process.environment = env

    // Forward signals
    let sigSources = setupSignalForwarding(to: process)

    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        stderr("Failed to run \(cmdArgs[0]): \(error)")
        return 1
    }

    // Clean up signal sources
    for src in sigSources { src.cancel() }

    return process.terminationStatus
}

/// Forward SIGINT/SIGTERM to child process
func setupSignalForwarding(to process: Process) -> [DispatchSourceSignal] {
    var sources: [DispatchSourceSignal] = []

    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        src.setEventHandler {
            if process.isRunning {
                kill(process.processIdentifier, sig)
            }
        }
        src.resume()
        sources.append(src)
    }

    return sources
}

// MARK: - Helpers

func stderr(_ msg: String) {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
}

/// Returns an error message if the wrapped command would need an SSH key on
/// the device but none is configured; nil if the check passes (or doesn't apply).
///
/// Why: `git push` / `ssh` / `scp` / `rsync` quietly fall back to interactive
/// password auth when the SSH agent has no usable identity. The terminal then
/// blocks on stdin and looks like a hang — and in --agent mode the user has
/// already burned a fingerprint touch on the (now useless) approval.
///
/// Conservative scope: only blocks when we're confident SSH is actually
/// needed. For `git`, that means the resolved remote URL is `git@host:` or
/// `ssh://`; HTTPS remotes go through unconditionally.
func sshPreflightFailure(cmdArgs: [String]) -> String? {
    guard let cmd0 = cmdArgs.first else { return nil }
    let bin = (cmd0 as NSString).lastPathComponent

    let strictlyNeedsSSH = ["ssh", "scp", "sftp", "rsync"].contains(bin)
    let mightNeedSSH = (bin == "git" && cmdArgs.count > 1
                        && ["push", "pull", "fetch", "clone", "ls-remote"].contains(cmdArgs[1]))

    guard strictlyNeedsSSH || mightNeedSSH else { return nil }

    // For git: only flag if the remote is SSH-style. HTTPS users don't need
    // the device's SSH key.
    if mightNeedSSH && !strictlyNeedsSSH {
        // `git X` where X is push/pull/fetch — second positional after that
        // is usually the remote name (defaults to "origin"). For `git clone`
        // the URL is the second arg directly; we just rely on its prefix.
        var remoteURL = ""
        if cmdArgs[1] == "clone" {
            // `git clone <url> [dir]`
            if cmdArgs.count >= 3 { remoteURL = cmdArgs[2] }
        } else {
            // `git push|pull|fetch [remote] ...` — assume positional remote
            // before any flag, default origin.
            let remoteName = (cmdArgs.count > 2 && !cmdArgs[2].hasPrefix("-"))
                             ? cmdArgs[2] : "origin"
            remoteURL = runShellCapture("git", "remote", "get-url", remoteName) ?? ""
        }
        let isSSH = remoteURL.hasPrefix("git@")
                    || remoteURL.hasPrefix("ssh://")
                    || remoteURL.hasPrefix("git+ssh://")
        if !isSSH { return nil }
    }

    // Query the App's SSH key cache. If the app isn't running we can't tell —
    // let the command run (it'll fail naturally).
    let resp: String
    do {
        resp = try CLIClient.send("LIST:ssh")
    } catch {
        return nil
    }
    let firstLine = resp.split(separator: "\n").first.map(String.init) ?? ""
    guard firstLine.hasPrefix("OK:") else { return nil }
    let countStr = firstLine.dropFirst(3)
    guard let count = Int(countStr), count == 0 else { return nil }

    return """
    imk: \(bin) needs an SSH key but none is configured on the device.
         Configure via the immurok app → Settings → SSH keys, then retry.
         (Run without `imk run --agent` if this command shouldn't use the device.)
    """
}

/// Run a shell command, return trimmed stdout on success, nil on failure.
private func runShellCapture(_ args: String...) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = args
    let outPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = Pipe()
    do {
        try p.run()
        p.waitUntilExit()
    } catch {
        return nil
    }
    guard p.terminationStatus == 0 else { return nil }
    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
}

func printUsage() {
    stderr("""
    Usage: imk <command> [options]

    Commands:
      list <ssh|otp|api>               List key names
      get imk://category/name          Output secret value to stdout
      run [opts] -- CMD                Inject secrets / mark as agent
                                       opts: --env-file FILE
                                             --agent NAME   (label run as
                                                             AI agent for
                                                             auth overlay)
      version                          Print version

    Examples:
      imk list api
      imk get imk://api/openai
      export TOKEN=$(imk get imk://api/github)
      imk run --env-file .env -- python3 app.py
    """)
}

// MARK: - Entry Point

exit(main())

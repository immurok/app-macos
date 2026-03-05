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

        // Output value to stdout (no trailing newline for pipe compatibility)
        let value = String(response.dropFirst(3))
        print(value, terminator: "")

        return 0
    } catch {
        stderr("Error: \(error)")
        return 1
    }
}

// MARK: - run

func cmdRun(_ args: [String]) -> Int32 {
    var envFiles: [String] = []
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
            }
        }
        cmdArgs.append(args[i])
        i += 1
    }

    guard !cmdArgs.isEmpty else {
        stderr("Usage: imk run [--env-file FILE] -- COMMAND [ARGS...]")
        return 1
    }

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

func printUsage() {
    stderr("""
    Usage: imk <command> [options]

    Commands:
      list <ssh|otp|api>               List key names
      get imk://category/name          Output secret value to stdout
      run [--env-file FILE] -- CMD     Inject secrets and run subprocess
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

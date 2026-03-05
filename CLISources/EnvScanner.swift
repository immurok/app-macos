/*
 * EnvScanner.swift - .env file parser and imk:// reference resolver
 *
 * Parses .env files and resolves imk:// references via CLIClient.
 */

import Foundation

struct EnvScanner {

    /// Parse a .env file into key-value pairs
    /// Supports: KEY=VALUE, KEY="VALUE", KEY='VALUE', # comments, empty lines
    static func parseEnvFile(at path: String) throws -> [(key: String, value: String)] {
        let content = try String(contentsOfFile: path, encoding: .utf8)
        var result: [(key: String, value: String)] = []

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip empty lines and comments
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            // Split on first '='
            guard let eqIdx = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[trimmed.startIndex..<eqIdx])
                .trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: eqIdx)...])
                .trimmingCharacters(in: .whitespaces)

            // Strip surrounding quotes
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
               (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }

            guard !key.isEmpty else { continue }
            result.append((key: key, value: value))
        }

        return result
    }

    /// Resolve all imk:// references in an environment dictionary
    /// Returns the resolved environment and any errors encountered
    static func resolveReferences(_ env: inout [String: String]) throws {
        let prefix = "imk://"

        for (key, value) in env {
            guard value.hasPrefix(prefix) else { continue }

            // Parse imk://category/name
            let ref = String(value.dropFirst(prefix.count))
            let parts = ref.split(separator: "/", maxSplits: 1)
            guard parts.count == 2 else {
                throw ResolveError.invalidReference(value)
            }

            let category = String(parts[0])
            let name = String(parts[1])

            // Send GET command
            let response = try CLIClient.send("GET:\(category):\(name)")

            if let error = CLIClient.checkError(response) {
                throw ResolveError.serverError(key: key, ref: value, error: error)
            }

            // Strip "OK:" prefix
            guard response.hasPrefix("OK:") else {
                throw ResolveError.unexpectedResponse(response)
            }

            env[key] = String(response.dropFirst(3))
        }
    }
}

enum ResolveError: Error, CustomStringConvertible {
    case invalidReference(String)
    case serverError(key: String, ref: String, error: String)
    case unexpectedResponse(String)

    var description: String {
        switch self {
        case .invalidReference(let ref):
            return "Invalid reference: \(ref) (expected imk://category/name)"
        case .serverError(let key, let ref, let error):
            return "Failed to resolve \(key)=\(ref): \(error)"
        case .unexpectedResponse(let resp):
            return "Unexpected server response: \(resp)"
        }
    }
}

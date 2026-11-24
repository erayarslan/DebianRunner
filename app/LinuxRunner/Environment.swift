import Foundation

struct LinuxApplication: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var command: String
    var arguments: [String] = []
    var environment: [String: String]?
    var workingDirectory = "/root"

    // Literal argv identity persists across discovery refreshes without relying
    // on transient UUIDs or shell-formatted commands.
    var launchKey: String {
        (try? JSONEncoder().encode([command, workingDirectory] + arguments).base64EncodedString()) ?? command
    }

    func validate() throws {
        let env = environment ?? [:]
        guard env.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count + 2 }) <= 4096,
              env.allSatisfy({ key, value in
                  key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil &&
                  !value.contains("\0") && key.utf8.count + value.utf8.count <= 4096
              }),
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              command.hasPrefix("/"), workingDirectory.hasPrefix("/"),
              !command.contains("\0"), !workingDirectory.contains("\0"),
              !arguments.contains(where: { $0.contains("\0") }),
              ([command] + arguments).reduce(1, { $0 + $1.utf8.count + 1 }) <= 4096 else {
            throw EnvironmentError.invalidCommand
        }
    }
}

struct LinuxEnvironment: Codable, Identifiable {
    var id = UUID()
    var name: String
    var distribution = "Debian GNU/Linux"
    var distributionID: String? = "debian"
    var packageManager: String? = "apt"
    var environmentVariables: [String: String]?
    var installationState: String?
    var lastBootResult: String?
    var storageBytes: Int64?
    var diagnosticHistory: [String]?
    var architecture = "arm64"
    // Relative to Roots' container. Never persist an absolute sandbox path.
    var rootfsName: String
    var defaultShell: String? = "/bin/bash"
    var homePath = "/root"
    var rootfsVersion = "13.7"
    var createdAt = Date()
    var lastBootedAt: Date?
    var runtimeConfiguration = ["backend": "asbestos", "jit": "false"]
    var applications = [
        LinuxApplication(name: "Bash Shell", command: "/bin/bash", arguments: ["-l"]),
        LinuxApplication(name: "System information", command: "/bin/uname", arguments: ["-a"])
    ]
    // State and storage are measured at runtime, never restored as Running.
}

struct LinuxPackageRecord: Identifiable {
    var id: String { name }
    let name, version, architecture, status, summary: String
    static func parse(_ text: String) -> [Self] {
        var seen = Set<String>()
        return text.components(separatedBy: .newlines).prefix(2000).compactMap { line in
            let fields = line.components(separatedBy: "\t")
            guard fields.count >= 4, PackageOperation.validName(fields[0]), seen.insert(fields[0]).inserted else { return nil }
            return Self(name: fields[0], version: fields[1], architecture: fields[2], status: fields[3], summary: fields.count > 4 ? fields[4] : "")
        }
    }
}

enum PackageOperation {
    static func validName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.range(of: "^[A-Za-z0-9][A-Za-z0-9+._:-]*$", options: .regularExpression) != nil
    }
    static func command(_ operation: String, value: String = "") throws -> [String] {
        let named = ["search", "details", "install", "upgrade", "remove", "plan-install", "plan-remove", "plan-upgrade", "apply-install", "apply-remove", "apply-upgrade"]
        guard (["installed", "updates", "update", "diagnose", "configure", "dependencies", "repair", "catalog"] + named).contains(operation),
              !named.contains(operation) || validName(value) else { throw EnvironmentError.invalidCommand }
        return ["/bin/sh", "/home/mobile/Downloads/.linuxrunner/support/package-manager.sh", operation, value]
    }
}

enum EnvironmentError: LocalizedError {
    case invalidCommand, invalidMetadata
    var errorDescription: String? {
        switch self {
        case .invalidCommand: return "Use an absolute guest executable and directory. Arguments must fit within 4 KiB and contain no NUL characters."
        case .invalidMetadata: return "Environment metadata is invalid. The existing file has been preserved."
        }
    }
}

struct EnvironmentCatalog: Codable {
    var schemaVersion = 1
    var environments: [LinuxEnvironment]
    static func read(_ url: URL) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard value.schemaVersion == 1,
              Set(value.environments.map(\.id)).count == value.environments.count,
              Set(value.environments.map(\.rootfsName)).count == value.environments.count,
              value.environments.allSatisfy({ validRootName($0.rootfsName) }) else {
            throw EnvironmentError.invalidMetadata
        }
        for environment in value.environments {
            for application in environment.applications { try application.validate() }
        }
        return value
    }
    func write(_ url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
    static func validRootName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." &&
        !name.contains("/") && !name.contains("\\") && !name.contains("\0")
    }
}

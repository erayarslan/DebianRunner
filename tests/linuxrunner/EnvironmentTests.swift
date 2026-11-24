import Foundation

@main struct Tests {
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("environments.json")
        let original = LinuxEnvironment(name: "Test Debian Minimal", rootfsName: UUID().uuidString)
        precondition(original.distributionID == "debian")
        precondition(original.packageManager == "apt")
        try EnvironmentCatalog(environments: [original]).write(url)
        let restored = try EnvironmentCatalog.read(url)
        precondition(restored.environments[0].id == original.id)
        precondition(restored.environments[0].rootfsName == original.rootfsName)
        precondition(restored.environments[0].applications == original.applications)
        for bad in ["", ".", "..", "a/b", "a\\b", "nul\0"] { precondition(!EnvironmentCatalog.validRootName(bad)) }
        for app in [
            LinuxApplication(name: "bad", command: "relative"),
            LinuxApplication(name: "bad", command: "/bin/sh", arguments: ["x\0y"]),
            LinuxApplication(name: "bad", command: "/bin/sh", arguments: [String(repeating: "x", count: 4096)]),
        ] {
            do { try app.validate(); fatalError("accepted invalid command") } catch {}
        }
        var cli = LinuxApplication(name: "Python", command: "/usr/bin/python3", arguments: ["--version"])
        cli.environment = ["PYTHONUNBUFFERED": "1"]
        try cli.validate()
        var withCLI = original
        withCLI.applications.append(cli)
        try EnvironmentCatalog(environments: [withCLI]).write(url)
        let cliRoundTrip = try EnvironmentCatalog.read(url)
        precondition(cliRoundTrip.environments[0].applications.last == cli)
        let oldEncoder = JSONEncoder()
        var old = try JSONSerialization.jsonObject(with: oldEncoder.encode(EnvironmentCatalog(environments: [original]))) as! [String: Any]
        var oldEnvironments = old["environments"] as! [[String: Any]]
        for key in ["distributionID", "packageManager", "environmentVariables"] { oldEnvironments[0].removeValue(forKey: key) }
        old["environments"] = oldEnvironments
        try JSONSerialization.data(withJSONObject: old).write(to: url)
        let oldRoundTrip = try EnvironmentCatalog.read(url)
        precondition(oldRoundTrip.environments[0].id == original.id)
        let unsupported = Data("{\"schemaVersion\":9,\"environments\":[]}".utf8)
        try unsupported.write(to: url)
        do { _ = try EnvironmentCatalog.read(url); fatalError("accepted unsupported schema") } catch {}
        let preserved = try Data(contentsOf: url)
        precondition(preserved == unsupported)
        print("PASS: metadata persistence, stable IDs, launcher round-trip, invalid paths/argv, schema rejection preserves file")
    }
}

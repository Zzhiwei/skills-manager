import Foundation

/// One entry of `claude plugin list --json`.
struct PluginInfo: Decodable {
    let id: String
    let version: String?
    let scope: String
    let enabled: Bool
    let projectPath: String?
}

/// Thin wrapper over the `claude plugin` CLI, which owns plugin state.
enum PluginCLI {
    // Apps launched from Finder don't get the shell PATH, so look in the usual install spots.
    static let executable: URL? = ["~/.local/bin/claude", "~/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        .map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
        .first { FileManager.default.isExecutableFile(atPath: $0.path) }

    struct Failure: LocalizedError { let errorDescription: String? }

    /// Runs `claude plugin <args>` in `dir` (local-scope plugins are tied to their project dir).
    static func run(_ args: [String], in dir: String? = nil) async throws -> Data {
        guard let exe = executable else { throw Failure(errorDescription: "Claude Code CLI (`claude`) not found.") }
        // Blocking pipe reads run on a GCD thread, keeping them off Swift's cooperative pool.
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async { cont.resume(with: Result { try runSync(exe, args, in: dir) }) }
        }
    }

    private static func runSync(_ exe: URL, _ args: [String], in dir: String?) throws -> Data {
        let p = Process()
        p.executableURL = exe
        p.arguments = ["plugin"] + args
        p.currentDirectoryURL = URL(fileURLWithPath: dir ?? NSHomeDirectory())
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        try p.run()
        // Drain stderr concurrently so neither pipe can fill up and block the child.
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: errData.isEmpty ? outData : errData, as: UTF8.self)
            throw Failure(errorDescription: "claude plugin \(args.joined(separator: " ")) failed:\n\(msg)")
        }
        return outData
    }

    /// Installed plugins keyed by id. Local-scope entries are re-read from their project dir,
    /// since `enabled` is reported relative to the working directory.
    static func list() async throws -> [String: PluginInfo] {
        var all = try JSONDecoder().decode([PluginInfo].self, from: await run(["list", "--json"]))
        for dir in Set(all.compactMap(\.projectPath)) {
            let local = try JSONDecoder().decode([PluginInfo].self, from: await run(["list", "--json"], in: dir))
            all.removeAll { $0.projectPath == dir }
            all += local.filter { $0.projectPath == dir }
        }
        // ponytail: a plugin installed in several scopes shows (and is acted on) as its first install only.
        return Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Runs enable/disable/update/uninstall against the plugin's own scope and project.
    static func act(_ command: String, on plugin: PluginInfo) async throws {
        _ = try await run([command, plugin.id, "--scope", plugin.scope], in: plugin.projectPath)
    }
}

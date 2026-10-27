import Foundation

struct Source: Hashable {
    enum Kind: Hashable { case global, project(String), plugin(id: String) }
    let label: String
    let kind: Kind
}

struct Skill: Identifiable {
    var id: String { realURL.path }
    let name: String
    let description: String
    let realURL: URL
    var entries: [URL] = []   // where it was found inside skills dirs; may be symlinks to realURL
    var sources: [Source] = []
    var readOnly: Bool { sources.contains { if case .plugin = $0.kind { true } else { false } } }
}

enum Scanner {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    static func sources(projects: [String]) -> [(URL, Source)] {
        var out = ["~/.agents/skills", "~/.claude/skills"].map {
            (URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath), Source(label: $0, kind: .global))
        }
        for p in projects {
            let name = URL(fileURLWithPath: p).lastPathComponent
            for sub in [".claude/skills", ".agents/skills"] {
                out.append((URL(fileURLWithPath: p).appendingPathComponent(sub), Source(label: name, kind: .project(p))))
            }
        }
        // Only currently installed plugin versions, not every stale copy in the cache.
        struct Installed: Decodable { struct Install: Decodable { let installPath: String }; let plugins: [String: [Install]] }
        let file = home.appendingPathComponent(".claude/plugins/installed_plugins.json")
        if let data = try? Data(contentsOf: file), let installed = try? JSONDecoder().decode(Installed.self, from: data) {
            for (key, installs) in installed.plugins {
                let label = String(key.split(separator: "@").first ?? Substring(key))
                for i in installs {
                    out.append((URL(fileURLWithPath: i.installPath).appendingPathComponent("skills"), Source(label: label, kind: .plugin(id: key))))
                }
            }
        }
        return out
    }

    static func scan(_ dirs: [(URL, Source)]) -> [Skill] {
        let fm = FileManager.default
        var byReal: [String: Skill] = [:]
        for (dir, source) in dirs {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for n in names where !n.hasPrefix(".") {
                let entry = dir.appendingPathComponent(n)
                let real = entry.resolvingSymlinksInPath()
                guard let text = try? String(contentsOf: real.appendingPathComponent("SKILL.md"), encoding: .utf8) else { continue }
                if byReal[real.path] == nil {
                    let fields = frontmatter(text)
                    byReal[real.path] = Skill(name: fields["name"].flatMap { $0.isEmpty ? nil : $0 } ?? n,
                                              description: fields["description"] ?? "", realURL: real)
                }
                byReal[real.path]!.entries.append(entry)
                if !byReal[real.path]!.sources.contains(source) { byReal[real.path]!.sources.append(source) }
            }
        }
        return byReal.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Minimal YAML frontmatter reader: top-level `key: value`, folded/indented continuation lines joined with spaces.
    static func frontmatter(_ text: String) -> [String: String] {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var out: [String: String] = [:]
        var key: String?
        for line in lines.dropFirst() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == "---" { break }
            if let k = key, line.hasPrefix(" ") || line.hasPrefix("\t") {
                out[k] = out[k]!.isEmpty ? t : out[k]! + " " + t
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let k = line[..<colon].trimmingCharacters(in: .whitespaces)
            var v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if [">", "|", ">-", "|-"].contains(v) { v = "" }
            if v.count >= 2, let f = v.first, f == v.last, f == "\"" || f == "'" { v = String(v.dropFirst().dropLast()) }
            out[k] = v
            key = k
        }
        return out
    }

    /// Moves the real folder to Trash, then any symlinks to it that were found in scanned dirs.
    static func trash(_ skill: Skill) throws {
        let fm = FileManager.default
        try fm.trashItem(at: skill.realURL, resultingItemURL: nil)
        for e in skill.entries where (try? fm.destinationOfSymbolicLink(atPath: e.path)) != nil {
            try fm.trashItem(at: e, resultingItemURL: nil)
        }
    }
}

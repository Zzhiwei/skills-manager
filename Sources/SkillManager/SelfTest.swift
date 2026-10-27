import Foundation

// Run with: swift run SkillManager --selftest
enum SelfTest {
    static func run() {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("skillmanager-selftest-\(UUID().uuidString)")
        let global = root.appendingPathComponent("global"), links = root.appendingPathComponent("links")
        let project = root.appendingPathComponent("proj")
        let a = global.appendingPathComponent("a"), b = project.appendingPathComponent(".claude/skills/b")
        for d in [a, global.appendingPathComponent("not-a-skill"), links, b] {
            try! fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        try! "---\nname: alpha\ndescription: >\n  first line\n  second line\nmetadata:\n  type: x\n---\nbody".write(
            to: a.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try! "---\ndescription: \"quoted: yes\"\n---\n".write(to: b.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try! fm.createSymbolicLink(atPath: links.appendingPathComponent("a").path, withDestinationPath: "../global/a")

        let skills = Scanner.scan([
            (global, Source(label: "g", kind: .global)),
            (links, Source(label: "l", kind: .global)),
            (project.appendingPathComponent(".claude/skills"), Source(label: "proj", kind: .project(project.path))),
        ])
        precondition(skills.count == 2, "dedupe + skip dirs without SKILL.md: \(skills.map(\.name))")
        let alpha = skills.first { $0.name == "alpha" }!, beta = skills.first { $0.name == "b" }!
        precondition(alpha.description == "first line second line", alpha.description)
        precondition(alpha.entries.count == 2 && alpha.sources.count == 2)
        precondition(beta.description == "quoted: yes" && beta.sources == [Source(label: "proj", kind: .project(project.path))])

        try! Scanner.trash(alpha)
        precondition(!fm.fileExists(atPath: a.path), "real folder trashed")
        precondition((try? fm.destinationOfSymbolicLink(atPath: links.appendingPathComponent("a").path)) == nil, "symlink trashed")
        try? fm.removeItem(at: root)

        let listed = try! JSONDecoder().decode([PluginInfo].self, from: Data("""
            [{"id":"x@m","version":"1.0","scope":"local","enabled":false,"projectPath":"/p","mcpServers":{}},
             {"id":"y@m","scope":"user","enabled":true}]
            """.utf8))
        precondition(listed.count == 2 && listed[0].projectPath == "/p" && !listed[0].enabled && listed[1].version == nil)
        print("selftest passed")
    }
}

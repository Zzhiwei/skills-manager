# Skill Manager

macOS SwiftUI app that lists agent skills (folders containing `SKILL.md`) from `~/.agents/skills`, `~/.claude/skills`, user-added projects (`<project>/.claude/skills`, `<project>/.agents/skills`) and installed Claude Code plugins.

## Commands

- `./build.sh` — release build + bundles `build/Skill Manager.app` (ad-hoc signed). No Xcode on this machine: CommandLineTools + SwiftPM only, so no `.xcodeproj`, no XCTest.
- `swift run SkillManager --selftest` — the test suite (`Sources/SkillManager/SelfTest.swift`, `precondition`-based). Run after touching `Scanner` or `PluginCLI`.
- `scripts/make-icon.sh` — regenerates `Resources/AppIcon.icns` from `scripts/make-icon.swift`. Only needed when changing the icon.
- Relaunch after building: `osascript -e 'quit app "Skill Manager"'; open "build/Skill Manager.app"`.
- Screen capture is not permitted for the agent, so UI changes can't be visually verified; say so.

## Layout

- `Scanner.swift` — finds skills, parses frontmatter, trashes skills. Plugin skill dirs come from `~/.claude/plugins/installed_plugins.json` (`installPath/skills`), not by walking the plugin cache (it holds stale versions and `.openclaw` copies).
- `PluginCLI.swift` — wraps `claude plugin …` (list/enable/disable/update/uninstall).
- `App.swift` — all UI, `Store` state, `Ocean` palette.

## Behaviour that must be preserved

- Skills are deduped by resolved real path; `~/.claude/skills` is mostly symlinks into `~/.agents/skills`. One row per real folder, with every source shown as a badge.
- Trash = `FileManager.trashItem`, never delete. Trash the real folder first, then the symlinks found in scanned dirs (if the real folder fails, nothing has changed).
- Plugin skills are read-only (no trash button); plugins are managed only through the `claude` CLI.
- "Made by Me" tags and the project list live in `UserDefaults` (`mine` = real paths, `projects`). Tags are edited only via the picker sheet in the Made by Me tab.
- Open in VS Code uses `NSWorkspace` + bundle id `com.microsoft.VSCode`, not the `code` CLI.

## Gotchas

- GUI apps don't get the shell `PATH`: `PluginCLI.executable` probes fixed install paths for `claude`.
- `claude plugin list --json` reports `enabled` relative to the working dir, so local-scope plugins are re-listed and acted on with cwd = their `projectPath`, always passing `--scope`.
- Never pass `-y` to `claude plugin update`: it would auto-accept marketplace-declared commands. Failures surface to the user instead.
- Process pipes: stderr is drained concurrently and blocking I/O runs on a GCD queue, not the Swift concurrency pool.
- Deployment target is macOS 13 (`Package.swift`, tools 5.9): avoid macOS 14+ APIs such as `Section(isExpanded:)`; plugin groups use `DisclosureGroup`.
- Theme: native semantic colors (`.primary`/`.secondary`, system backgrounds) with accents from `enum Ocean`, each having light/dark variants. Don't reintroduce gradients or low-opacity text.

## Git

Remote `origin` = github.com/Zzhiwei/skills-manager (public). Pushing only works through the local proxy: `git -c http.proxy=http://127.0.0.1:8888 push`.

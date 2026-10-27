import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--selftest") { return SelfTest.run() }
        NSApplication.shared.setActivationPolicy(.regular) // needed when launched as a bare binary via `swift run`
        SkillManagerApp.main()
    }
}

struct SkillManagerApp: App {
    var body: some Scene {
        WindowGroup("Skill Manager") {
            ContentView().tint(Ocean.teal)
        }
    }
}

/// Ocean accents over native macOS colors; each accent has a light/dark variant that keeps text contrast high.
enum Ocean {
    static let teal = adaptive(light: 0x0E7C86, dark: 0x4FD1D9)
    static let blue = adaptive(light: 0x1F5FA8, dark: 0x7DB7F5)
    static let slate = adaptive(light: 0x4A5D6E, dark: 0xA9BCCB)
    static let coral = adaptive(light: 0xC23B27, dark: 0xFF7A66)

    static func adaptive(light: Int, dark: Int) -> Color {
        func ns(_ hex: Int) -> NSColor {
            NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        return Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? ns(dark) : ns(light) })
    }
}

enum Filter: Hashable { case all, mine, global, plugins, project(String) }

@MainActor
final class Store: ObservableObject {
    @Published var skills: [Skill] = []
    @Published var projects: [String] = UserDefaults.standard.stringArray(forKey: "projects") ?? [] {
        didSet { UserDefaults.standard.set(projects, forKey: "projects"); reload() }
    }
    /// Real paths of skills tagged "made by me".
    @Published var mine = Set(UserDefaults.standard.stringArray(forKey: "mine") ?? []) {
        didSet { UserDefaults.standard.set(Array(mine), forKey: "mine") }
    }

    @Published var plugins: [String: PluginInfo] = [:]
    @Published var pluginError: String?
    @Published var busyPlugins: Set<String> = []

    init() {
        reload()
        Task { await reloadPlugins() }
    }

    func reload() { skills = Scanner.scan(Scanner.sources(projects: projects)) }

    func reloadPlugins() async {
        do { plugins = try await PluginCLI.list(); pluginError = nil } catch { pluginError = error.localizedDescription }
    }

    /// Runs a `claude plugin` command, then rescans. Returns an error message on failure.
    func act(_ command: String, on plugin: PluginInfo) async -> String? {
        busyPlugins.insert(plugin.id)
        defer { busyPlugins.remove(plugin.id) }
        var failure: String?
        do { try await PluginCLI.act(command, on: plugin) } catch { failure = error.localizedDescription }
        reload()
        await reloadPlugins()
        return failure
    }
}

struct ContentView: View {
    @StateObject private var store = Store()
    @State private var filter: Filter? = .all
    @State private var query = ""
    @State private var importing = false
    @State private var pendingTrash: Skill?
    @State private var pendingUninstall: PluginInfo?
    @State private var pickingMine = false
    @State private var expandedPlugins: Set<String> = [] // empty = all collapsed
    @State private var error: String?

    private var visible: [Skill] {
        store.skills.filter { skill in
            let inFilter: Bool = switch filter ?? .all {
            case .all: true
            case .global: skill.sources.contains { $0.kind == .global }
            case .mine: store.mine.contains(skill.id)
            case .plugins: skill.readOnly
            case .project(let p): skill.sources.contains { $0.kind == .project(p) }
            }
            return inFilter && (query.isEmpty || skill.name.localizedCaseInsensitiveContains(query)
                || skill.description.localizedCaseInsensitiveContains(query))
        }
    }

    /// Visible skills grouped by plugin id; a skill shipped by several plugins appears under each.
    /// Installed plugins without skills get a group too, unless a search is narrowing the list.
    private var pluginGroups: [(id: String, skills: [Skill])] {
        var ids = Set(visible.flatMap { $0.sources.compactMap { if case .plugin(let id) = $0.kind { id } else { nil } } })
        if query.isEmpty { ids.formUnion(store.plugins.keys) }
        return ids.sorted().map { id in (id, visible.filter { $0.sources.contains { $0.kind == .plugin(id: id) } }) }
    }

    private func act(_ command: String, on plugin: PluginInfo) {
        Task { if let e = await store.act(command, on: plugin) { error = e } }
    }

    private func row(_ skill: Skill) -> some View {
        SkillRow(skill: skill, open: { open(skill) }, trash: { pendingTrash = skill })
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $filter) {
                Section("Library") {
                    Label("All Skills", systemImage: "water.waves").tag(Filter.all)
                    Label("Made by Me", systemImage: "person.crop.circle").tag(Filter.mine)
                    Label("Global", systemImage: "globe").tag(Filter.global)
                    Label("Plugins", systemImage: "puzzlepiece.extension").tag(Filter.plugins)
                }
                Section("Projects") {
                    ForEach(store.projects, id: \.self) { p in
                        Label(URL(fileURLWithPath: p).lastPathComponent, systemImage: "folder")
                            .tag(Filter.project(p))
                            .help(p)
                            .contextMenu {
                                Button("Remove Project") {
                                    if filter == .project(p) { filter = .all }
                                    store.projects.removeAll { $0 == p }
                                }
                            }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button { importing = true } label: { Label("Add Project…", systemImage: "plus") }
                    .buttonStyle(.borderless).padding()
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            List {
                if filter == .plugins {
                    if let e = store.pluginError {
                        Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(Ocean.coral)
                    }
                    ForEach(pluginGroups, id: \.id) { group in
                        let expanded = Binding(
                            get: { expandedPlugins.contains(group.id) },
                            set: { if $0 { expandedPlugins.insert(group.id) } else { expandedPlugins.remove(group.id) } }
                        )
                        DisclosureGroup(isExpanded: expanded) {
                            if group.skills.isEmpty { Text("No skills in this plugin").foregroundStyle(.secondary) }
                            ForEach(group.skills) { row($0) }
                        } label: {
                            PluginHeader(id: group.id, skillCount: group.skills.count, info: store.plugins[group.id],
                                         busy: store.busyPlugins.contains(group.id),
                                         toggleExpanded: { expanded.wrappedValue.toggle() },
                                         act: { command in store.plugins[group.id].map { act(command, on: $0) } },
                                         uninstall: { pendingUninstall = store.plugins[group.id] })
                        }
                    }
                } else {
                    ForEach(visible) { row($0) }
                }
            }
            .overlay {
                if visible.isEmpty && !(filter == .plugins && !pluginGroups.isEmpty) {
                    Text(filter == .mine && query.isEmpty ? "No skills tagged yet. Click Add Skills… in the toolbar." : "No skills here")
                        .foregroundStyle(.secondary)
                }
            }
            .searchable(text: $query, prompt: "Search skills")
            .navigationSubtitle("\(visible.count) skills")
            .toolbar {
                if filter == .mine {
                    Button { pickingMine = true } label: { Label("Add Skills…", systemImage: "plus") }
                }
                Button {
                    store.reload()
                    Task { await store.reloadPlugins() }
                } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .sheet(isPresented: $pickingMine) {
            MinePicker(skills: store.skills, selection: store.mine) { store.mine = $0 }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                store.projects += urls.map(\.path).filter { !store.projects.contains($0) }
            case .failure(let e): error = e.localizedDescription
            }
        }
        .confirmationDialog("Move “\(pendingTrash?.name ?? "")” to Trash?", isPresented: Binding(
            get: { pendingTrash != nil }, set: { if !$0 { pendingTrash = nil } }
        ), presenting: pendingTrash) { skill in
            Button("Move to Trash", role: .destructive) {
                do { try Scanner.trash(skill); store.mine.remove(skill.id) } catch { self.error = error.localizedDescription }
                store.reload()
            }
        } message: { skill in
            Text(([skill.realURL] + skill.entries.filter { $0.path != skill.realURL.path }).map(\.path).joined(separator: "\n"))
        }
        .confirmationDialog("Uninstall plugin “\(pendingUninstall?.id ?? "")”?", isPresented: Binding(
            get: { pendingUninstall != nil }, set: { if !$0 { pendingUninstall = nil } }
        ), presenting: pendingUninstall) { plugin in
            Button("Uninstall", role: .destructive) { act("uninstall", on: plugin) }
        } message: { plugin in
            Text("Runs `claude plugin uninstall \(plugin.id) --scope \(plugin.scope)`. This also deletes the plugin's saved data. Restart Claude Code sessions to apply.")
        }
        .alert("Error", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: { Text(error ?? "") }
    }

    private func open(_ skill: Skill) {
        guard let vscode = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") else {
            error = "Visual Studio Code is not installed."
            return
        }
        NSWorkspace.shared.open([skill.realURL], withApplicationAt: vscode, configuration: .init()) { _, err in
            if let err { DispatchQueue.main.async { error = err.localizedDescription } }
        }
    }
}

struct SkillRow: View {
    let skill: Skill
    let open: () -> Void
    let trash: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(skill.name).font(.headline)
                    if skill.readOnly {
                        Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary).help("Plugin skill (read-only)")
                    }
                }
                if !skill.description.isEmpty {
                    Text(skill.description).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 6) {
                    ForEach(skill.sources, id: \.self) { SourceBadge(source: $0) }
                }
                Text(skill.realURL.path.replacingOccurrences(of: Scanner.home.path, with: "~"))
                    .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            Button(action: open) { Label("Open in VS Code", systemImage: "chevron.left.forwardslash.chevron.right") }
            if !skill.readOnly {
                Button(action: trash) { Image(systemName: "trash") }
                    .foregroundStyle(Ocean.coral).help("Move to Trash")
            }
        }
        .padding(12)
        .background(Ocean.teal.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor)))
    }
}

struct SourceBadge: View {
    let source: Source

    var body: some View {
        let (icon, color, help): (String, Color, String) = switch source.kind {
        case .global: ("globe", Ocean.teal, "Global skills directory")
        case .project(let p): ("folder.fill", Ocean.blue, "Project: \(p)")
        case .plugin(let id): ("puzzlepiece.extension.fill", Ocean.slate, "Claude Code plugin: \(id)")
        }
        Label(source.label, systemImage: icon)
            .font(.caption)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
            .help(help)
    }
}

/// Multi-select sheet for the "Made by Me" set; starts with current tags, so deselecting untags.
struct MinePicker: View {
    let skills: [Skill]
    @State var selection: Set<String>
    let save: (Set<String>) -> Void
    @State var query = ""
    @Environment(\.dismiss) var dismiss

    var body: some View {
        let shown = skills.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.description.localizedCaseInsensitiveContains(query)
        }
        VStack(spacing: 12) {
            HStack {
                Text("Made by Me").font(.title3.bold())
                Spacer()
                Text("\(selection.count) selected").foregroundStyle(.secondary)
            }
            TextField("Search skills", text: $query).textFieldStyle(.roundedBorder)
            List(shown) { skill in
                let selected = selection.contains(skill.id)
                Button { selection.formSymmetricDifference([skill.id]) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.title3).foregroundStyle(selected ? Ocean.teal : .secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(skill.name).font(.headline)
                            HStack(spacing: 6) { ForEach(skill.sources, id: \.self) { SourceBadge(source: $0) } }
                        }
                        Spacer()
                    }
                    .padding(8)
                    .contentShape(Rectangle()) // whole row is clickable, not just the text
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .listRowBackground(RoundedRectangle(cornerRadius: 8).fill(selected ? Ocean.teal.opacity(0.15) : Color.clear))
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Done") { save(selection); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 560, height: 600)
    }
}

/// Collapsible group header for one plugin: name, version/scope, and enable / update / uninstall controls.
struct PluginHeader: View {
    let id: String
    let skillCount: Int
    let info: PluginInfo?   // nil until `claude plugin list` has loaded, or if it failed
    let busy: Bool
    let toggleExpanded: () -> Void
    let act: (String) -> Void
    let uninstall: () -> Void

    var body: some View {
        let name = String(id.split(separator: "@").first ?? Substring(id))
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Label("\(name) (\(skillCount))", systemImage: "puzzlepiece.extension")
                    .font(.headline).foregroundStyle(Ocean.slate)
                if let info {
                    Text([info.version, info.projectPath.map { "\(info.scope): \(URL(fileURLWithPath: $0).lastPathComponent)" }]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).help(info.projectPath ?? "")
                    if !info.enabled {
                        Text("Disabled").font(.caption.bold()).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .overlay(Capsule().stroke(Color(nsColor: .separatorColor)))
                    }
                }
                Spacer()
            }
            .opacity(info?.enabled == false ? 0.6 : 1)
            .contentShape(Rectangle()) // click anywhere on the header to toggle, not just the chevron
            .onTapGesture(perform: toggleExpanded)
            if busy { ProgressView().controlSize(.small) }
            if let info {
                HStack(spacing: 8) {
                    Toggle("Enabled", isOn: Binding(get: { info.enabled }, set: { act($0 ? "enable" : "disable") }))
                        .toggleStyle(.switch).controlSize(.small).labelsHidden()
                        .help(info.enabled ? "Disable plugin" : "Enable plugin")
                    Button("Update") { act("update") }.controlSize(.small).help("Update to the latest version")
                    Button(action: uninstall) { Image(systemName: "trash") }
                        .foregroundStyle(Ocean.coral).help("Uninstall plugin").accessibilityLabel("Uninstall \(name)")
                }
                .disabled(busy)
            }
        }
    }
}

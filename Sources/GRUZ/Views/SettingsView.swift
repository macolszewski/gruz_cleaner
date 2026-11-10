import AppKit
import CleanerKit
import ScannerKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView().tabItem { Label("General", systemImage: "gearshape") }
            ScanSettingsView().tabItem { Label("Scanning", systemImage: "magnifyingglass") }
            AgeSettingsView().tabItem { Label("Data Age", systemImage: "clock") }
            AccessSettingsView().tabItem { Label("Access", systemImage: "lock.shield") }
        }
    }
}

struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Picker("Language", selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { language in
                        languageName(language).tag(language)
                    }
                }
                .disabled(!AppLanguage.isConfigurable)
                if settings.languageNeedsRestart {
                    HStack {
                        Label("The new language applies after GRUZ restarts.", systemImage: "arrow.clockwise.circle")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Restart Now") { AppLanguage.relaunch() }
                            .disabled(model.isCleaning || model.claudeMemory.isRunning)
                    }
                }
            } footer: {
                Text("By default GRUZ uses the macOS language. You can also choose it in System Settings > General > Language & Region > Applications.")
            }
        }
        .formStyle(.grouped)
    }

    /// Language names are written in their own language so each is recognizable in any interface.
    private func languageName(_ language: AppLanguage) -> Text {
        switch language {
        case .system: Text("System Default")
        case .english: Text(verbatim: "English")
        case .polish: Text(verbatim: "Polski")
        }
    }
}

struct ScanSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                ForEach(settings.projectRoots, id: \.self) { root in
                    HStack {
                        Image(systemName: "folder")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(root).font(.body.monospaced())
                            if let why = Self.outsideAllowedArea(root) {
                                Text("Nothing in this folder can be removed: \(why)")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        Button(role: .destructive) {
                            settings.projectRoots.removeAll { $0 == root }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove from the list (the folder is not deleted)")
                    }
                }
                Button("Add Folder…", action: addRoot)
            } header: {
                Text("Project folders")
            } footer: {
                Text("GRUZ looks here for node_modules, .venv, build output and agent worktrees. The folders themselves and project source code are protected.")
            }

            Section("Unrecognized") {
                Stepper(value: $settings.unrecognizedMinimumMB, in: 10...10_000, step: 50) {
                    Text("Show folders larger than \(settings.unrecognizedMinimumMB) MB")
                }
            }

            Section {
                Button("Scan Again with New Settings") { model.scan() }
                    .disabled(!model.canScan)
            }
        }
        .formStyle(.grouped)
    }

    /// Why artifacts inside `root` would be refused by the denylist (for example, under ~/Documents), if they would.
    static func outsideAllowedArea(_ root: String) -> String? {
        let probe = Paths.join(Paths.expand(root), "node_modules")
        if case .denied(let why) = Denylist().check(probe) { return why }
        return nil
    }

    private func addRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let path = Paths.abbreviate(url.path)
            if !model.settings.projectRoots.contains(path) { model.settings.projectRoots.append(path) }
        }
    }
}

struct AgeSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Toggle("Only show data older than…", isOn: $settings.ageFilterEnabled)
                Stepper(value: $settings.ageFilterDays, in: 1...3650) {
                    Text("\(settings.ageFilterDays) days")
                }
                .disabled(!settings.ageFilterEnabled)
            } header: {
                Text("App-wide filter")
            } footer: {
                Text("Age is the time since anything in the folder last changed. The filter applies to all categories.")
            }

            Section {
                ForEach(rulesWithThreshold, id: \.id) { rule in
                    RuleThresholdRow(rule: rule)
                }
            } header: {
                Text("Default item thresholds")
            } footer: {
                Text("Some items (such as Claude and Codex sessions or temporary files) show only older data by default. You can change the threshold or turn it off. When the app-wide filter is also on, the longer threshold applies.")
            }
        }
        .formStyle(.grouped)
    }

    private var rulesWithThreshold: [Rule] {
        model.catalog?.rules.filter { $0.defaultAgeDays != nil } ?? []
    }
}

struct RuleThresholdRow: View {
    @Environment(AppModel.self) private var model
    let rule: Rule

    var body: some View {
        let settings = model.settings
        let override = settings.ruleAgeOverrides[rule.id]
        let enabled = override.map { $0 > 0 } ?? true
        let days = (override ?? 0) > 0 ? override! : (rule.defaultAgeDays ?? 30)
        HStack {
            Toggle(isOn: Binding(
                get: { enabled },
                set: { settings.ruleAgeOverrides[rule.id] = $0 ? days : 0 }
            )) {
                VStack(alignment: .leading) {
                    Text(rule.title)
                    Text(rule.app ?? "").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Stepper(value: Binding(
                get: { days },
                set: { settings.ruleAgeOverrides[rule.id] = max(1, $0) }
            ), in: 1...3650) {
                Text("\(days) days").monospacedDigit()
            }
            .disabled(!enabled)
            .fixedSize()
        }
    }
}

struct AccessSettingsView: View {
    @Environment(AppModel.self) private var model
    private var granted: Bool { model.hasFullDiskAccess }

    var body: some View {
        Form {
            Section {
                Label {
                    granted ? Text("Full Disk Access is on") : Text("No Full Disk Access")
                } icon: {
                    Image(systemName: granted ? "checkmark.shield.fill" : "exclamationmark.shield")
                }
                .foregroundStyle(granted ? .green : .orange)
                Text("Without this permission GRUZ cannot measure the Trash, Mail, Messages or iPhone backups. Add GRUZ to the list, then restart it.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Open Privacy Settings") { NSWorkspace.shared.open(FullDiskAccess.settingsURL) }
                    Button("Check Now") { model.refreshFullDiskAccess() }
                }
            } header: {
                Text("Permissions")
            }
            Section {
                Text("GRUZ only reads data while scanning. It removes only what you select and confirm in the review window, by default to the Trash. Every operation is recorded in the operation log.")
                    .foregroundStyle(.secondary)
                Button("Show Operation Log in Finder") {
                    let url = FileOperationLog.defaultURL
                    if FileManager.default.fileExists(atPath: url.path) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } else {
                        NSWorkspace.shared.open(url.deletingLastPathComponent().deletingLastPathComponent())
                    }
                }
            } header: {
                Text("Safety")
            }
        }
        .formStyle(.grouped)
    }
}

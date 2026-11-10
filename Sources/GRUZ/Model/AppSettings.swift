import AppKit
import Foundation
import Observation
import ScannerKit

/// User preferences, persisted in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    private let defaults = UserDefaults.standard

    var projectRoots: [String] { didSet { defaults.set(projectRoots, forKey: "projectRoots") } }
    var ageFilterEnabled: Bool { didSet { defaults.set(ageFilterEnabled, forKey: "ageFilterEnabled") } }
    var ageFilterDays: Int { didSet { defaults.set(ageFilterDays, forKey: "ageFilterDays") } }
    /// Rule id -> days; 0 disables the rule's default threshold. Missing keys use the rule default.
    var ruleAgeOverrides: [String: Int] { didSet { defaults.set(ruleAgeOverrides, forKey: "ruleAgeOverrides") } }
    var unrecognizedMinimumMB: Int { didSet { defaults.set(unrecognizedMinimumMB, forKey: "unrecognizedMinimumMB") } }
    var language: AppLanguage { didSet { language.apply() } }
    /// Bundle localizations are resolved once per process, so a new language needs a restart.
    let languageAtLaunch = AppLanguage.current
    var languageNeedsRestart: Bool { language != languageAtLaunch }

    init() {
        projectRoots = defaults.stringArray(forKey: "projectRoots") ?? ScanOptions.defaultProjectRoots()
        ageFilterEnabled = defaults.bool(forKey: "ageFilterEnabled")
        ageFilterDays = defaults.object(forKey: "ageFilterDays") as? Int ?? 30
        ruleAgeOverrides = defaults.dictionary(forKey: "ruleAgeOverrides") as? [String: Int] ?? [:]
        unrecognizedMinimumMB = defaults.object(forKey: "unrecognizedMinimumMB") as? Int ?? 100
        language = languageAtLaunch
    }

    /// Effective threshold for a rule: its default unless overridden; nil when disabled.
    func ruleThreshold(ruleID: String?, defaultDays: Int?) -> Int? {
        guard let ruleID else { return defaultDays }
        if let override = ruleAgeOverrides[ruleID] { return override > 0 ? override : nil }
        return defaultDays
    }

    /// Items must be older than the stricter of the global filter and the rule threshold.
    func threshold(for item: ItemThresholdInput) -> Int? {
        let global = ageFilterEnabled ? ageFilterDays : nil
        let rule = ruleThreshold(ruleID: item.ruleID, defaultDays: item.defaultAgeDays)
        switch (global, rule) {
        case let (g?, r?): return max(g, r)
        case let (g?, nil): return g
        case let (nil, r?): return r
        default: return nil
        }
    }
}

struct ItemThresholdInput {
    var ruleID: String?
    var defaultAgeDays: Int?
}

/// Interface language override, stored as `AppleLanguages` in the app's own defaults domain.
///
/// System Settings > General > Language & Region > Applications writes the same key, so both
/// places show and change one setting.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case polish = "pl"

    var id: String { rawValue }

    private static let key = "AppleLanguages"

    /// A bare executable (`swift run`) has no defaults domain of its own to keep the choice in.
    static var isConfigurable: Bool { Bundle.main.bundleIdentifier != nil }

    /// Reads the app domain only: `UserDefaults.object(forKey:)` would also return the global
    /// system language list, which is not a choice made for this app.
    static var current: AppLanguage {
        guard let domain = Bundle.main.bundleIdentifier,
              let languages = UserDefaults.standard.persistentDomain(forName: domain)?[key] as? [String],
              let preferred = languages.first,
              let code = Locale(identifier: preferred).language.languageCode?.identifier,
              let language = AppLanguage(rawValue: code), language != .system
        else { return .system }
        return language
    }

    func apply() {
        guard Self.isConfigurable else { return }
        if self == .system {
            UserDefaults.standard.removeObject(forKey: Self.key)
        } else {
            UserDefaults.standard.set([rawValue], forKey: Self.key)
        }
    }

    /// Starts a new instance of the app bundle, then quits this one.
    @MainActor
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            guard error == nil else { return }
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}

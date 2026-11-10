import Foundation

/// The language GRUZ presents its content in.
///
/// Foundation picks a bundle localization from the user's preferred languages, limited to the
/// localizations the main bundle declares (`CFBundleLocalizations` in the app's Info.plist).
/// Rule texts follow the same choice, so the catalog and the interface never disagree.
/// Processes without such an Info.plist (`swift run`, tests, the CLI) fall back to English.
public enum Localization {
    /// The development language: source strings and rule catalogs are written in it.
    public static let developmentLanguage = "en"

    /// Languages with complete translations of the interface and the rule catalog.
    public static let supportedLanguages = ["en", "pl"]

    /// The language resolved for this process.
    public static var current: String {
        Bundle.scannerKit.preferredLocalizations.first ?? developmentLanguage
    }
}

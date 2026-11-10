import Foundation

extension Bundle {
    /// CleanerKit's resources (maintenance helpers and translations).
    ///
    /// Inside GRUZ.app the resource bundle sits in `Contents/Resources`, which the
    /// SwiftPM-generated `Bundle.module` never searches: it only looks at the app's root
    /// (where a nested bundle would break code signing) and at the absolute build path.
    static let cleanerKit: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("GRUZ_CleanerKit.bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return .module
    }()

    /// CleanerKit's English table alone, for text that must not follow the UI language
    /// (the operation log). Lookups in a single `.lproj` folder ignore the user's language
    /// preferences; English keys missing from it resolve to themselves, which is English.
    static let cleanerKitEnglish: Bundle = {
        cleanerKit.url(forResource: "en", withExtension: "lproj").flatMap(Bundle.init(url:)) ?? cleanerKit
    }()
}

import Foundation

extension Bundle {
    /// ScannerKit's resources (rule catalog and translations).
    ///
    /// Inside GRUZ.app the resource bundle sits in `Contents/Resources`, which the
    /// SwiftPM-generated `Bundle.module` never searches: it only looks at the app's root
    /// (where a nested bundle would break code signing) and at the absolute build path.
    static let scannerKit: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("GRUZ_ScannerKit.bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return .module
    }()
}

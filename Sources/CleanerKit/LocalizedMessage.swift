import Foundation

/// A user-facing message resolved twice: in the user's language for the UI and in English for
/// the operation log, so the log reads the same whatever language the app runs in.
struct LocalizedMessage: Error, LocalizedError, Sendable {
    let text: String
    let english: String

    init(_ value: String.LocalizationValue) {
        text = String(localized: value, bundle: .cleanerKit)
        english = String(localized: value, bundle: .cleanerKitEnglish)
    }

    init(text: String, english: String) {
        self.text = text
        self.english = english
    }

    /// Text produced elsewhere (system errors, ScannerKit) that CleanerKit cannot translate.
    init(verbatim: String) {
        self.init(text: verbatim, english: verbatim)
    }

    /// Keeps the English form of CleanerKit's own errors; other errors are logged as described.
    init(_ error: any Error) {
        switch error {
        case let message as LocalizedMessage: self = message
        case let rust as RustRemovalError: self.init(text: rust.message, english: rust.logMessage)
        default: self.init(verbatim: error.localizedDescription)
        }
    }

    var errorDescription: String? { text }

    /// Prefixes the message with a path or other untranslated context.
    func prefixed(_ context: String) -> LocalizedMessage {
        LocalizedMessage(text: "\(context): \(text)", english: "\(context): \(english)")
    }

    /// Appends a sentence, e.g. what happened to the worker after a failure.
    func appending(_ other: LocalizedMessage) -> LocalizedMessage {
        LocalizedMessage(text: "\(text) \(other.text)", english: "\(english) \(other.english)")
    }

    static func joined(_ messages: [LocalizedMessage], separator: String = "; ") -> LocalizedMessage {
        LocalizedMessage(text: messages.map(\.text).joined(separator: separator),
                         english: messages.map(\.english).joined(separator: separator))
    }
}

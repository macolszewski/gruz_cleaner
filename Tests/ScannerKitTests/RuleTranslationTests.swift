import Foundation
import Testing
@testable import ScannerKit

@Suite struct RuleTranslationTests {
    static let translatedLanguages = Localization.supportedLanguages.filter { $0 != Localization.developmentLanguage }

    var directory: URL { get throws { try #require(RuleCatalog.builtInDirectory) } }

    @Test(arguments: translatedLanguages)
    func everyRuleAndArtifactIsTranslated(language: String) throws {
        let english = try RuleCatalog.load(from: directory, language: Localization.developmentLanguage)
        let translations = try #require(try RuleCatalog.translations(in: directory, language: language))

        let ids = Set(english.rules.map(\.id) + english.artifacts.map(\.id))
        #expect(Set(translations.keys).subtracting(ids).isEmpty, "translations for unknown ids")
        #expect(ids.subtracting(translations.keys).isEmpty, "untranslated ids")

        for rule in english.rules {
            let text = try #require(translations[rule.id], "\(rule.id)")
            #expect(text.title?.isEmpty == false, "\(rule.id): title")
            #expect(text.description?.isEmpty == false, "\(rule.id): description")
            #expect((text.regeneration != nil) == (rule.regeneration != nil), "\(rule.id): regeneration")
            #expect((text.note != nil) == (rule.note != nil), "\(rule.id): note")
        }
        for artifact in english.artifacts {
            let text = try #require(translations[artifact.id], "\(artifact.id)")
            #expect(text.title?.isEmpty == false, "\(artifact.id): title")
            #expect(text.description?.isEmpty == false, "\(artifact.id): description")
            #expect((text.regeneration != nil) == (artifact.regeneration != nil), "\(artifact.id): regeneration")
            #expect(text.app == nil && text.note == nil, "\(artifact.id): artifacts have no app or note")
        }
    }

    @Test(arguments: translatedLanguages)
    func loadingAppliesTranslationsWithoutChangingBehaviour(language: String) throws {
        let english = try RuleCatalog.load(from: directory, language: Localization.developmentLanguage)
        let translated = try RuleCatalog.load(from: directory, language: language)

        #expect(translated.rules.map(\.id) == english.rules.map(\.id))
        #expect(translated.rules.map(\.paths) == english.rules.map(\.paths))
        #expect(translated.rules.map(\.action) == english.rules.map(\.action))
        #expect(translated.rules.map(\.safety) == english.rules.map(\.safety))
        #expect(zip(translated.rules, english.rules).contains { $0.title != $1.title })
    }

    @Test func missingTranslationKeepsEnglish() throws {
        let english = try RuleCatalog.load(from: directory, language: Localization.developmentLanguage)
        let unknown = try RuleCatalog.load(from: directory, language: "xx")
        #expect(unknown.rules.map(\.title) == english.rules.map(\.title))
    }
}

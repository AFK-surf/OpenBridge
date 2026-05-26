import Foundation
@testable import OpenBridge
import Testing

struct AppLanguageSelectionTests {
    @Test
    func `available localizations remove base and preserve app option identifiers`() {
        let localizations = AppLanguageSelection.availableLocalizations(from: ["Base", "en", "zh_Hans", "en"])

        #expect(localizations == ["en", "zh-Hans"])
    }

    @Test
    func `regional stored language resolves to supported picker option`() {
        let available = ["en", "zh-Hans"]

        #expect(
            AppLanguageSelection.resolvedSelection(
                for: "zh-Hans-CN",
                availableLocalizations: available,
                preferredLanguages: []
            ) == "zh-Hans"
        )
        #expect(
            AppLanguageSelection.resolvedSelection(
                for: "en-US",
                availableLocalizations: available,
                preferredLanguages: []
            ) == "en"
        )
    }

    @Test
    func `empty stored language resolves to preferred supported picker option`() {
        let resolved = AppLanguageSelection.resolvedSelection(
            for: "",
            availableLocalizations: ["en", "zh-Hans"],
            preferredLanguages: ["zh-Hans-CN"]
        )

        #expect(resolved == "zh-Hans")
        #expect(!AppLanguageSelection.displayName(for: resolved, locale: Locale(identifier: "en_US_POSIX")).isEmpty)
    }

    @Test
    func `unsupported stored language falls back to a visible supported option`() {
        let resolved = AppLanguageSelection.resolvedSelection(
            for: "es-MX",
            availableLocalizations: ["en", "zh-Hans"],
            preferredLanguages: []
        )

        #expect(resolved == "en")
    }
}

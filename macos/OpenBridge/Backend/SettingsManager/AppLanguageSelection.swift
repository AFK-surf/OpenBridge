import Foundation

nonisolated enum AppLanguageSelection {
    static func availableLocalizations(from localizations: [String]) -> [String] {
        var seen = Set<String>()
        return localizations.compactMap { localization in
            let normalized = normalizedIdentifier(localization)
            guard !normalized.isEmpty, normalized != "Base" else {
                return nil
            }
            let key = normalized.lowercased()
            guard seen.insert(key).inserted else {
                return nil
            }
            return normalized
        }
    }

    static func resolvedSelection(
        for storedLanguage: String,
        availableLocalizations: [String],
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> String {
        let available = self.availableLocalizations(from: availableLocalizations)
        let normalizedLanguage = normalizedIdentifier(storedLanguage)
        guard !available.isEmpty else {
            return normalizedLanguage
        }

        if let exactMatch = match(normalizedLanguage, in: available) {
            return exactMatch
        }

        let preferences = normalizedLanguage.isEmpty
            ? preferredLanguages.map(normalizedIdentifier).filter { !$0.isEmpty }
            : [normalizedLanguage]

        if let preferred = Bundle.preferredLocalizations(from: available, forPreferences: preferences).first,
           let matchedPreferred = match(preferred, in: available)
        {
            return matchedPreferred
        }

        if let english = match("en", in: available) {
            return english
        }

        return available[0]
    }

    static func displayName(for language: String, locale: Locale = .current) -> String {
        let normalized = normalizedIdentifier(language)
        guard !normalized.isEmpty else {
            return ""
        }
        return locale.localizedString(forIdentifier: normalized) ?? normalized
    }

    private static func normalizedIdentifier(_ identifier: String) -> String {
        identifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
    }

    private static func match(_ language: String, in available: [String]) -> String? {
        guard !language.isEmpty else {
            return nil
        }
        return available.first { $0.caseInsensitiveCompare(language) == .orderedSame }
    }
}

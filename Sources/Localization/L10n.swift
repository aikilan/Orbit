import Foundation

enum AppLanguagePreference: String, CaseIterable, Identifiable {
    case system
    case english
    case simplifiedChinese

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            return L10n.tr("跟随系统")
        case .english:
            return L10n.tr("英文")
        case .simplifiedChinese:
            return L10n.tr("简体中文")
        }
    }
}

enum L10n {
    private static let languagePreferenceKey = "app_language_preference"
    private static let resourceBundleName = "Orbit_Orbit.bundle"
    private static let englishTranslations = loadTranslations(for: "en")
    private static let simplifiedChineseTranslations = loadTranslations(for: "zh-Hans")

    static var currentLanguagePreference: AppLanguagePreference {
        guard let rawValue = UserDefaults.standard.string(forKey: languagePreferenceKey),
              let preference = AppLanguagePreference(rawValue: rawValue) else {
            return .system
        }
        return preference
    }

    static func setLanguagePreference(_ preference: AppLanguagePreference) {
        UserDefaults.standard.set(preference.rawValue, forKey: languagePreferenceKey)
    }

    private static var resolvedTranslations: [String: String] {
        switch currentLanguagePreference {
        case .system:
            if Locale.preferredLanguages.contains(where: { $0.hasPrefix("zh") }) {
                return simplifiedChineseTranslations
            }
        case .english:
            return englishTranslations
        case .simplifiedChinese:
            return simplifiedChineseTranslations
        }

        return englishTranslations
    }

    static func tr(_ key: String, _ arguments: CVarArg...) -> String {
        let format = resolvedTranslations[key] ?? key
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: Locale.current, arguments: arguments)
    }

    static func resourceBundle(mainBundle: Bundle = .main) -> Bundle? {
        let bundles = [mainBundle] + Bundle.allBundles + Bundle.allFrameworks
        let roots = bundles.flatMap { bundle in
            [
                bundle.resourceURL,
                bundle.bundleURL,
                bundle.executableURL?.deletingLastPathComponent(),
            ]
        }.compactMap { $0 }
        var candidateURLs: [URL] = []
        var seenPaths = Set<String>()

        for root in roots {
            var currentURL = root

            for _ in 0..<5 {
                let candidateURL = currentURL.appendingPathComponent(resourceBundleName)
                let candidatePath = candidateURL.standardizedFileURL.path
                if seenPaths.insert(candidatePath).inserted {
                    candidateURLs.append(candidateURL)
                }

                let parentURL = currentURL.deletingLastPathComponent()
                if parentURL.path == currentURL.path {
                    break
                }
                currentURL = parentURL
            }
        }

        for candidateURL in candidateURLs {
            if let bundle = Bundle(url: candidateURL) {
                return bundle
            }
        }

        return nil
    }

    private static func loadTranslations(for languageCode: String) -> [String: String] {
        guard let bundle = resourceBundle() else {
            return [:]
        }

        let subdirectories = Array(
            Set([
                "\(languageCode).lproj",
                "\(languageCode.lowercased()).lproj",
            ])
        )

        for subdirectory in subdirectories {
            if let url = bundle.url(
                forResource: "Localizable",
                withExtension: "strings",
                subdirectory: subdirectory
            ),
            let dictionary = NSDictionary(contentsOf: url) as? [String: String] {
                return dictionary
            }
        }

        return [:]
    }
}

import Foundation

/// The language the UI is showing: the first of the reader's languages the app is translated
/// into (Settings → Fish Pocket → Language, else the system's), English when none is.
/// Engine texts (`{en, zh, …}` plugin and schema strings) and date formats follow it too,
/// so a screen never mixes the app's language with another.

enum AppLanguage {
    /// `zh-Hans`, `en`…: a localization in the bundle.
    static var code: String { Bundle.main.preferredLocalizations.first ?? "en" }

    static var isChinese: Bool { code.lowercased().hasPrefix("zh") }

    static var isSpanish: Bool { code.lowercased().hasPrefix("es") }

    static var locale: Locale { Locale(identifier: code) }

    /// The languages the settings picker offers: the bundle's localizations, each named in itself.
    static let choices: [(code: String, name: String)] = [("zh-Hans", "简体中文"), ("en", "English")]

    /// The language chosen for this app, `nil` when it follows the system. It is the same
    /// `AppleLanguages` entry that Settings → Fish Pocket → Language writes, read from the app's own
    /// domain so the system's list does not count; it takes effect the next time the app starts.
    static var chosen: String? {
        get {
            guard let id = Bundle.main.bundleIdentifier,
                  let first = (UserDefaults.standard.persistentDomain(forName: id)?["AppleLanguages"] as? [String])?.first
            else { return nil }
            return choices.first { first.lowercased().hasPrefix(String($0.code.lowercased().prefix(2))) }?.code
        }
        set {
            if let newValue { UserDefaults.standard.set([newValue], forKey: "AppleLanguages") }
            else { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
        }
    }

    /// `zh-hans` → `zh`: the key the engine's `{en, zh, …}` texts use.
    static var primary: String { String(code.lowercased().prefix { $0 != "-" && $0 != "_" }) }
}

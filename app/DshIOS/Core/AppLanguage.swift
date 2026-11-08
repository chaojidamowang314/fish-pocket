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

    /// The language's name in itself (`简体中文`, `English`), for the settings row that leads to it.
    static var name: String {
        locale.localizedString(forIdentifier: code).map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? code
    }

    /// `zh-hans` → `zh`: the key the engine's `{en, zh, …}` texts use.
    static var primary: String { String(code.lowercased().prefix { $0 != "-" && $0 != "_" }) }
}

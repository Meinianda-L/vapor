import Foundation

/// The language Vapor's interface is showing, so Steam's own text, store content and dates follow it.
/// Decided once per launch by the app bundle's localizations (Settings → 语言 sets AppleLanguages);
/// a build without them (the dev binary, tests) is Chinese, the source language.
public enum AppLanguage {
    public static let isChinese: Bool = {
        guard Bundle.main.localizations.contains("en") else { return true }
        return Bundle.main.preferredLocalizations.first?.hasPrefix("zh") ?? true
    }()

    /// Steam's name for it, as in `l=` parameters and steamui_<language>-json.js.
    public static var steam: String { isChinese ? "schinese" : "english" }

    public static var locale: Locale { isChinese ? Locale(identifier: "zh_CN") : Locale(identifier: "en_US") }
}

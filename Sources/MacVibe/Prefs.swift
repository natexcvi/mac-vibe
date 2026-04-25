import Foundation

/// Centralised access to user-tunable preferences, persisted via UserDefaults.
enum Prefs {
    /// Language code passed to Whisper. `"auto"` means "let the model detect
    /// the spoken language on each utterance"; any value from
    /// `Prefs.supportedLanguages` pins decoding to that language.
    static var language: String {
        get { UserDefaults.standard.string(forKey: "language") ?? "auto" }
        set { UserDefaults.standard.set(newValue, forKey: "language") }
    }

    /// Languages exposed in the menu picker. Whisper supports ~100 — these
    /// are the most commonly used ones; edit this list to taste.
    static let supportedLanguages: [(code: String, label: String)] = [
        ("auto", "Automatic"),
        ("en", "English"),
        ("es", "Spanish"),
        ("fr", "French"),
        ("de", "German"),
        ("it", "Italian"),
        ("pt", "Portuguese"),
        ("nl", "Dutch"),
        ("he", "Hebrew"),
        ("ar", "Arabic"),
        ("ru", "Russian"),
        ("zh", "Mandarin"),
        ("ja", "Japanese"),
        ("ko", "Korean"),
        ("hi", "Hindi"),
    ]
}

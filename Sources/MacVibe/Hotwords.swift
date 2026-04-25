import AppKit
import Foundation

/// User-managed glossary of proper nouns and technical jargon that Whisper
/// tends to mishear. Pulled into the model's `initial_prompt` on each
/// transcription so it biases (softly) toward those terms.
///
/// Storage: a plain text file at
///   ~/Library/Application Support/MacVibe/hotwords.txt
/// — one term per line, blank lines and lines starting with `#` ignored.
///
/// Why this works: Whisper's `initial_prompt` conditions decoding as if the
/// transcript already started with that text. The model expects the listed
/// words to appear and decodes them more readily. It's a *soft* bias, not a
/// hard constraint, so don't dump a thousand words into it (~50–100 is the
/// sweet spot — much more begins to drift the general transcription).
enum Hotwords {
    /// Path to the user-editable glossary file.
    static let storeURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("MacVibe", isDirectory: true)
            .appendingPathComponent("hotwords.txt")
    }()

    /// Reads the file (lazily creating it with a template on first read) and
    /// returns the list of effective terms.
    static func current() -> [String] {
        ensureFileExists()
        guard let text = try? String(contentsOf: storeURL, encoding: .utf8) else { return [] }
        var terms: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            terms.append(line)
        }
        return terms
    }

    /// Creates the support directory and a commented template if absent.
    static func ensureFileExists() {
        let dir = storeURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: storeURL.path) else { return }
        let template = """
            # MacVibe custom dictionary — one term per line.
            #
            # Add proper nouns, names, technical terms, and any other words
            # Whisper tends to mishear. These are passed to the speech model
            # as a soft bias on each transcription.
            #
            # Lines starting with # are ignored. Keep the list to a few dozen
            # high-value terms — much more than that can degrade general
            # accuracy.
            #
            # Examples:
            # Anthropic
            # Claude
            # MacVibe
            # SwiftUI
            # whisper.cpp
            """
        try? template.write(to: storeURL, atomically: true, encoding: .utf8)
    }

    /// Opens the file in the user's default text editor.
    static func openInEditor() {
        ensureFileExists()
        NSWorkspace.shared.open(storeURL)
    }
}

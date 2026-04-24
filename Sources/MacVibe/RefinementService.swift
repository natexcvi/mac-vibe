import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Cleans up raw dictation output with on-device Apple Intelligence.
///
/// Uses the FoundationModels framework (macOS 26+). On older systems or when
/// Apple Intelligence is unavailable, `refine` falls through with the raw text.
final class RefinementService {
    private static let instructions = """
        You clean dictation transcripts. The user spoke into a microphone; you got \
        the transcript. Output a near-verbatim copy with ONLY these edits:

        — Remove disfluencies: "um", "uh", "er", "hmm", and the filler usages of \
          "like" / "you know" / "sort of" / "kind of".
        — Resolve self-corrections: when the speaker restarts or corrects mid-thought, \
          keep only the final intended wording.
        — Remove stuttered word repetitions ("the the cat" → "the cat").
        — Add basic capitalization and punctuation if missing.

        Hard rules (these override everything else):
        — DO NOT rephrase, paraphrase, shorten, translate, or "improve" the wording.
        — DO NOT change vocabulary, technical terms, names, numbers, or word order.
        — DO NOT add commentary, prefaces, quotes, markdown, or explanation.
        — Output should be roughly the SAME LENGTH as input (slightly shorter only \
          when fillers were removed).
        — If the input is already clean, return it unchanged.

        Examples
        ━━━━━━━━
        Input:  "um so I think we should like move the meeting to to Friday you know"
        Output: "I think we should move the meeting to Friday."

        Input:  "the report is due Tuesday actually no Wednesday"
        Output: "The report is due Wednesday."

        Input:  "Send the file to Alex by 5pm."
        Output: "Send the file to Alex by 5pm."
        """

    var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.availability == .available
        }
        #endif
        return false
    }

    /// Streams refined text. Emits partial updates as the model produces them, then
    /// a final value. On unavailability or error, emits the raw text once.
    func refine(_ raw: String, partial: @escaping (String) -> Void) async -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let model = SystemLanguageModel.default
            if model.availability == .available {
                do {
                    let session = LanguageModelSession(instructions: Self.instructions)
                    let stream = session.streamResponse(to: Prompt(trimmed))
                    var latest = ""
                    for try await snapshot in stream {
                        latest = snapshot.content
                        partial(latest)
                    }
                    let final = latest.trimmingCharacters(in: .whitespacesAndNewlines)
                    if final.isEmpty {
                        return trimmed
                    }
                    // Sanity check: if the model returned something dramatically
                    // shorter than the input, it almost certainly summarized
                    // instead of cleaning. Fall back to raw rather than ship
                    // butchered text.
                    let inputLen = trimmed.count
                    let outputLen = final.count
                    if inputLen >= 30, Double(outputLen) / Double(inputLen) < 0.55 {
                        NSLog("RefinementService: refined too short (%d → %d chars), keeping raw", inputLen, outputLen)
                        partial(trimmed)
                        return trimmed
                    }
                    return final
                } catch {
                    NSLog("RefinementService: Apple Intelligence error: \(error) — using raw text")
                    partial(trimmed)
                    return trimmed
                }
            }
        }
        #endif

        partial(trimmed)
        return trimmed
    }
}

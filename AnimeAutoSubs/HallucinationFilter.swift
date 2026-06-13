import Foundation
import FoundationModels

/// Tiered hallucination filter for whisper outputs.
///
/// Whisper's failure mode on near-silent or short audio is to emit a
/// canned closing phrase ("ご視聴ありがとうございました", "Thanks for
/// watching!", "-end-", a fake subtitler credit, etc.). The filter
/// rejects these in three tiers, escalating from cheap to expensive:
///
/// - **Tier A** — synchronous, definite. Patterns that are *never* real
///   dialogue: subtitler credits ("サブタイトル:X", "字幕:X"), end
///   markers ("-end-", "(END)"), and stock single-word stand-ins whisper
///   emits over background noise ("音声", "音楽", "拍手").
/// - **Tier B** — synchronous, heuristic. The "thanks for watching"
///   class — Japanese and English variants whisper hallucinates with
///   high consistency. Dropped instantly with a logged reason.
/// - **Tier C** — asynchronous, LLM-judged. Phrases that *might* be
///   hallucinations but could plausibly be real (e.g. a character
///   actually saying "Thank you"). Routed through the on-device
///   `FoundationModels` language model along with the recently displayed
///   lines as context. The LLM judges whether the candidate fits the
///   surrounding dialogue. If `FoundationModels` is unavailable on the
///   host, Tier C degrades to keep — better to show an outlier than
///   drop real dialogue on a guess.
final class HallucinationFilter: @unchecked Sendable {
    enum Verdict {
        case keep
        case drop(reason: String)
    }

    // MARK: - Tier A (definite hallucinations)

    /// Exact-match drops. Any segment whose normalized text equals one
    /// of these strings is whisper hallucinating over noise / silence.
    private let tierAExact: Set<String> = [
        "音声", "音楽", "拍手", "笑",
        "-end-", "(end)", "(END)",
        "you",
    ]

    /// Anchored regex drops — subtitler/translator credit lines.
    private let tierAPatterns: [NSRegularExpression]

    // MARK: - Tier B (high-probability hallucinations)

    private let tierBExact: Set<String> = [
        "ご視聴ありがとうございました",
        "ご清聴ありがとうございました",
        "ありがとうございました",
        "字幕視聴ありがとうございました",
        "みんな見てくれてありがとう",
        "みんな見てくれてありがとう!",
        "Thanks for watching!",
        "Thank you.", "Thank you",
    ]

    /// Substrings that mark a stock closing-credit hallucination even
    /// when embedded in longer text. "Thanks for watching everyone!"
    /// → drop.
    private let tierBSubstrings: [String] = [
        "thanks for watching",
        "thank you for watching",
        "ご視聴ありがとう",
        "ご清聴ありがとう",
    ]

    // MARK: - Tier C (LLM)

    /// Soft markers — these survive Tier A/B but are flagged for the
    /// LLM context check. Single "Thank you" / "ありがとう" alone is the
    /// motivating case: real dialogue sometimes, hallucination overflow
    /// often. The LLM decides given recent context.
    private let tierCMarkers: [String] = [
        "thank you", "thanks", "ありがとう", "感謝",
    ]

    private let session: LanguageModelSession?
    private let lock = NSLock()
    private var recentDisplayed: [String] = []
    private let maxContext = 6

    init() {
        let patternStrings = [
            #"^\s*サブタイトル\s*[:：].*$"#,
            #"^\s*字幕\s*[:：].*$"#,
            #"^\s*翻訳\s*[:：].*$"#,
            #"^\s*Subtitle\s*[:：].*$"#,
            #"^\s*Translation\s*[:：].*$"#,
            #"^\s*[Aa]uthor\s*[:：].*$"#,
        ]
        self.tierAPatterns = patternStrings.compactMap {
            try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
        }

        switch SystemLanguageModel.default.availability {
        case .available:
            let instructions = """
            You judge whether an automatically transcribed line of Japanese-anime \
            dialogue is plausible or a whisper hallucination. Whisper sometimes \
            emits canned closing phrases ("Thank you", "ありがとうございました", \
            etc.) when fed short or silent audio. Given a candidate line plus the \
            most recent surrounding dialogue, answer only "yes" if the candidate \
            plausibly fits as a real line of dialogue, or "no" if it is likely a \
            hallucinated leftover. Do not explain.
            """
            self.session = LanguageModelSession(instructions: instructions)
            print("[hallucination] LLM available — Tier C enabled")
        case .unavailable(let reason):
            self.session = nil
            print("[hallucination] LLM unavailable (\(reason)) — Tier C degrades to keep")
        }
    }

    // MARK: - Public API

    /// Strip brackets and trim. Returns "" for whitespace-only or
    /// single-character residues — those are never useful subtitles.
    func normalize(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let bracketPattern = #"[\[【((][^\]】)）]*[\]】)）]"#
        if let regex = try? NSRegularExpression(pattern: bracketPattern) {
            let range = NSRange(cleaned.startIndex..., in: cleaned)
            cleaned = regex.stringByReplacingMatches(in: cleaned, range: range, withTemplate: "")
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.allSatisfy({ $0.isWhitespace || $0 == "." || $0 == "…" || $0 == "、" || $0 == "。" }) {
            return ""
        }
        if cleaned.count <= 1 { return "" }
        return cleaned
    }

    /// Tier A + Tier B synchronous check. Pure string operations.
    func quickCheck(text: String) -> Verdict {
        if tierAExact.contains(text) {
            return .drop(reason: "tier-A:exact")
        }
        for regex in tierAPatterns {
            let range = NSRange(text.startIndex..., in: text)
            if regex.firstMatch(in: text, range: range) != nil {
                return .drop(reason: "tier-A:pattern")
            }
        }
        if tierBExact.contains(text) {
            return .drop(reason: "tier-B:exact")
        }
        let lower = text.lowercased()
        for substring in tierBSubstrings {
            if lower.contains(substring.lowercased()) {
                return .drop(reason: "tier-B:substring(\(substring))")
            }
        }
        return .keep
    }

    /// True if `text` matches a Tier C soft marker — caller should run
    /// `plausibleInContext` before scheduling.
    func isAmbiguous(text: String) -> Bool {
        let lower = text.lowercased()
        return tierCMarkers.contains { lower.contains($0.lowercased()) }
    }

    /// Async LLM check. Returns true if the model judges the candidate
    /// plausible given recent context. Returns true unconditionally if
    /// the LLM is unavailable or errors out.
    func plausibleInContext(text: String) async -> Bool {
        guard let session = session else { return true }

        lock.lock()
        let context = recentDisplayed.suffix(maxContext).joined(separator: "\n")
        lock.unlock()

        let prompt = """
        Recent dialogue:
        \(context.isEmpty ? "(none)" : context)

        Candidate line: "\(text)"

        Plausible real dialogue, or whisper hallucination? Answer "yes" or "no".
        """
        do {
            let response = try await session.respond(to: prompt)
            let answer = response.content
                .lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Model occasionally elaborates ("yes, this fits..."). Match
            // on the leading token only. Default to keep on anything we
            // can't parse cleanly.
            if answer.hasPrefix("no") { return false }
            return true
        } catch {
            print("[hallucination] LLM check failed (\(error)) — keeping line")
            return true
        }
    }

    /// Append a displayed line to the rolling context window.
    func recordDisplayed(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        recentDisplayed.append(text)
        if recentDisplayed.count > maxContext {
            recentDisplayed.removeFirst(recentDisplayed.count - maxContext)
        }
    }
}

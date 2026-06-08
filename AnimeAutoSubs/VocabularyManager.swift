import Foundation
import AppKit
import Combine
import UniformTypeIdentifiers

/// One row in the vocabulary list. `id` == `surface` so a recurring word
/// updates in place (set semantics) and the manager can move it to the top.
struct VocabEntry: Identifiable, Equatable {
    let id: String
    let surface: String
    let reading: String?
    var definition: String?  // nil while the jisho fetch is in flight
    var lastSeenAt: Date
}

/// Cumulative list of kanji-bearing tokens seen during a broadcast.
/// - Latest-seen entries float to the top.
/// - Recurring tokens are deduped (set semantics) rather than appearing twice.
/// - Definitions are fetched lazily from jisho.org and cached for the session.
@MainActor
final class VocabularyManager: ObservableObject {
    @Published private(set) var entries: [VocabEntry] = []

    private var definitionCache: [String: String] = [:]
    private var inFlight: Set<String> = []

    /// Record every kanji-bearing token from a displayed phrase. Tokens that
    /// are pure kana/punctuation are skipped (not pedagogically interesting).
    func record(_ tokens: [FuriganaPair]) {
        let now = Date()
        for token in tokens where containsKanji(token.surface) {
            recordSingle(token, at: now)
        }
    }

    private func recordSingle(_ token: FuriganaPair, at now: Date) {
        entries.removeAll { $0.surface == token.surface }
        let entry = VocabEntry(
            id: token.surface,
            surface: token.surface,
            reading: token.reading,
            definition: definitionCache[token.surface],
            lastSeenAt: now
        )
        entries.insert(entry, at: 0)

        if definitionCache[token.surface] == nil && !inFlight.contains(token.surface) {
            inFlight.insert(token.surface)
            Task { @MainActor in
                let def = await Self.fetchDefinition(for: token.surface)
                self.inFlight.remove(token.surface)
                if let def = def {
                    self.definitionCache[token.surface] = def
                    if let idx = self.entries.firstIndex(where: { $0.surface == token.surface }) {
                        self.entries[idx].definition = def
                    }
                }
            }
        }
    }

    func clear() {
        entries.removeAll()
    }

    /// Save the current list to a user-chosen text file, latest-first.
    func saveToFile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "vocabulary.txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.title = "Save vocabulary list"
        panel.begin { [entries] response in
            guard response == .OK, let url = panel.url else { return }
            let lines: [String] = entries.map { e in
                var line = e.surface
                if let r = e.reading, r != e.surface {
                    line += " (\(r))"
                }
                if let d = e.definition {
                    line += " — \(d)"
                }
                return line
            }
            let text = lines.joined(separator: "\n") + "\n"
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func containsKanji(_ s: String) -> Bool {
        s.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) ||
            (0x3400...0x4DBF).contains(scalar.value)
        }
    }

    // MARK: - Jisho API

    /// Fetch the first English definition from jisho.org for `word`.
    /// Returns up to 3 short glosses joined by ", ".
    static func fetchDefinition(for word: String) async -> String? {
        let encoded = word.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? word
        guard let url = URL(string: "https://jisho.org/api/v1/search/words?keyword=\(encoded)") else {
            return nil
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode(JishoResponse.self, from: data)
            guard let firstEntry = decoded.data.first, let firstSense = firstEntry.senses.first else {
                return nil
            }
            return firstSense.english_definitions.prefix(3).joined(separator: ", ")
        } catch {
            return nil
        }
    }

    private struct JishoResponse: Decodable {
        let data: [Entry]
        struct Entry: Decodable {
            let senses: [Sense]
        }
        struct Sense: Decodable {
            let english_definitions: [String]
        }
    }
}

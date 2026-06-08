import Foundation
import Combine

/// One token from MeCab. `surface` is the displayed glyph (kanji or kana),
/// `reading` is its hiragana reading (only set when the surface contains kanji).
struct FuriganaPair {
    let surface: String
    let reading: String?
}

/// Wraps the homebrew `mecab` binary with the UniDic dictionary.
final class MeCabParser {
    private let mecabPath = "/opt/homebrew/bin/mecab"
    private let dicPath = "/opt/homebrew/lib/mecab/dic/unidic"

    /// Tokenize Japanese text into surface/reading pairs. Returns nil if mecab fails to run.
    func tokenize(_ text: String) -> [FuriganaPair]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: mecabPath)
        process.arguments = ["-d", dicPath]

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            print("[mecab] process failed: \(error)")
            return nil
        }

        inputPipe.fileHandleForWriting.write(Data((text + "\n").utf8))
        inputPipe.fileHandleForWriting.closeFile()
        process.waitUntilExit()

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }

        let tokens = parseMeCabOutput(output)
        return tokens.isEmpty ? nil : tokens
    }

    private func parseMeCabOutput(_ output: String) -> [FuriganaPair] {
        var tokens: [FuriganaPair] = []
        for line in output.components(separatedBy: "\n") {
            if line == "EOS" || line.isEmpty { continue }

            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 2 else { continue }

            let surface = parts[0]

            let reading: String?
            if parts.count >= 2, surfaceContainsKanji(surface) {
                reading = katakanaToHiragana(parts[1])
            } else {
                reading = nil
            }

            tokens.append(FuriganaPair(surface: surface, reading: reading))
        }
        return tokens
    }

    private func surfaceContainsKanji(_ s: String) -> Bool {
        s.unicodeScalars.contains { scalar in
            // CJK Unified Ideographs + CJK Extension A
            (0x4E00...0x9FFF).contains(scalar.value) ||
            (0x3400...0x4DBF).contains(scalar.value)
        }
    }

    private func katakanaToHiragana(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            if (0x30A1...0x30F6).contains(scalar.value) {
                result += String(Unicode.Scalar(scalar.value - 0x60)!)
            } else {
                result += String(scalar)
            }
        }
        return result
    }
}

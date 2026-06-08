import Foundation
import AppKit
import ApplicationServices

/// One runtime dependency the app needs to function fully.
/// Each entry knows how to verify its own presence and how to instruct
/// the user to install it (both GUI and terminal paths).
struct Dependency: Identifiable {
    let id: String
    let name: String
    /// Why the app needs this — shown to the user.
    let purpose: String
    /// Returns true if the dependency is present.
    let isPresent: () -> Bool
    /// One-line install instructions for non-technical users.
    let guiInstructions: String
    /// Optional Homepage / download URL.
    let downloadURL: String?
    /// Optional terminal command for technical users (copyable).
    let terminalCommand: String?
}

enum DependencyCheck {
    /// All runtime dependencies the app expects on the host machine.
    /// (BroadcastDelayManager looks for BlackHole; WhisperTranscriber for the model
    /// and the cli; MeCabParser for mecab + dictionary.)
    static let all: [Dependency] = [
        Dependency(
            id: "safari-extension",
            name: "Safari extension",
            purpose: "AnimeAutoSubs delegates play / pause control of the source video to its Safari Web Extension (no synthetic clicks, works inside cross-origin iframes, works regardless of player wrapper). Without it, the dialog's Play / Pause button has no effect on the source.",
            isPresent: { SafariExtensionStatusChecker.shared.isEnabled },
            guiInstructions: "Open Safari → Settings → Extensions. Tick \"AnimeAutoSubs Extension\". If it's missing entirely, quit and relaunch AnimeAutoSubs (which registers the extension with macOS), then reopen Safari → Settings → Extensions and tick it. After enabling, click \"Re-check\" below.",
            downloadURL: nil,
            terminalCommand: nil
        ),
        Dependency(
            id: "accessibility",
            name: "Accessibility access",
            purpose: "Lets AnimeAutoSubs intercept the volume keys globally. macOS ties this grant to the app's signature, so rebuilding or reinstalling AnimeAutoSubs quietly invalidates it.",
            isPresent: { AXIsProcessTrusted() },
            guiInstructions: "Open System Settings → Privacy & Security → Accessibility. Remove any existing AnimeAutoSubs entry (select it and click −), then add the new one (drag /Applications/AnimeAutoSubs.app into the list or click +) and toggle it on. Quit and relaunch AnimeAutoSubs.",
            downloadURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            terminalCommand: nil
        ),
        Dependency(
            id: "screen-recording",
            name: "Screen Recording access",
            purpose: "Required by ScreenCaptureKit to capture the browser window's video and audio. macOS ties this grant to the app's signature, so rebuilding or reinstalling AnimeAutoSubs quietly invalidates it.",
            isPresent: { CGPreflightScreenCaptureAccess() },
            guiInstructions: "Open System Settings → Privacy & Security → Screen & System Audio Recording. Remove any existing AnimeAutoSubs entry (select it and click −), then add the new one (drag /Applications/AnimeAutoSubs.app into the list or click +) and toggle it on. Quit and relaunch AnimeAutoSubs.",
            downloadURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            terminalCommand: nil
        ),
        Dependency(
            id: "whisper-cli",
            name: "whisper.cpp",
            purpose: "Transcribes Japanese speech to text in real time.",
            isPresent: { FileManager.default.fileExists(atPath: "/opt/homebrew/bin/whisper-cli") },
            guiInstructions: "Install Homebrew from brew.sh, then open Terminal and run:  brew install whisper-cpp",
            downloadURL: "https://brew.sh",
            terminalCommand: "brew install whisper-cpp"
        ),
        Dependency(
            id: "mecab",
            name: "MeCab",
            purpose: "Splits Japanese text into words so each kanji can be annotated with its hiragana reading (furigana).",
            isPresent: { FileManager.default.fileExists(atPath: "/opt/homebrew/bin/mecab") },
            guiInstructions: "Open Terminal and run:  brew install mecab",
            downloadURL: "https://brew.sh",
            terminalCommand: "brew install mecab"
        ),
        Dependency(
            id: "unidic",
            name: "UniDic dictionary",
            purpose: "Provides hiragana readings MeCab uses for furigana.",
            isPresent: {
                let path = "/opt/homebrew/lib/mecab/dic/unidic"
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
            },
            guiInstructions: "Open Terminal and run:  brew install mecab-unidic",
            downloadURL: "https://brew.sh",
            terminalCommand: "brew install mecab-unidic"
        ),
        Dependency(
            id: "whisper-model",
            name: "Whisper model (ggml-small.bin)",
            purpose: "The neural network weights AnimeAutoSubs uses to transcribe Japanese speech.",
            isPresent: {
                let path = NSHomeDirectory() + "/Library/Application Support/AnimeAutoSubs/ggml-small.bin"
                return FileManager.default.fileExists(atPath: path)
            },
            guiInstructions: "Download ggml-small.bin (~466 MB) from huggingface.co/ggerganov/whisper.cpp and place it in  ~/Library/Application Support/AnimeAutoSubs/",
            downloadURL: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin",
            terminalCommand: "mkdir -p ~/Library/Application\\ Support/AnimeAutoSubs && curl -L 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin' -o ~/Library/Application\\ Support/AnimeAutoSubs/ggml-small.bin"
        ),
        Dependency(
            id: "blackhole",
            name: "BlackHole 2ch",
            purpose: "Virtual audio driver that lets AnimeAutoSubs route the source's audio without you hearing it twice.",
            isPresent: { AudioDeviceManager.shared.findBlackHole() != nil },
            guiInstructions: "Download BlackHole 2ch from existential.audio and run the installer. Restart AnimeAutoSubs afterwards.",
            downloadURL: "https://existential.audio/blackhole/",
            terminalCommand: "brew install --cask blackhole-2ch"
        ),
    ]

    static func missing() -> [Dependency] {
        all.filter { !$0.isPresent() }
    }

    /// All dependencies paired with their current presence status — used by the dashboard.
    static func statuses() -> [DependencyStatus] {
        all.map { DependencyStatus(dep: $0, present: $0.isPresent()) }
    }
}

struct DependencyStatus: Identifiable {
    let dep: Dependency
    let present: Bool
    var id: String { dep.id }
}

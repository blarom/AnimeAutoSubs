import Foundation
import SwiftUI
import Combine

/// Drives a 2-line subtitle display synced to delayed audio playback.
/// Phrases are scheduled for a future Date, displayed in the bottom slot,
/// and bubble up to the top slot when a newer phrase arrives. They expire
/// after `persistSeconds` of *active broadcast time* on screen (the clock
/// pauses while playback is paused) so stale lines don't stick forever
/// when nothing new is being said.
class SubtitleManager: ObservableObject {
    enum LineColor {
        case white
        case yellow

        var swiftUIColor: Color {
            switch self {
            case .white: return Color.white
            case .yellow: return Color(red: 1.0, green: 0.93, blue: 0.4)
            }
        }
    }

    struct DisplayedPhrase: Identifiable {
        let id = UUID()
        let tokens: [FuriganaPair]
        let color: LineColor
        /// Wall-clock time the phrase started showing. Bumped forward by the
        /// pause duration on resume so paused time doesn't count toward expiry.
        var displayedAt: Date
    }

    @Published var line1: DisplayedPhrase?  // older line, shown on top
    @Published var line2: DisplayedPhrase?  // newer line, shown on bottom
    @Published var isPaused: Bool = false
    @Published var persistSeconds: Double = BroadcastConstants.defaultSubtitlePersistSeconds {
        didSet { UserDefaults.standard.set(persistSeconds, forKey: "subtitlePersistSeconds") }
    }

    /// Fired on the main runloop whenever a new phrase enters the displayed
    /// set (i.e., its scheduled display time arrived and pause isn't active).
    /// Used by the vocabulary dashboard to record tokens as they appear.
    var onPhraseDisplayed: (([FuriganaPair]) -> Void)?

    private struct PendingPhrase {
        let tokens: [FuriganaPair]
        let color: LineColor
        let displayTime: Date
    }

    private var pending: [PendingPhrase] = []
    private var displayedPhrases: [DisplayedPhrase] = []
    private var nextColorIsYellow = false
    private var schedulerTimer: Timer?
    private var pausedAt: Date?

    init() {
        if let saved = UserDefaults.standard.object(forKey: "subtitlePersistSeconds") as? Double,
           BroadcastConstants.subtitlePersistRange.contains(saved) {
            persistSeconds = saved
        }
        startScheduler()
    }

    private func startScheduler() {
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        schedulerTimer = timer
    }

    /// Schedule a transcribed phrase to display at a specific (clock) time —
    /// the time is aligned with the moment its audio chunk is heard.
    func schedule(tokens: [FuriganaPair], displayAt: Date) {
        DispatchQueue.main.async {
            let color: LineColor = self.nextColorIsYellow ? .yellow : .white
            self.nextColorIsYellow.toggle()
            self.pending.append(PendingPhrase(tokens: tokens, color: color, displayTime: displayAt))
            self.pending.sort { $0.displayTime < $1.displayTime }
        }
    }

    func clear() {
        DispatchQueue.main.async {
            self.line1 = nil
            self.line2 = nil
            self.displayedPhrases.removeAll()
            self.pending.removeAll()
        }
    }

    /// Stop adding new phrases AND stop the expiry clock. Already-displayed
    /// phrases stay visible indefinitely while paused.
    func pauseRetirement() {
        DispatchQueue.main.async {
            self.isPaused = true
            self.pausedAt = Date()
        }
    }

    /// Resume new phrases + expiry. Bumps every displayed phrase's
    /// `displayedAt` AND every pending phrase's `displayTime` forward by the
    /// pause duration so paused wall-clock time isn't counted. Without the
    /// pending shift, subtitles scheduled to display during the pause would
    /// all be "overdue" at resume and pile in via the 10 Hz tick — drowning
    /// the actual audio by several seconds.
    func resumeRetirement() {
        DispatchQueue.main.async {
            self.isPaused = false
            if let pausedAt = self.pausedAt {
                let pauseDuration = Date().timeIntervalSince(pausedAt)
                for i in self.displayedPhrases.indices {
                    self.displayedPhrases[i].displayedAt = self.displayedPhrases[i].displayedAt.addingTimeInterval(pauseDuration)
                }
                for i in self.pending.indices {
                    let p = self.pending[i]
                    self.pending[i] = PendingPhrase(
                        tokens: p.tokens,
                        color: p.color,
                        displayTime: p.displayTime.addingTimeInterval(pauseDuration)
                    )
                }
                self.pausedAt = nil
            }
        }
    }

    private func tick() {
        let now = Date()
        guard !isPaused else {
            republish()
            return
        }
        // Drain at most ONE pending phrase per tick. The 10 Hz timer means a
        // queue of N pending segments shows up at 100 ms / phrase, instead of
        // all-in-one-tick where the FIFO cap (count > 2) would silently drop
        // the older ones before SwiftUI ever paints them.
        if let next = pending.first, next.displayTime <= now {
            pending.removeFirst()
            let phrase = DisplayedPhrase(tokens: next.tokens, color: next.color, displayedAt: now)
            displayedPhrases.append(phrase)
            var droppedFromFront = false
            if displayedPhrases.count > 2 {
                displayedPhrases.removeFirst(displayedPhrases.count - 2)
                droppedFromFront = true
            }
            let surfaces = phrase.tokens.map(\.surface).joined()
            if droppedFromFront {
                print("[subtitle] displayed (FIFO push, oldest dropped): \"\(surfaces)\"")
            } else {
                print("[subtitle] displayed: \"\(surfaces)\"")
            }
            onPhraseDisplayed?(phrase.tokens)
        }
        displayedPhrases.removeAll { now.timeIntervalSince($0.displayedAt) >= persistSeconds }
        republish()
    }

    /// Skip @Published assignments when the values haven't changed — tick() runs
    /// at 10Hz, so without this SwiftUI would re-evaluate the subtitle rows
    /// 10× per second on static content.
    private func republish() {
        let count = displayedPhrases.count
        let newLine1: DisplayedPhrase?
        let newLine2: DisplayedPhrase?
        if count >= 2 {
            newLine1 = displayedPhrases[count - 2]
            newLine2 = displayedPhrases[count - 1]
        } else if count == 1 {
            newLine1 = nil
            newLine2 = displayedPhrases[0]
        } else {
            newLine1 = nil
            newLine2 = nil
        }
        if line1?.id != newLine1?.id { line1 = newLine1 }
        if line2?.id != newLine2?.id { line2 = newLine2 }
    }
}

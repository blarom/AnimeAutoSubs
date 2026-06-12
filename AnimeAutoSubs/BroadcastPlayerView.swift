import SwiftUI
import AppKit
import Combine

struct BroadcastPlayerView: View {
    @ObservedObject var manager: BroadcastDelayManager
    @ObservedObject var subtitleManager: SubtitleManager
    @ObservedObject var bridge: ExtensionBridge
    let onPlayPause: () -> Void
    let onSkip: (Double) -> Void
    let onSeek: (Double) -> Void
    let onClose: () -> Void

    /// While the user is dragging the scrub slider, we stop mirroring
    /// `bridge.sourceCurrentTime` into the slider value and instead let
    /// the user's drag control it. `scrubTarget` holds the in-flight
    /// drag value so we can render a hint label and send a single seek
    /// command on release.
    @State private var isScrubbing = false
    @State private var scrubTarget: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            videoArea
            subtitleArea
            playbackBar
        }
        .background(Color.black)
    }

    // MARK: - Playback controls (bottom bar)

    private var playbackBar: some View {
        HStack(spacing: 6) {
            playPauseButton
            skipButton(systemName: "gobackward.30", delta: -30, help: "Skip back 30 seconds")
            skipButton(systemName: "gobackward.10", delta: -10, help: "Skip back 10 seconds")
            skipButton(systemName: "goforward.10",  delta:  10, help: "Skip forward 10 seconds")
            skipButton(systemName: "goforward.30",  delta:  30, help: "Skip forward 30 seconds")

            Text(formatTime(displayedTime))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.85))
                .frame(minWidth: 44, alignment: .trailing)
                .padding(.leading, 4)

            ZStack(alignment: .top) {
                Slider(
                    value: Binding(
                        get: { sliderValue },
                        set: { scrubTarget = $0 }
                    ),
                    in: 0...max(bridge.sourceDuration, 0.001),
                    onEditingChanged: { editing in
                        if editing {
                            isScrubbing = true
                            scrubTarget = sliderValue
                        } else {
                            isScrubbing = false
                            onSeek(scrubTarget)
                        }
                    }
                )
                .disabled(!sourceTimeAvailable)
                .tint(.white)

                if isScrubbing {
                    Text(formatTime(scrubTarget))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.8)))
                        .foregroundColor(.white)
                        .offset(y: -22)
                        .allowsHitTesting(false)
                }
            }

            Text(formatTime(bridge.sourceDuration))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.6))
                .frame(minWidth: 44, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .frame(height: BroadcastConstants.broadcastPlaybackBarHeight)
        .background(Color.black)
    }

    private var playPauseButton: some View {
        Button(action: onPlayPause) {
            Image(systemName: manager.isPaused ? "play.fill" : "pause.fill")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.white)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .disabled(!manager.engineSetupComplete)
        .opacity(manager.engineSetupComplete ? 1.0 : 0.35)
        .help(manager.isPaused ? "Play (source + broadcast)" : "Pause (source + broadcast)")
    }

    private func skipButton(systemName: String, delta: Double, help: String) -> some View {
        Button {
            onSkip(delta)
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.white)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .disabled(!sourceTimeAvailable)
        .opacity(sourceTimeAvailable ? 1.0 : 0.35)
        .help(help)
    }

    /// Slider position: tracks the user's drag while scrubbing, otherwise
    /// mirrors the live source playback time.
    private var sliderValue: Double {
        isScrubbing ? scrubTarget : bridge.sourceCurrentTime
    }

    /// Current-time label: shows the scrub target while dragging so the
    /// numeric readout matches what the slider thumb is pointing at.
    private var displayedTime: Double {
        isScrubbing ? scrubTarget : bridge.sourceCurrentTime
    }

    private var sourceTimeAvailable: Bool {
        bridge.sourceDuration > 0
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%d:%02d", m, s)
        }
    }

    // MARK: - Video area

    private var videoArea: some View {
        ZStack(alignment: .topTrailing) {
            VideoLayerHost(layer: manager.videoLayer)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .aspectRatio(displayAspect, contentMode: .fit)
                .overlay {
                    if manager.blurEnglishSubtitles {
                        GeometryReader { geo in
                            ForEach(Array(manager.detectedSubtitleRects.enumerated()), id: \.offset) { _, normRect in
                                let mapped = mapVisionRectToView(normRect, viewSize: geo.size)
                                EnglishSubtitleBlurView()
                                    .frame(width: mapped.width, height: mapped.height)
                                    .position(x: mapped.midX, y: mapped.midY)
                            }
                        }
                        .allowsHitTesting(false)
                    }
                }

            bufferingOverlay

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .padding(6)
                    .background(Circle().fill(Color.black.opacity(0.6)))
            }
            .buttonStyle(.plain)
            .help("Close broadcast")
            .padding(8)
        }
        .frame(minHeight: 240)
    }

    private func mapVisionRectToView(_ rect: CGRect, viewSize: CGSize) -> CGRect {
        // Vision uses normalized [0,1] coords with origin at bottom-left.
        // SwiftUI uses pixel coords with origin at top-left.
        let x = rect.origin.x * viewSize.width
        let y = (1 - rect.origin.y - rect.height) * viewSize.height
        let w = rect.width * viewSize.width
        let h = rect.height * viewSize.height
        // Tight padding around detected text (just enough to fully cover descender/ascender bounds)
        let pad: CGFloat = 2
        return CGRect(x: x - pad, y: y - pad, width: w + pad * 2, height: h + pad * 2)
    }

    private var bufferingOverlay: some View {
        Group {
            if case .buffering(let progress) = manager.mode {
                let remaining = max(0, manager.delaySeconds * (1 - progress))
                ZStack {
                    Color.black.opacity(0.7)
                    VStack(spacing: 12) {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .tint(.white)
                            .frame(width: 200)
                        Text(String(format: "Buffering… %.1fs", remaining))
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .foregroundColor(.white)
                    }
                }
                .transition(.opacity)
            } else if case .starting = manager.mode {
                ZStack {
                    Color.black.opacity(0.7)
                    ProgressView().tint(.white)
                }
            } else if manager.isPaused && !manager.hasEverEmittedFrame {
                ZStack {
                    Color.black
                    VStack(spacing: 12) {
                        Image(systemName: "pause.circle")
                            .font(.system(size: 36))
                            .foregroundColor(.white.opacity(0.7))
                        Text("Source paused — click Play to start")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: manager.mode)
    }

    private var subtitleArea: some View {
        VStack(spacing: 6) {
            phraseRow(subtitleManager.line1)
            phraseRow(subtitleManager.line2)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .frame(height: subtitleAreaHeight)
        .background(Color.black)
        .clipped()
    }

    /// Fixed total subtitle area height: two slots + spacing + vertical padding.
    /// Multi-line content within a slot can overflow vertically (overlapping the
    /// other slot or the video) — that's the explicit trade-off the user wants
    /// instead of the area growing and pushing the video around.
    private var subtitleAreaHeight: CGFloat {
        BroadcastConstants.broadcastSubtitleAreaHeight(fontSize: manager.subtitleFontSize)
    }

    /// Fixed slot height per row. An empty row renders Color.clear at this height
    /// so a single phrase occupies the SAME bottom-row position whether or not the
    /// top row is filled. Multi-line wrapped content stays centered on this slot
    /// (extending above/below it) rather than reflowing the layout.
    private var rowHeight: CGFloat {
        let main = manager.subtitleFontSize * 1.2  // main-text line height
        let ruby = manager.subtitleFontSize * 0.42 * 1.2  // ruby-text line height
        return main + 1 + ruby
    }

    @ViewBuilder
    private func phraseRow(_ phrase: SubtitleManager.DisplayedPhrase?) -> some View {
        Group {
            if let phrase = phrase {
                GeometryReader { geo in
                    // Auto-fit: if the phrase at the user's preferred font size would
                    // exceed the row's width, shrink just *this* phrase so it stays on
                    // one line. The font-size slider remains authoritative for normal
                    // phrases — this is a per-phrase ceiling, not a global override.
                    let baseSize = manager.subtitleFontSize
                    let scale = autoFitScale(phrase: phrase, availableWidth: geo.size.width, baseSize: baseSize)
                    let effective = baseSize * scale

                    ZStack(alignment: .bottom) {
                        WrappingHStack(horizontalSpacing: 0, verticalSpacing: 4) {
                            ForEach(Array(phrase.tokens.enumerated()), id: \.offset) { _, token in
                                rubyToken(token, fontSize: effective, color: phrase.color.swiftUIColor)
                            }
                        }
                        .allowsHitTesting(false)

                        RubyTextView(
                            tokens: phrase.tokens,
                            mainSize: effective,
                            mainColor: .clear
                        )
                        .frame(height: effective * 1.2)
                        .allowsHitTesting(subtitleManager.isPaused)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: rowHeight, alignment: .center)
    }

    /// Estimate the natural width of a phrase at `baseSize` and return a scale
    /// factor in (0.5, 1.0] that fits it within `availableWidth`. Each token's
    /// width is `max(surfaceWidth, rubyWidth)` (ruby annotations widen narrow
    /// kanji to fit their reading) and full-width Japanese glyphs are roughly
    /// one font-unit wide. Floor at 0.5 so the text never becomes unreadably
    /// small — at that point the user can drop the persistence higher and
    /// pause to read.
    private func autoFitScale(phrase: SubtitleManager.DisplayedPhrase, availableWidth: CGFloat, baseSize: CGFloat) -> Double {
        guard availableWidth > 0 else { return 1.0 }
        let rubyRatio: CGFloat = 0.42
        var natural: CGFloat = 0
        for token in phrase.tokens {
            let surfaceW = CGFloat(token.surface.count) * baseSize
            var rubyW: CGFloat = 0
            if let reading = token.reading, reading != token.surface {
                rubyW = CGFloat(reading.count) * baseSize * rubyRatio
            }
            natural += max(surfaceW, rubyW)
        }
        if natural <= availableWidth { return 1.0 }
        return max(0.5, Double(availableWidth / natural))
    }

    /// Renders one mecab token: surface on the baseline, hiragana reading
    /// (when present) above it as a smaller "ruby" annotation centered horizontally.
    /// Non-selectable on purpose — the RubyTextView overlay handles selection.
    @ViewBuilder
    private func rubyToken(_ token: FuriganaPair, fontSize: CGFloat, color: Color) -> some View {
        let rubySize = fontSize * 0.42
        VStack(spacing: 1) {
            if let reading = token.reading, reading != token.surface {
                Text(reading)
                    .font(.system(size: rubySize, weight: .regular))
                    .foregroundColor(color.opacity(0.75))
            } else {
                // Empty placeholder of the same height so all tokens align on the same baseline.
                Color.clear.frame(height: rubySize * 1.15)
            }
            Text(token.surface)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundColor(color)
        }
        .fixedSize()
    }

    private var sourceAspect: CGFloat {
        let size = manager.sourceWindowSize
        if size.width > 0 && size.height > 0 { return size.width / size.height }
        return 16.0 / 9.0
    }

    private var displayAspect: CGFloat { sourceAspect }
}

// MARK: - Layer host

struct VideoLayerHost: NSViewRepresentable {
    let layer: CALayer

    func makeNSView(context: Context) -> ContainerView {
        let view = ContainerView()
        view.wantsLayer = true
        view.layer = CALayer()
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.hostedLayer = layer
        view.layer?.addSublayer(layer)
        return view
    }

    func updateNSView(_ nsView: ContainerView, context: Context) {
        nsView.needsLayout = true
    }

    final class ContainerView: NSView {
        weak var hostedLayer: CALayer?
        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hostedLayer?.frame = bounds
            CATransaction.commit()
        }
    }
}

// MARK: - English subtitle blur
// Strong gaussian blur (via NSVisualEffectView) so text becomes unreadable
// while letting the general colors behind it show through. No tint or opacity
// customization — the .hudWindow material gives a sensible default look on
// dark anime backgrounds.

struct EnglishSubtitleBlurView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .withinWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = 10
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

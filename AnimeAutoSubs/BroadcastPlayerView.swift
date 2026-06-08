import SwiftUI
import AppKit
import Combine

struct BroadcastPlayerView: View {
    @ObservedObject var manager: BroadcastDelayManager
    @ObservedObject var subtitleManager: SubtitleManager
    let onPlayPause: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            videoArea
            subtitleArea
        }
        .background(Color.black)
    }

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
        rowHeight * 2 + 6 + 28
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

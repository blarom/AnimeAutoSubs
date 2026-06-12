import SwiftUI
import Combine
import ScreenCaptureKit

struct WizardDialogView: View {
    @ObservedObject var wizard: BroadcastWizard
    @ObservedObject var broadcastManager: BroadcastDelayManager
    @ObservedObject var subtitleManager: SubtitleManager
    @ObservedObject var mediaSource: MediaSourceRouter
    let onStop: () -> Void

    /// User-dismissed for the current dialog lifetime. Recreated when the
    /// dialog is re-opened (start broadcast → stop → start), which is the
    /// right window for the tip to reappear if the connection is still
    /// silent.
    @State private var sourceTipDismissed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let app = wizard.sourceWindow?.owningApplication?.applicationName,
               let title = wizard.sourceWindow?.title {
                HStack(spacing: 6) {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text("\(app) — \(title)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Divider()

            Text(stageInstruction)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            switch wizard.stage {
            case .fine:
                VStack(spacing: 8) {
                    Button {
                        wizard.autofitVideoRect()
                    } label: {
                        HStack {
                            Image(systemName: "rectangle.dashed.and.paperclip")
                            Text("Autofit")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .help("Detects the largest video-like rectangle in the source window")
                    Button("Confirm video region") { wizard.confirmFine() }
                        .keyboardShortcut(.defaultAction)
                        .frame(maxWidth: .infinity)
                }
            case .broadcasting:
                broadcastingControls
            case .idle:
                EmptyView()
            }
        }
        .padding(14)
        .frame(width: 360)
        .background(.regularMaterial)
        .cornerRadius(10)
    }

    private var header: some View {
        HStack {
            Image(systemName: stageIcon)
                .foregroundColor(stageColor)
            Text(stageTitle)
                .font(.headline)
            Spacer()
            if wizard.stage == .fine {
                Button("Cancel", action: { wizard.cancel() })
                    .controlSize(.small)
            }
        }
    }

    private var broadcastingControls: some View {
        VStack(spacing: 10) {
            sourceConnectionTip

            // Broadcast state indicator. The Safari Web Extension delivers
            // play/pause directly to the source video element, and reports
            // play/pause events back via App Group IPC, so this row stays
            // in sync with reality without any synthetic-event guesswork.
            // The Toggle button manually flips the broadcast's belief —
            // useful when the source was toggled outside the app.
            HStack(spacing: 8) {
                Circle()
                    .fill(broadcastManager.isPaused ? Color.orange : Color.green)
                    .frame(width: 10, height: 10)
                Text("Broadcast: \(broadcastManager.isPaused ? "Paused" : "Playing")")
                    .font(.caption)
                Spacer()
                Button("Toggle") {
                    broadcastManager.syncToggle()
                }
                .controlSize(.small)
                .help("Flip the broadcast's belief of source state without sending a command. Use when the source was toggled outside the app.")
                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .foregroundColor(.red)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Stop broadcasting")
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))

            // Volume
            labeledSlider(title: "Volume", icon: volumeIcon) {
                Slider(value: Binding(
                    get: { Double(broadcastManager.outputVolume) },
                    set: { broadcastManager.outputVolume = Float($0) }
                ), in: Double(BroadcastConstants.volumeRange.lowerBound)...Double(BroadcastConstants.volumeRange.upperBound))
                trailingValue("\(Int(broadcastManager.outputVolume * 100))%")
            }

            // Audio output device the engine is currently routed to.
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2")
                    .frame(width: 16)
                    .foregroundColor(.secondary)
                if let route = broadcastManager.outputRouteName {
                    Text("Output: \(route)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else if broadcastManager.engineSetupComplete {
                    Text("Output: not routed (pick one in the menu bar)")
                        .font(.caption)
                        .foregroundColor(.orange)
                } else {
                    Text("Output: connecting…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .help("Where the delayed audio is being sent. Change in 字 → Audio Output (delayed).")

            // Subtitle font size
            labeledSlider(title: "Subtitle font size", icon: "textformat.size") {
                Slider(value: $broadcastManager.subtitleFontSize, in: BroadcastConstants.subtitleFontSizeRange)
                trailingValue("\(Int(broadcastManager.subtitleFontSize))pt")
            }

            // Subtitle persistence
            labeledSlider(title: "Subtitle persistence", icon: "hourglass") {
                Slider(value: $subtitleManager.persistSeconds, in: BroadcastConstants.subtitlePersistRange)
                trailingValue(String(format: "%.1fs", subtitleManager.persistSeconds))
            }

            // Blur English subs toggle
            Toggle(isOn: $broadcastManager.blurEnglishSubtitles) {
                HStack {
                    Image(systemName: "rectangle.dashed.badge.record")
                        .frame(width: 16)
                        .foregroundColor(.secondary)
                    Text("Blur English subtitles")
                        .font(.system(size: 12))
                }
            }
            .toggleStyle(.checkbox)

            // Capture quality (applies on next broadcast start)
            VStack(alignment: .leading, spacing: 4) {
                Text("Capture quality")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack {
                    Image(systemName: "speedometer")
                        .frame(width: 16)
                        .foregroundColor(.secondary)
                    Picker("", selection: $broadcastManager.captureQuality) {
                        ForEach(BroadcastDelayManager.CaptureQuality.allCases, id: \.self) { q in
                            Text(q.rawValue).tag(q)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
            }
            .help("Performance mode reduces capture resolution to ~50% (saves memory). Applies on next broadcast start.")

            // Transcription load (applies live)
            VStack(alignment: .leading, spacing: 4) {
                Text("Transcription load")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack {
                    Image(systemName: "cpu")
                        .frame(width: 16)
                        .foregroundColor(.secondary)
                    Picker("", selection: $broadcastManager.transcriptionLoad) {
                        ForEach(BroadcastDelayManager.TranscriptionLoad.allCases, id: \.self) { load in
                            Text(load.rawValue).tag(load)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
            }
            .help("Light = 1 whisper at a time / 2 threads each (lowest CPU; bursts may delay subtitles). Balanced = 2 / 4 threads (default, safe on M-series 8-core). Maximum = 3 / 4 threads (best subtitle latency; may cause audio skips on busy systems).")

            HStack {
                Text(modeText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
    }

    /// Soft tip shown while the extension hasn't reported any state event
    /// in this broadcast session. Most commonly means the user hasn't yet
    /// triggered playback on the source page so the `<video>` element
    /// hasn't been instantiated — Play/Pause from the dialog will appear
    /// to do nothing in that window. The tip auto-disappears the moment
    /// the bridge sees the first play/pause event, and can be dismissed
    /// manually.
    @ViewBuilder
    private var sourceConnectionTip: some View {
        if !mediaSource.isAvailable && !sourceTipDismissed {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .foregroundColor(.blue)
                Text("If Play/Pause has no effect, the source video element hasn't been initialized yet. Click play on the source video in your browser once to wake it up.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button {
                    sourceTipDismissed = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.blue.opacity(0.08)))
        }
    }

    @ViewBuilder
    private func labeledSlider<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 16)
                    .foregroundColor(.secondary)
                content()
            }
        }
    }

    private func trailingValue(_ text: String) -> some View {
        Text(text)
            .font(.caption.monospacedDigit())
            .frame(width: 36, alignment: .trailing)
            .foregroundColor(.secondary)
    }

    private var volumeIcon: String {
        let v = broadcastManager.outputVolume
        if v < 0.01 { return "speaker.slash.fill" }
        if v < 0.34 { return "speaker.wave.1.fill" }
        if v < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    private var modeText: String {
        switch broadcastManager.mode {
        case .idle: return ""
        case .starting: return "Starting…"
        case .buffering(let p): return String(format: "Buffering %.0f%%", p * 100)
        case .playing: return "Broadcasting"
        case .stopping: return "Stopping…"
        }
    }

    private var stageTitle: String {
        switch wizard.stage {
        case .idle: return "Ready"
        case .fine: return "Video region"
        case .broadcasting: return "Broadcast Control"
        }
    }

    private var stageInstruction: String {
        switch wizard.stage {
        case .idle:
            return "Pick a window from the picker to begin."
        case .fine:
            return "Adjust the green rectangle to match your video, or click Autofit to let the app detect the largest plausible rectangle in the window. Drag the body to move; corners to resize."
        case .broadcasting:
            return "Watching delayed playback with synced subtitles. Click Play/Pause to control both source and broadcast."
        }
    }

    private var stageIcon: String {
        switch wizard.stage {
        case .idle: return "circle"
        case .fine: return "rectangle.dashed.and.paperclip"
        case .broadcasting: return "play.rectangle.fill"
        }
    }

    private var stageColor: Color {
        switch wizard.stage {
        case .idle: return .secondary
        case .fine: return .green
        case .broadcasting: return .blue
        }
    }
}

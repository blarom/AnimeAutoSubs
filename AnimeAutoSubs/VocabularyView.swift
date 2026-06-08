import SwiftUI
import Combine

/// Live vocabulary dashboard: every kanji-bearing token seen during the
/// broadcast, latest on top, with reading + jisho-fetched definition.
/// Includes a font-size slider and a save-to-file button.
struct VocabularyView: View {
    @ObservedObject var manager: VocabularyManager
    @AppStorage("vocabFontSize") private var fontSize: Double = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            fontSizeRow
            Divider()
            list
        }
        .padding(14)
        .frame(width: 360, height: 600)
    }

    private var header: some View {
        HStack {
            Text("Vocabulary")
                .font(.title3.bold())
            Text("\(manager.entries.count)")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.15)))
            Spacer()
            Button {
                manager.saveToFile()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.down")
                    Text("Save…")
                }
            }
            .disabled(manager.entries.isEmpty)
        }
    }

    private var fontSizeRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "textformat.size")
                .foregroundColor(.secondary)
            Slider(value: $fontSize, in: 11...26)
            Text("\(Int(fontSize))pt")
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
    }

    private var list: some View {
        ScrollView {
            if manager.entries.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "text.book.closed")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary)
                    Text("Words will appear here as they're displayed")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 360)
            } else {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(manager.entries) { entry in
                        entryRow(entry)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: VocabEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.surface)
                    .font(.system(size: fontSize, weight: .semibold))
                    .textSelection(.enabled)
                if let r = entry.reading, r != entry.surface {
                    Text(r)
                        .font(.system(size: fontSize * 0.75))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            }
            if let def = entry.definition {
                Text(def)
                    .font(.system(size: fontSize * 0.85))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.tail)
            } else {
                Text("…")
                    .font(.system(size: fontSize * 0.85))
                    .foregroundColor(Color.secondary.opacity(0.5))
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.06)))
    }
}

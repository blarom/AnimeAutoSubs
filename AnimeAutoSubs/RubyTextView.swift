import SwiftUI
import AppKit
import CoreText

/// An NSTextView-backed selectable text view that lays out tokens using Core
/// Text's `kCTRubyAnnotationAttribute`. Used purely as the *invisible* selection
/// layer underneath the visible `WrappingHStack` of ruby tokens — Core Text's
/// ruby spacing matches what the visible side ends up rendering, so the
/// selection highlight lines up with the visible kanji.
///
/// Performance notes (this view was previously responsible for video freezes):
/// - Fixed-size: no intrinsic-size driving, so SwiftUI's `.frame(height:)`
///   alone determines the bounds. Avoids layout-cycle tension.
/// - Signature short-circuit in `updateNSView`: SwiftUI may call updateNSView
///   on unrelated state ticks; rebuilding the NSAttributedString + relayout
///   each time saturates the main thread. We only rebuild when the rendered
///   content actually changes.
struct RubyTextView: NSViewRepresentable {
    let tokens: [FuriganaPair]
    let mainSize: CGFloat
    let mainColor: NSColor

    func makeNSView(context: Context) -> NSTextView {
        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.allowsUndo = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width, .height]
        context.coordinator.lastSignature = ""
        return tv
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        let sig = signature
        if sig == context.coordinator.lastSignature { return }
        context.coordinator.lastSignature = sig
        textView.textStorage?.setAttributedString(makeAttributedString())
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastSignature: String = ""
    }

    /// Cheap key capturing everything that affects rendering.
    private var signature: String {
        var s = "\(mainSize)|\(mainColor.hash)|"
        for t in tokens {
            s += t.surface + "/" + (t.reading ?? "") + "|"
        }
        return s
    }

    private func makeAttributedString() -> NSAttributedString {
        let result = NSMutableAttributedString()
        let mainFont = NSFont.systemFont(ofSize: mainSize, weight: .semibold)
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: mainFont,
            .foregroundColor: mainColor
        ]

        for token in tokens {
            var attrs = baseAttrs
            if let reading = token.reading, reading != token.surface {
                // Match the visible side's ruby/main ratio (rubyToken uses
                // rubySize = mainSize * 0.42), otherwise Core Text's larger
                // line height nudges the main glyph upward and the selection
                // highlight ends up at the visible furigana row.
                let rubyAttrs: [CFString: Any] = [
                    kCTRubyAnnotationSizeFactorAttributeName: 0.42
                ]
                let annotation = CTRubyAnnotationCreateWithAttributes(
                    .center,
                    .auto,
                    .before,
                    reading as CFString,
                    rubyAttrs as CFDictionary
                )
                attrs[NSAttributedString.Key(kCTRubyAnnotationAttributeName as String)] = annotation
            }
            result.append(NSAttributedString(string: token.surface, attributes: attrs))
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        return result
    }
}

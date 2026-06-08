import SwiftUI
import AppKit

struct AdjustableRectView: View {
    @Binding var rect: CGRect          // in window-local points
    let color: Color
    let dashed: Bool
    let backgroundImage: CGImage?

    @State private var dragStart: CGRect?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image = backgroundImage {
                    Image(decorative: image, scale: 1.0, orientation: .up)
                        .resizable()
                        .interpolation(.medium)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .allowsHitTesting(false)
                } else {
                    Color.black.opacity(0.001)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .allowsHitTesting(false)
                }

                // Bold colored border using strokeBorder
                Rectangle()
                    .strokeBorder(color, style: StrokeStyle(lineWidth: 4, dash: dashed ? [12, 6] : []))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false)

                // Move-handle (interior, leaves room for corners)
                Color.clear
                    .frame(width: max(0, rect.width - 36), height: max(0, rect.height - 36))
                    .contentShape(Rectangle())
                    .position(x: rect.midX, y: rect.midY)
                    .gesture(
                        DragGesture()
                            .onChanged { v in
                                if dragStart == nil { dragStart = rect }
                                guard let start = dragStart else { return }
                                let nx = max(0, min(geo.size.width - start.width, start.origin.x + v.translation.width))
                                let ny = max(0, min(geo.size.height - start.height, start.origin.y + v.translation.height))
                                rect = CGRect(x: nx, y: ny, width: start.width, height: start.height)
                            }
                            .onEnded { _ in dragStart = nil }
                    )

                ForEach(0..<4, id: \.self) { i in
                    cornerHandle(idx: i, in: geo.size)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    @ViewBuilder
    private func cornerHandle(idx: Int, in viewSize: CGSize) -> some View {
        let pos = cornerPos(idx: idx, rect: rect)
        Circle()
            .fill(color)
            .overlay(Circle().stroke(Color.white, lineWidth: 2))
            .frame(width: 18, height: 18)
            .position(pos)
            .gesture(
                DragGesture()
                    .onChanged { v in
                        if dragStart == nil { dragStart = rect }
                        guard let start = dragStart else { return }
                        rect = adjustCorner(idx: idx, original: start, dx: v.translation.width, dy: v.translation.height, bounds: viewSize)
                    }
                    .onEnded { _ in dragStart = nil }
            )
    }

    private func cornerPos(idx: Int, rect: CGRect) -> CGPoint {
        switch idx {
        case 0: return CGPoint(x: rect.minX, y: rect.minY)
        case 1: return CGPoint(x: rect.maxX, y: rect.minY)
        case 2: return CGPoint(x: rect.minX, y: rect.maxY)
        case 3: return CGPoint(x: rect.maxX, y: rect.maxY)
        default: return .zero
        }
    }

    private func adjustCorner(idx: Int, original: CGRect, dx: CGFloat, dy: CGFloat, bounds: CGSize) -> CGRect {
        var r = original
        let minSide: CGFloat = 80
        switch idx {
        case 0:
            let nx = max(0, min(r.maxX - minSide, r.origin.x + dx))
            let ny = max(0, min(r.maxY - minSide, r.origin.y + dy))
            r.size.width = r.maxX - nx
            r.size.height = r.maxY - ny
            r.origin.x = nx
            r.origin.y = ny
        case 1:
            let nx = max(r.origin.x + minSide, min(bounds.width, r.maxX + dx))
            let ny = max(0, min(r.maxY - minSide, r.origin.y + dy))
            r.size.width = nx - r.origin.x
            r.size.height = r.maxY - ny
            r.origin.y = ny
        case 2:
            let nx = max(0, min(r.maxX - minSide, r.origin.x + dx))
            let ny = max(r.origin.y + minSide, min(bounds.height, r.maxY + dy))
            r.size.width = r.maxX - nx
            r.size.height = ny - r.origin.y
            r.origin.x = nx
        case 3:
            let nx = max(r.origin.x + minSide, min(bounds.width, r.maxX + dx))
            let ny = max(r.origin.y + minSide, min(bounds.height, r.maxY + dy))
            r.size.width = nx - r.origin.x
            r.size.height = ny - r.origin.y
        default: break
        }
        return r
    }
}

import SwiftUI
import Combine

struct SnapshotRectContainer: View {
    @ObservedObject var wizard: BroadcastWizard
    let color: Color
    let dashed: Bool

    var body: some View {
        AdjustableRectView(
            rect: Binding(get: { wizard.fineRect }, set: { wizard.fineRect = $0 }),
            color: color,
            dashed: dashed,
            backgroundImage: wizard.sourceSnapshot
        )
    }
}

import SwiftUI
import AppKit

/// A non-modal dashboard listing every runtime dependency with a green/red
/// status indicator. Always shown at app launch. Install instructions are
/// inlined for missing items only.
///
/// `onRecheck` re-runs the presence checks. `onClose` hides the window —
/// it can be reopened from the menu bar.
struct DependencyDashboardView: View {
    @State var statuses: [DependencyStatus]
    let onRecheck: () -> [DependencyStatus]
    let onClose: () -> Void

    /// Observes the cached state of the Safari extension. The check is
    /// async (round-trips to SafariServices), so we trigger a refresh on
    /// any user-driven re-check and update statuses when the cache flips.
    @ObservedObject private var extChecker = SafariExtensionStatusChecker.shared

    private var allGreen: Bool { statuses.allSatisfy { $0.present } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(statuses) { status in
                        depRow(status)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 240, maxHeight: 760)

            HStack {
                Button("Re-check") {
                    extChecker.refresh()
                    statuses = onRecheck()
                }
                .keyboardShortcut("r", modifiers: .command)
                Spacer()
                Button("Close") { onClose() }
            }
        }
        .padding(20)
        .frame(width: 580)
        // App-active notification fires when the user returns from System
        // Settings after toggling Accessibility / Screen Recording, or
        // from Safari after enabling the extension. Refresh both the
        // async extension check and the synchronous statuses.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            extChecker.refresh()
            statuses = onRecheck()
        }
        // When the extension's async refresh completes (or its enabled
        // state changes between refreshes), re-run statuses so the
        // Safari-extension row turns green/red without requiring a click.
        .onChange(of: extChecker.isEnabled) { _, _ in
            statuses = onRecheck()
        }
        .onChange(of: extChecker.hasChecked) { _, _ in
            statuses = onRecheck()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: allGreen ? "checkmark.seal.fill" : "wrench.and.screwdriver.fill")
                .font(.system(size: 24))
                .foregroundColor(allGreen ? .green : .orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(allGreen ? "All set" : "Setup status")
                    .font(.title3.bold())
                Text(allGreen
                     ? "Everything AnimeAutoSubs needs is installed."
                     : "Install the missing tools below, then click Re-check.")
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func depRow(_ status: DependencyStatus) -> some View {
        let dep = status.dep
        let present = status.present

        HStack(alignment: .top, spacing: 12) {
            Image(systemName: present ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(present ? .green : .red)
                .font(.system(size: 18))

            VStack(alignment: .leading, spacing: 6) {
                Text(dep.name)
                    .font(.system(size: 14, weight: .semibold))
                Text(dep.purpose)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !present {
                    Text(dep.guiInstructions)
                        .font(.system(size: 12))
                        .padding(.top, 2)
                        .fixedSize(horizontal: false, vertical: true)

                    if let urlString = dep.downloadURL, let url = URL(string: urlString) {
                        let isSettings = url.scheme == "x-apple.systempreferences"
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: isSettings ? "gearshape" : "arrow.up.forward.app")
                                Text(isSettings ? "Open System Settings" : "Open download page")
                            }
                        }
                        .buttonStyle(.link)
                    }

                    if let cmd = dep.terminalCommand {
                        HStack(spacing: 6) {
                            Text(cmd)
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.07)))
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(cmd, forType: .string)
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }

            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(present ? Color.green.opacity(0.06) : Color.red.opacity(0.07))
        )
    }
}

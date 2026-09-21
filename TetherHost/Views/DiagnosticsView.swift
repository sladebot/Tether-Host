import SwiftUI
#if canImport(TetherHostCore)
import TetherHostCore
#endif

struct DiagnosticsView: View {
    @EnvironmentObject private var model: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sanitized activity")
                        .font(.title2.bold())
                    Text("Only allowlisted event names and timestamps appear here. Tokens, URLs, paths, and raw guest output are excluded.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Export…") {}
                    .disabled(true)
                    .help("Export is unavailable until a sanitized report writer is connected.")
            }
            .padding(24)
            Divider()

            if model.diagnostics.isEmpty {
                EmptyEvidenceView(
                    title: "No diagnostic events",
                    message: "Refresh after a host status provider is connected.",
                    symbol: "doc.text.magnifyingglass"
                )
            } else {
                List(model.diagnostics) { entry in
                    HStack {
                        Label(eventTitle(entry.event), systemImage: eventSymbol(entry.event))
                        Spacer()
                        Text(entry.date.formatted(date: .abbreviated, time: .standard))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 5)
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Diagnostics")
    }

    private func eventTitle(_ event: DiagnosticEvent) -> String {
        switch event {
        case .applicationOpened: "Application opened"
        case .inventoryRead: "VM inventory read"
        case .inventoryFailed: "VM inventory unavailable"
        case .vmDesignated: "VM identity designated"
        case .setupChecked: "Setup journal checked"
        case .setupBlocked: "Setup blocked"
        case .stateUnavailable: "Host state unavailable"
        }
    }

    private func eventSymbol(_ event: DiagnosticEvent) -> String {
        switch event {
        case .inventoryFailed, .setupBlocked, .stateUnavailable: "exclamationmark.triangle"
        default: "checkmark.circle"
        }
    }
}

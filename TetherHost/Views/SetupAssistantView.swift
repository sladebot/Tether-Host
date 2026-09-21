import SwiftUI
#if canImport(TetherHostCore)
import TetherHostCore
#endif

struct SetupAssistantView: View {
    @EnvironmentObject private var model: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            setupHeader
            Divider()
            List(model.setup.stages, id: \.stage) { record in
                SetupStageRow(record: record, isCurrent: record.stage == model.setup.nextStage)
            }
            .listStyle(.inset)
        }
        .navigationTitle("Setup Assistant")
    }

    private var setupHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Secure guest setup")
                        .font(.title2.bold())
                    Text("Progress is loaded from the setup journal. An interrupted step must be reconciled before it is retried.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(model.completedSetupCount) of \(model.setup.stages.count)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: model.setupProgress)
                .accessibilityLabel("Setup progress")
                .accessibilityValue("\(model.completedSetupCount) of \(model.setup.stages.count) stages complete")
        }
        .padding(24)
    }
}

private struct SetupStageRow: View {
    let record: SetupStageRecord
    let isCurrent: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: record.state.symbol)
                .font(.title3)
                .foregroundStyle(record.state.color)
                .frame(width: 26)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(record.stage.title)
                        .font(.body.weight(.semibold))
                    if isCurrent {
                        Text("NEXT")
                            .font(.caption2.bold())
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }
                }
                Text(record.stage.requirement)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Label(record.state.label, systemImage: "circle.fill")
                        .foregroundStyle(record.state.color)
                    if record.attempts > 0 {
                        Text("Attempts: \(record.attempts)")
                    }
                    Text(record.updatedAt.formatted(date: .abbreviated, time: .shortened))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Button(record.state == .waitingForUser ? "Continue" : "Retry") {}
                .disabled(true)
                .help("Stage execution is unavailable in the read-only observation build.")
                .accessibilityHint("Unavailable in this read-only build")
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }
}

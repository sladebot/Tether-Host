import SwiftUI
#if canImport(TetherHostCore)
import TetherHostCore
#endif

struct VMInventoryView: View {
    @EnvironmentObject private var model: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Virtual machines on this Mac")
                    .font(.headline)
                Spacer()
                if !model.isInsideGuest {
                    Button("Create New VM") { model.startNewNativeVMSetup() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityHint("Opens the built-in macOS VM creation guide")
                }
            }
            .padding()
            if model.inventory.isEmpty {
                EmptyEvidenceView(
                    title: "No VM found",
                    message: "Choose Create New VM to install macOS inside Tether Host.",
                    symbol: "macpro.gen3"
                )
            } else {
                List(model.inventory) { vm in
                    VMRecordRow(vm: vm, duplicate: model.isDuplicate(vm))
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Virtual Machines")
        .safeAreaInset(edge: .top) {
            if !model.duplicatedVMNames.isEmpty {
                Label(
                    "Duplicate VM names detected. Bind only by exact UUID after reconciling the registrations.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
                .accessibilityAddTraits(.isStaticText)
            }
        }
    }
}

private struct VMRecordRow: View {
    let vm: VirtualMachineRecord
    let duplicate: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "macpro.gen3")
                .font(.title2)
                .foregroundStyle(duplicate ? .orange : .secondary)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(vm.name)
                        .font(.headline)
                    if duplicate {
                        Label("Duplicate name", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }
                Text(vm.id.rawValue.uuidString)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Text(vm.state.rawValue.capitalized)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.quaternary, in: Capsule())
            Button("Designate") {}
                .disabled(true)
                .help(duplicate
                    ? "Resolve duplicate registrations before designating an exact VM UUID."
                    : "VM designation is unavailable in the read-only observation build.")
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(vm.name), UUID \(vm.id.rawValue.uuidString), state \(vm.state.rawValue)\(duplicate ? ", duplicate name" : "")")
    }
}

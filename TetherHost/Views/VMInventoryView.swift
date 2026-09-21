import SwiftUI
#if canImport(TetherHostCore)
import TetherHostCore
#endif

struct VMInventoryView: View {
    @EnvironmentObject private var model: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Virtual machines on this Mac")
                        .font(.headline)
                    Spacer()
                    if !model.isInsideGuest {
                        Button("Create New VM") { model.startNewNativeVMSetup() }
                            .buttonStyle(.borderedProminent)
                            .accessibilityHint("Creates a Tether Host VM, which does not appear in UTM")
                    }
                }
                Picker("Show VMs from", selection: Binding(
                    get: { model.providerSetup.provider },
                    set: { source in
                        model.selectProvider(source)
                        Task { await model.refresh() }
                    }
                )) {
                    Text("Tether Host").tag(VMProvider.builtIn)
                    Text("UTM").tag(VMProvider.utm)
                }
                .pickerStyle(.segmented)
                Text(model.providerSetup.provider == .builtIn
                     ? "Tether Host saves these Apple VMs locally. They do not appear in UTM."
                     : "These are VMs registered with UTM. VMs created by Tether Host appear under Tether Host instead.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding()
            if model.inventory.isEmpty {
                EmptyEvidenceView(
                    title: "No VM found",
                    message: model.providerSetup.provider == .builtIn
                        ? "Choose Create New VM to install macOS inside Tether Host."
                        : "No UTM VM is registered here. Switch to Tether Host to see VMs created in this app.",
                    symbol: "macpro.gen3"
                )
            } else {
                List(model.inventory) { vm in
                    VMRecordRow(vm: vm, duplicate: model.isDuplicate(vm),
                                canReveal: model.vmBundleURL(for: vm) != nil) {
                        model.revealVMInFinder(vm)
                    }
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
    let canReveal: Bool
    let reveal: () -> Void

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
            Button("Show in Finder", action: reveal)
                .disabled(!canReveal)
                .help(canReveal ? "Reveal the exact VM bundle in Finder" : "This registration's exact local bundle could not be found")
        }
        .padding(.vertical, 8)
    }
}

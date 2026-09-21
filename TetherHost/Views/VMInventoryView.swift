import SwiftUI
#if canImport(TetherHostCore)
import TetherHostCore
#endif

struct VMInventoryView: View {
    @EnvironmentObject private var model: AppViewModel
    @State private var pendingDeletion: VMDeletionRequest?
    @State private var confirmationCode = ""

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
                .disabled(model.isRemovingVM)
                Text(model.providerSetup.provider == .builtIn
                     ? "Tether Host saves these Apple VMs locally. They do not appear in UTM."
                     : "These are VMs registered with UTM. VMs created by Tether Host appear under Tether Host instead.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if model.isRemovingVM { ProgressView("Deleting VM files…") }
                if let message = model.vmRemovalMessage {
                    Text(message).font(.callout).textSelection(.enabled)
                }
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
                                canReveal: model.vmBundleURL(for: vm) != nil,
                                canDelete: model.canDeleteVM(vm),
                                reveal: { model.revealVMInFinder(vm) },
                                delete: {
                                    confirmationCode = ""
                                    pendingDeletion = VMDeletionRequest(vm: vm, provider: model.providerSetup.provider)
                                })
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
        .sheet(item: $pendingDeletion) { request in
            VStack(alignment: .leading, spacing: 16) {
                Text("Permanently delete this VM?").font(.title2.bold())
                Text(request.vm.name).font(.headline)
                Text(request.vm.id.description)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Text(request.provider == .builtIn
                     ? "Tether Host will permanently delete this VM bundle, including its macOS disk and data, to free disk space. It will not go to Trash."
                     : "Tether Host will ask UTM to delete this VM, then permanently remove its exact local bundle if UTM leaves it behind. This cannot be undone.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("Type the last 8 characters of the VM ID to confirm: \(request.confirmationCode)")
                    .font(.callout)
                TextField("Last 8 characters", text: $confirmationCode)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Cancel") { pendingDeletion = nil }
                    Button("Delete VM and Files", role: .destructive) {
                        pendingDeletion = nil
                        Task { await model.deleteVM(request.vm, from: request.provider) }
                    }
                    .disabled(confirmationCode.trimmingCharacters(in: .whitespacesAndNewlines)
                        .uppercased() != request.confirmationCode)
                }
            }
            .padding(24)
            .frame(width: 460)
        }
    }
}

private struct VMDeletionRequest: Identifiable {
    let vm: VirtualMachineRecord
    let provider: VMProvider

    var id: UUID { vm.id.rawValue }
    var confirmationCode: String { String(vm.id.description.suffix(8)) }
}

private struct VMRecordRow: View {
    let vm: VirtualMachineRecord
    let duplicate: Bool
    let canReveal: Bool
    let canDelete: Bool
    let reveal: () -> Void
    let delete: () -> Void

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
            Button("Delete…", role: .destructive, action: delete)
                .disabled(!canDelete)
                .help(canDelete ? "Permanently delete this stopped VM and its files" : "Stop the VM and ensure its exact local bundle is available")
        }
        .padding(.vertical, 8)
    }
}

import SwiftUI
#if canImport(TetherHostCore)
import TetherHostCore
#endif

struct VMInventoryView: View {
    @EnvironmentObject private var model: AppViewModel

    var body: some View {
        VMInventoryContent(manager: model.nativeVM)
    }
}

private struct VMInventoryContent: View {
    @EnvironmentObject private var model: AppViewModel
    @ObservedObject var manager: NativeVMManager
    @State private var pendingDeletion: VMDeletionRequest?
    @State private var pendingForceOff: VMForceOffRequest?
    @State private var confirmationCode = ""

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Virtual machines on this Mac")
                        .font(.headline)
                    Spacer()
                    if !model.isInsideGuest {
                        Button("Create VM…", systemImage: "plus") { model.startNewVMSetup() }
                            .buttonStyle(.borderedProminent)
                            .accessibilityHint("Opens VM creation for the selected provider")
                    }
                }
                Picker("Show VMs from", selection: Binding(
                    get: { model.providerSetup.provider },
                    set: { source in
                        model.selectProvider(source)
                        Task { await model.refresh() }
                    }
                )) {
                    Text("Apple Virtualization").tag(VMProvider.builtIn)
                    Text("UTM").tag(VMProvider.utm)
                }
                .pickerStyle(.segmented)
                .disabled(model.isRemovingVM)
                Text(model.providerSetup.provider == .builtIn
                     ? "Apple Virtualization VMs are saved by Tether Host and do not appear in UTM."
                     : "These VMs are registered with UTM. Apple Virtualization VMs appear in the other list.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if model.providerSetup.provider == .builtIn {
                    HStack(alignment: .top, spacing: 8) {
                        if manager.isBusy { ProgressView().controlSize(.small) }
                        Text(manager.status).font(.callout).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                if model.isRemovingVM { ProgressView("Deleting VM files…") }
                if let message = model.vmRemovalMessage {
                    Text(message).font(.callout).textSelection(.enabled)
                }
            }
            .padding()
            if model.candidateVMs.isEmpty {
                EmptyEvidenceView(
                    title: "No virtual machines",
                    message: model.providerSetup.provider == .builtIn
                        ? "Create a macOS or Ubuntu VM."
                        : "Create a UTM VM or choose Apple Virtualization to see VMs created here.",
                    symbol: "macpro.gen3"
                )
            } else {
                List(model.candidateVMs) { vm in
                    VMRecordRow(vm: vm, duplicate: model.isDuplicate(vm),
                                provider: model.providerSetup.provider,
                                isRunningHere: manager.runningVMID == vm.id,
                                isAnotherVMRunning: manager.isRunning && manager.runningVMID != vm.id,
                                isStartingHere: manager.startingVMID == vm.id,
                                isBusy: manager.isBusy || model.isRemovingVM || model.isRefreshing,
                                hasOtherHostCopy: manager.hasOtherHostCopy,
                                shutdownRequested: manager.shutdownRequested,
                                canReveal: model.vmBundleURL(for: vm) != nil,
                                canDelete: model.canDeleteVM(vm),
                                start: {
                                    model.selectVM(vm.id)
                                    Task { await manager.startOrShow(vm.id) }
                                },
                                shutDown: { manager.requestShutdown(for: vm.id) },
                                forceOff: { pendingForceOff = VMForceOffRequest(vm: vm) },
                                openUTM: { model.openUTM() },
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
                     ? "Tether Host will permanently delete this VM bundle, including its disk and data, to free disk space. It will not go to Trash."
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
        .alert("Force power off \(pendingForceOff?.vm.name ?? "VM")?",
               isPresented: Binding(get: { pendingForceOff != nil },
                                    set: { if !$0 { pendingForceOff = nil } })) {
            Button("Cancel", role: .cancel) { pendingForceOff = nil }
            Button("Force Power Off", role: .destructive) {
                guard let request = pendingForceOff else { return }
                pendingForceOff = nil
                Task { await manager.forcePowerOff(for: request.vm.id) }
            }
        } message: {
            Text("\(pendingForceOff?.vm.name ?? "This VM") (\(pendingForceOff?.vm.id.description ?? "")) will stop immediately. Unsaved work inside it will be lost.")
        }
    }
}

private struct VMDeletionRequest: Identifiable {
    let vm: VirtualMachineRecord
    let provider: VMProvider

    var id: UUID { vm.id.rawValue }
    var confirmationCode: String { String(vm.id.description.suffix(8)) }
}

private struct VMForceOffRequest {
    let vm: VirtualMachineRecord
}

private struct VMRecordRow: View {
    let vm: VirtualMachineRecord
    let duplicate: Bool
    let provider: VMProvider
    let isRunningHere: Bool
    let isAnotherVMRunning: Bool
    let isStartingHere: Bool
    let isBusy: Bool
    let hasOtherHostCopy: Bool
    let shutdownRequested: Bool
    let canReveal: Bool
    let canDelete: Bool
    let start: () -> Void
    let shutDown: () -> Void
    let forceOff: () -> Void
    let openUTM: () -> Void
    let reveal: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "macpro.gen3")
                    .font(.title2)
                    .foregroundStyle(duplicate ? .orange : .secondary)
                    .frame(width: 26)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(vm.name).font(.headline)
                    if vm.state == .unavailable {
                        Text("Storage unavailable. Reconnect the drive and refresh.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Text(vm.id.rawValue.uuidString)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 4)
                Text(isStartingHere ? "Starting" : isRunningHere ? (shutdownRequested ? "Shutting down" : "Running") : vm.state.rawValue.capitalized)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.quaternary, in: Capsule())
            }
            if duplicate {
                Label("Duplicate VM name; use the UUID above.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                if provider == .builtIn {
                    if isRunningHere {
                        Button("Show VM", action: start)
                            .disabled(isBusy)
                        Button(shutdownRequested ? "Shutting Down…" : "Shut Down", action: shutDown)
                            .disabled(isBusy || shutdownRequested)
                    } else {
                        Button(isStartingHere ? "Starting…" : "Start VM", action: start)
                            .disabled(isBusy || isAnotherVMRunning || hasOtherHostCopy || vm.state != .stopped)
                            .help(powerHelp)
                    }
                } else {
                    Button("Open UTM", action: openUTM)
                        .help("Manage this VM's power in UTM")
                }
                Spacer()
                Menu {
                    Button("Show in Finder", action: reveal).disabled(!canReveal)
                    if provider == .builtIn && isRunningHere {
                        Divider()
                        Button("Force Off…", role: .destructive, action: forceOff)
                            .disabled(isBusy)
                    }
                    Divider()
                    Button("Delete…", role: .destructive, action: delete).disabled(!canDelete)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .fixedSize()
                .help("More actions for \(vm.name)")
            }
        }
        .padding(.vertical, 8)
    }

    private var powerHelp: String {
        if hasOtherHostCopy { return "Another Tether Host copy is managing VMs" }
        if isAnotherVMRunning { return "Shut down the running VM before starting this one" }
        if vm.state == .unavailable { return "Reconnect this VM's storage and refresh" }
        if vm.state != .stopped { return "Wait until this VM is off and refresh its status" }
        if isBusy { return "Wait for the current VM operation to finish" }
        return "Start this exact VM"
    }
}

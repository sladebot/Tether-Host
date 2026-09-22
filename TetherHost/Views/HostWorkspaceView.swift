import SwiftUI
import TetherHostCore

/// The host keeps its VM display visible while setup moves through guest dependencies.
struct HostWorkspaceView: View {
    @EnvironmentObject private var model: AppViewModel
    @ObservedObject var manager: NativeVMManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var showToken = false
    @State private var showsCreateVM = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                sidebar
                Divider()
                sectionContent
            }
            .frame(width: 510)
            Divider()
            VMMonitorView(manager: manager)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1040, minHeight: 700)
        .task {
            model.checkProviderInstallation()
            while !Task.isCancelled {
                if scenePhase == .active { await model.refresh() }
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.checkProviderInstallation()
                Task { await model.refresh() }
            }
        }
        .onChange(of: model.setupDependencies) { _, gates in
            model.syncHostSleepAssertion()
            if let step = model.workspaceSection.dependency, !gates.isUnlocked(step) {
                model.workspaceSection = .vm
            }
        }
        .onChange(of: manager.isRunning) { _, _ in
            model.syncHostSleepAssertion()
        }
        .onChange(of: model.workspaceSection) { _, section in
            if section != .hermes { showToken = false }
        }
        .sheet(isPresented: $showsCreateVM) {
            createVMSheet
                .interactiveDismissDisabled(manager.isBusy)
        }
        .tint(.accentColor)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Tether Host")
                        .font(.title2.bold())
                    Text("Set up the VM, then its guest services")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await model.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(model.isRefreshing)
                .help("Refresh VM status")
            }

            VStack(spacing: 3) {
                dependencyButton(.vm, number: 1, title: "Virtual machine", symbol: "desktopcomputer")
                dependencyButton(.tailscale, number: 2, title: "Tailscale", symbol: "network")
                dependencyButton(.hermes, number: 3, title: "Hermes", symbol: "shippingbox")
                dependencyButton(.phone, number: 4, title: "Connect iPhone", symbol: "iphone")
            }

            HStack(spacing: 16) {
                utilityButton(.library, title: "VMs", symbol: "square.stack")
                utilityButton(.overview, title: "Health", symbol: "shield.lefthalf.filled")
                utilityButton(.diagnostics, title: "Diagnostics", symbol: "stethoscope")
            }
            .font(.caption)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func dependencyButton(
        _ dependency: HostSetupDependency, number: Int, title: String, symbol: String
    ) -> some View {
        let enabled = model.setupDependencies.isUnlocked(dependency)
        let completed = model.setupDependencies.isCompleted(dependency)
        let section = HostWorkspaceSection(dependency)
        return Button {
            model.workspaceSection = section
        } label: {
            HStack(spacing: 12) {
                Image(systemName: completed ? "checkmark.circle.fill" : "\(number).circle")
                    .font(.title3)
                    .foregroundStyle(completed ? .green : (enabled ? Color.accentColor : .secondary))
                    .frame(width: 24)
                Text(title).fontWeight(model.workspaceSection == section ? .semibold : .regular)
                Spacer()
                if !enabled { Image(systemName: "lock.fill").font(.caption2) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(model.workspaceSection == section ? Color.accentColor.opacity(0.14) : .clear,
                        in: RoundedRectangle(cornerRadius: 9))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(enabled ? title : dependency.lockReason)
        .accessibilityLabel("Step \(number): \(title), \(completed ? "complete" : enabled ? "available" : "locked")")
    }

    private func utilityButton(_ section: HostWorkspaceSection, title: String, symbol: String) -> some View {
        Button {
            model.workspaceSection = section
        } label: {
            Label(title, systemImage: symbol)
                .foregroundStyle(model.workspaceSection == section ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch model.workspaceSection {
        case .vm:
            scrollContent { vmSection }
        case .tailscale:
            scrollContent { tailscaleSection }
        case .hermes:
            scrollContent { hermesSection }
        case .phone:
            scrollContent { phoneSection }
        case .library:
            VMInventoryView()
        case .overview:
            HostDashboardView()
        case .diagnostics:
            DiagnosticsView()
        }
    }

    private func scrollContent<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
        }
    }

    private var vmSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionHeader("Virtual machine", detail: "Choose a Mac or create a new one.")
            Picker("Run with", selection: Binding(
                get: { model.providerSetup.provider },
                set: { provider in
                    model.selectProvider(provider)
                    Task { await model.refresh() }
                }
            )) {
                Text("UTM").tag(VMProvider.utm)
                Text("Built-in Apple").tag(VMProvider.builtIn)
            }
            .pickerStyle(.segmented)
            .disabled(model.isRefreshing || model.isRemovingVM || manager.isBusy || manager.isRunning)
            Text(model.providerSetup.provider == .utm
                 ? "UTM opens and displays your Mac."
                 : "Tether Host opens and displays your Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
            providerAvailability

            HStack {
                Text("Your virtual machines").font(.headline)
                Spacer()
                Button { showsCreateVM = true } label: {
                    Label("Create new…", systemImage: "plus")
                }
                .disabled(manager.isBusy || manager.isRunning || manager.hasOtherHostCopy)
            }
            if model.candidateVMs.isEmpty {
                Text(model.providerSetup.provider == .builtIn
                     ? "No built-in VMs yet. Create one from a macOS image."
                     : "No UTM VMs found. Create one or refresh the list.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.candidateVMs) { vm in
                    Button {
                        model.selectVM(vm.id)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: model.designatedVM?.id == vm.id
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(model.designatedVM?.id == vm.id ? Color.accentColor : .secondary)
                            Text(vm.name).fontWeight(.medium)
                                .lineLimit(1)
                            if model.isDuplicate(vm) {
                                Text(String(vm.id.description.suffix(8)))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(vm.state == .started ? "Running" : "Off")
                                .font(.caption)
                                .foregroundStyle(vm.state == .started ? .green : .secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(model.designatedVM?.id == vm.id ? Color.accentColor.opacity(0.10) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .disabled(manager.isBusy)
                    .help(vm.id.description)
                }
            }

            if let vm = model.designatedVM {
                Divider()
                Label(model.providerSetup.provider == .builtIn && manager.isRunning
                      && manager.runningVMID != vm.id
                      ? "Another VM is running. Shut it down before starting this one."
                      : model.setupDependencies.vmReady
                        ? "VM desktop is ready for guest setup."
                        : model.designatedVMIsRunning
                          ? "Finish macOS setup in the display, then confirm the desktop."
                          : model.providerSetup.provider == .utm
                            ? "Open UTM to start this VM."
                            : "Click Start VM to continue.",
                      systemImage: model.setupDependencies.vmReady ? "checkmark.circle.fill" : "hourglass")
                    .foregroundStyle(model.setupDependencies.vmReady ? .green : .orange)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    if model.providerSetup.provider == .builtIn {
                        if manager.isRunning && manager.runningVMID == vm.id {
                            Button("Shut Down VM") { manager.requestShutdown() }
                                .buttonStyle(.borderedProminent)
                                .disabled(manager.isBusy || manager.shutdownRequested)
                        } else {
                            Button("Start VM") { Task { await manager.startOrShow(vm.id) } }
                                .buttonStyle(.borderedProminent)
                                .disabled(manager.isRunning || manager.isBusy || manager.hasOtherHostCopy)
                        }
                    }
                    if model.vmBundleURL(for: vm) != nil {
                        Button("Show in Finder") { model.revealVMInFinder(vm) }
                    }
                    if model.providerSetup.provider == .builtIn, !manager.isRunning {
                        Button("Move to UTM") {
                            Task {
                                if await manager.moveToUTM(vm.id) {
                                    model.selectProvider(.utm)
                                    await model.refresh()
                                    model.selectVM(vm.id)
                                }
                            }
                        }
                        .disabled(manager.isBusy || manager.hasOtherHostCopy)
                        .help("Register this Apple VM with UTM after confirming its files")
                    }
                }
            }
            Divider()
            HStack {
                if model.providerSetup.provider == .utm {
                    Button("Open UTM") { model.openUTM() }
                        .disabled(!model.providerSetup.availability.canContinue)
                }
                Button("Refresh") { Task { await model.refresh() } }
                    .disabled(model.isRefreshing)
                Spacer()
                Button("Manage VMs") { model.workspaceSection = .library }
            }
            .buttonStyle(.borderless)
            if model.providerSetup.provider == .utm {
                Link("UTM setup guide", destination: UTMInstallation.macOSGuideURL)
                    .font(.caption)
            }
            if model.isRefreshing { ProgressView("Refreshing VMs…") }
        }
    }

    @ViewBuilder
    private var providerAvailability: some View {
        switch model.providerSetup.availability {
        case .unchecked:
            Label("Checking VM support…", systemImage: "arrow.clockwise")
                .font(.callout).foregroundStyle(.secondary)
        case .ready:
            EmptyView()
        case .blocked(let reason):
            VStack(alignment: .leading, spacing: 6) {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                if model.providerSetup.provider == .utm {
                    Link("Download UTM", destination: UTMInstallation.downloadURL)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var createVMSheet: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Create a macOS VM").font(.title2.bold())
                Text(model.providerSetup.provider == .utm
                     ? "Tether Host installs macOS, then adds the new VM to UTM."
                     : "Tether Host installs macOS and opens the new VM here.")
                .foregroundStyle(.secondary)
            }

            if manager.isBusy {
                VStack(alignment: .leading, spacing: 16) {
                    if let download = manager.downloadProgress {
                        if let fraction = download.fraction {
                            ProgressView(value: fraction)
                            Text("\(Int(fraction * 100))% · \(transferSize(download.receivedBytes)) of \(transferSize(download.totalBytes ?? 0))")
                                .font(.callout.monospacedDigit())
                        } else {
                            ProgressView()
                            Text("\(transferSize(download.receivedBytes)) downloaded")
                                .font(.callout.monospacedDigit())
                        }
                        if let speed = download.bytesPerSecond {
                            Text("\(transferSize(Int64(speed)))/s")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if let remaining = download.secondsRemaining {
                            Text("About \(remainingTime(remaining)) remaining")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    } else if let progress = manager.installationProgress {
                        ProgressView(value: progress)
                    } else {
                        ProgressView().controlSize(.large)
                    }
                    Text(manager.status)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Keep Tether Host open until installation finishes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 160, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("macOS installation image").font(.headline)
                    Text("A new VM needs an Apple IPSW. Choose one you have or download it from Apple.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Choose IPSW…") { manager.chooseIPSW() }
                    if manager.hasCachedHostImage {
                        Label("A macOS 26.2 image already exists on this Mac. Reuse it for another VM?",
                              systemImage: "checkmark.circle.fill")
                            .font(.callout).foregroundStyle(.green)
                        HStack {
                            Button("Reuse image") { Task { await manager.useCachedHostImage() } }
                                .buttonStyle(.borderedProminent)
                            Button("Show in Finder") { manager.revealCachedHostImageInFinder() }
                            if NativeVMManager.canDownloadHostImage {
                                Button("Download again") { Task { await manager.downloadHostImage() } }
                            }
                        }
                    } else if NativeVMManager.canDownloadHostImage {
                        Button("Download macOS 26.2") { Task { await manager.downloadHostImage() } }
                    }
                    Text(manager.imageDescription).font(.callout).foregroundStyle(.secondary)
                    if manager.imageURL != nil {
                        Button("Show selected image in Finder") { manager.revealSelectedImageInFinder() }
                            .font(.caption)
                    }
                    Link("Find a macOS IPSW", destination: UTMInstallation.macOSImageURL)
                        .font(.caption)
                    if manager.status != "No VM installation has started." {
                        Text(manager.status).font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if manager.hasOtherHostCopy {
                        Label("Quit the other Tether Host copy before creating a VM.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 12)
                HStack {
                    Button("Cancel") { showsCreateVM = false }
                    Spacer()
                    Button(model.providerSetup.provider == .utm ? "Create in UTM" : "Create built-in VM") {
                        Task {
                            if let id = await manager.install(for: model.providerSetup.provider) {
                                await model.refresh()
                                model.selectVM(id)
                                showsCreateVM = false
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(manager.imageURL == nil || manager.isRunning
                        || !model.providerSetup.availability.canContinue || manager.hasOtherHostCopy)
                }
            }
        }
        .padding(24)
        .frame(width: 520)
        .frame(minHeight: 340)
    }

    private func transferSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func remainingTime(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours) hr \(minutes) min" }
        if minutes > 0 { return "\(minutes) min" }
        return "\(total) sec"
    }

    private var tailscaleSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Tailscale inside the VM", detail: "The physical Mac’s Tailscale installation does not count.")
            Text("Once the macOS desktop is ready, open Tether Guest Installer.app from the setup disk in the VM. Its six-step guide checks Internet, reuses or installs Tailscale, installs Hermes and computer use, then verifies the connection.")
                .foregroundStyle(.secondary)
            if model.providerSetup.provider == .builtIn {
                Label("Tether Guest Setup disk is attached when the VM boots.", systemImage: "opticaldisc")
            } else if model.selectedUTMVMHasGuestSetupDisk {
                Label("The read-only guest installer is included with this UTM VM. Open it in the VM’s Finder after logging in.",
                      systemImage: "opticaldisc")
            } else {
                Text("This existing UTM VM needs the guest setup disk attached once. Create it here, then attach it in UTM as a removable drive.")
                    .foregroundStyle(.secondary)
                Button(model.isExportingGuestSetupDisk ? "Creating disk…" : "Create Guest Setup Disk…") {
                    model.exportGuestSetupDisk()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isExportingGuestSetupDisk || !model.setupDependencies.vmReady)
                if model.guestSetupDiskURL != nil {
                    Button("Show setup disk in Finder") { model.revealGuestSetupDisk() }
                }
                Text(model.guestSetupDiskStatus).font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            if model.setupDependencies.tailscaleReady {
                Label("You confirmed Tailscale sign-in for this VM.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("Tailscale needs attention") { model.clearTailscaleSetup() }
            } else {
                Button("I completed Tailscale sign-in in this VM") { model.confirmTailscaleSetup() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.setupDependencies.vmReady)
                Text("Hermes can be installed and configured independently. Confirm Tailscale here before verifying the final private connection.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var hermesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Hermes inside the VM", detail: "Install and configure Hermes once the VM has Internet.")
            Text("In the VM, open Tether Guest Installer.app and choose Install Hermes, then Set up Hermes. The guide keeps existing data, prompts for model sign-in and permissions, and verifies a model response. Tether Host itself is not installed in the VM.")
                .foregroundStyle(.secondary)
            Text("When the guest prints its connection details, enter them below or import its private connection.json file. Verification happens from this Mac before the iPhone step unlocks.")
                .foregroundStyle(.secondary)
            Button("Import Guest Connection…") { model.importConnectionFile() }
                .disabled(model.isVerifyingConnection)
            TextField("Guest URL — https://your-vm.your-tailnet.ts.net", text: $model.connectionURL)
                .textFieldStyle(.roundedBorder)
                .disabled(model.isVerifyingConnection)
            HStack {
                Group {
                    if showToken {
                        TextField("API token", text: $model.connectionToken)
                    } else {
                        SecureField("API token", text: $model.connectionToken)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .privacySensitive()
                .disabled(model.isVerifyingConnection)
                Button(showToken ? "Hide" : "Reveal") { showToken.toggle() }
            }
            Button(model.isVerifyingConnection ? "Verifying…" : "Verify Hermes Connection") {
                Task { await model.verifyConnection() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isVerifyingConnection || model.connectionURL.isEmpty || model.connectionToken.isEmpty
                || !model.setupDependencies.tailscaleReady)
            Text(model.connectionMessage).font(.callout).fixedSize(horizontal: false, vertical: true)
            if model.setupDependencies.hermesReady {
                Label("Backend verified for the selected VM.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }

    private var phoneSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Connect Tether on iPhone", detail: "Keep this VM running while your phone connects.")
            Label("Hermes API access was verified from this Mac.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("On your iPhone, join the same Tailscale network. In Tether, add a Hermes API Server connection, enter the guest URL and token, then tap Test Connection.")
                .foregroundStyle(.secondary)
            Text(model.connectionURL).font(.callout.monospaced()).textSelection(.enabled)
            HStack {
                Button("Copy URL") { model.copyConnectionURL() }
                Button("Copy Token") { model.copyConnectionToken() }
            }
            Text("The token clipboard clears after 45 seconds. After a VM reboot, unlock macOS and log in so the guest gateway and desktop permissions can resume.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func sectionHeader(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title2.bold())
            Text(detail).font(.callout).foregroundStyle(.secondary)
        }
    }
}

private struct VMMonitorView: View {
    @EnvironmentObject private var model: AppViewModel
    @ObservedObject var manager: NativeVMManager
    @State private var showingForcePowerOff = false

    private var isOn: Bool {
        model.providerSetup.provider == .builtIn ? manager.isRunning : model.designatedVMIsRunning
    }

    private var displayedVMName: String {
        if model.providerSetup.provider == .builtIn, let runningID = manager.runningVMID {
            return model.candidateVMs.first(where: { $0.id == runningID })?.name
                ?? "Tether Host VM · \(runningID.description.prefix(8))"
        }
        return model.designatedVM?.name ?? "No VM selected"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Virtual machine").font(.headline)
                    Text(displayedVMName)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Label(isOn ? "On" : "Off", systemImage: "power")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(isOn ? .green : .secondary)
            }
            .padding(16)

            ZStack {
                Color.black
                if model.providerSetup.provider == .builtIn,
                   manager.isRunning, let vm = manager.virtualMachine {
                    NativeVMDisplay(virtualMachine: vm)
                        .aspectRatio(1.6, contentMode: .fit)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: model.providerSetup.provider == .utm
                              ? "macpro.gen3" : "display")
                            .font(.system(size: 54, weight: .ultraLight))
                        Text(model.providerSetup.provider == .utm
                             ? "UTM displays this VM in its own window"
                             : "VM is off")
                            .font(.title3.weight(.medium))
                        Text(model.providerSetup.provider == .utm
                             ? "Open UTM to see its live desktop."
                             : "Select a VM on the left, then start it here.")
                            .font(.callout)
                    }
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .padding()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 10) {
                if model.providerSetup.provider == .builtIn {
                    Text(manager.status).font(.callout).foregroundStyle(.secondary)
                        .lineLimit(3).textSelection(.enabled)
                    HStack {
                        Button(manager.isRunning ? "VM is running" : "Start VM") {
                            guard let vm = model.designatedVM else { return }
                            Task { await manager.startOrShow(vm.id) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(manager.isRunning || manager.isBusy || manager.hasOtherHostCopy
                            || model.designatedVM == nil)
                        Button("Shut Down VM") { manager.requestShutdown() }
                            .buttonStyle(.bordered)
                            .disabled(!manager.isRunning || manager.isBusy)
                        if manager.shutdownRequested && manager.isRunning {
                            Button("Force Power Off", role: .destructive) {
                                showingForcePowerOff = true
                            }
                            .disabled(manager.isBusy)
                        }
                        Spacer()
                        if manager.isRunning, let vm = model.designatedVM,
                           manager.runningVMID == vm.id,
                           !manager.isDesktopReady(for: vm.id) {
                            Button("Desktop is ready") { manager.confirmDesktopReady() }
                        }
                    }
                } else {
                    Text(model.designatedVMIsRunning
                         ? "UTM reports this VM as running. Confirm the macOS desktop in UTM."
                         : "UTM reports this VM as off. Start it in UTM, then refresh.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Open UTM") { model.openUTM() }
                            .buttonStyle(.borderedProminent)
                        Button("Refresh status") { Task { await model.refresh() } }
                            .disabled(model.isRefreshing)
                        Spacer()
                        if model.designatedVMIsRunning, !model.setupDependencies.desktopConfirmed {
                            Button("Desktop is ready") { model.confirmUTMDesktopReady() }
                        }
                    }
                }
                if model.setupDependencies.vmReady {
                    Label("Desktop ready for guest setup", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                }
                if model.preventsHostSleep {
                    Label("Keeping this Mac awake while the VM runs", systemImage: "moon.zzz.slash")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog("Power off this VM immediately?", isPresented: $showingForcePowerOff) {
            Button("Force Power Off", role: .destructive) {
                Task { await manager.forcePowerOff() }
            }
        } message: {
            Text("Unsaved work inside macOS will be lost. Use this only when Shut Down does not finish.")
        }
    }
}

private extension HostWorkspaceSection {
    init(_ dependency: HostSetupDependency) {
        switch dependency {
        case .vm: self = .vm
        case .tailscale: self = .tailscale
        case .hermes: self = .hermes
        case .phone: self = .phone
        }
    }

    var dependency: HostSetupDependency? {
        switch self {
        case .vm: .vm
        case .tailscale: .tailscale
        case .hermes: .hermes
        case .phone: .phone
        case .library, .overview, .diagnostics: nil
        }
    }
}

private extension HostSetupDependency {
    var lockReason: String {
        switch self {
        case .vm: ""
        case .tailscale: "Select and boot a VM, then confirm its macOS desktop."
        case .hermes: "Select and boot a VM, then confirm its macOS desktop."
        case .phone: "Verify the Hermes connection before connecting your iPhone."
        }
    }
}

private extension HostSetupDependencies {
    func isCompleted(_ dependency: HostSetupDependency) -> Bool {
        switch dependency {
        case .vm: vmReady
        case .tailscale: tailscaleReady
        case .hermes: hermesReady
        case .phone: false
        }
    }
}

import SwiftUI
import TetherHostCore

/// A focused setup workspace with the VM desktop available when interaction is needed.
struct HostWorkspaceView: View {
    @EnvironmentObject private var model: AppViewModel
    @ObservedObject var manager: NativeVMManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var showToken = false
    @State private var showsVMMonitor = true
    @State private var showsPhoneInstructions = false
    @State private var isVMFullScreen = false
    @State private var fullScreenWindow: NSWindow?

    private var canShowVMMonitor: Bool {
        model.providerSetup.provider == .builtIn && manager.isRunning
    }

    private var showsMonitor: Bool {
        canShowVMMonitor && showsVMMonitor
    }

    private var managerHasError: Bool {
        let status = manager.status.localizedLowercase
        return status.contains("could not") || status.contains("failed")
            || status.contains("did not accept") || status.contains("stopped:")
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                sidebar
                Divider()
                sectionContent
            }
            .frame(minWidth: isVMFullScreen ? 0 : 500, maxWidth: isVMFullScreen ? 0 : .infinity)
            .clipped()
            .allowsHitTesting(!isVMFullScreen)
            .accessibilityHidden(isVMFullScreen)
            if showsMonitor || isVMFullScreen {
                Divider()
                VMMonitorView(manager: manager, isFullScreen: isVMFullScreen) {
                    guard let window = NSApp.keyWindow else { return }
                    fullScreenWindow = window
                    isVMFullScreen = !window.styleMask.contains(.fullScreen)
                    window.toggleFullScreen(nil)
                }
                .frame(minWidth: isVMFullScreen ? 600 : 430, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: showsMonitor ? 960 : 680, minHeight: 620)
        .task {
            model.checkProviderInstallation()
            while !Task.isCancelled {
                if scenePhase == .active {
                    await model.refresh()
                    await model.refreshVerifiedGuestConnection()
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.checkProviderInstallation()
                Task {
                    await model.refresh()
                    await model.refreshVerifiedGuestConnection()
                }
            }
        }
        .onChange(of: model.setupDependencies) { _, _ in
            model.syncHostSleepAssertion()
        }
        .onChange(of: manager.isRunning) { _, running in
            model.syncHostSleepAssertion()
            if !running { model.invalidateLiveGuestReadiness() }
        }
        .onChange(of: model.workspaceSection) { _, section in
            if section != .hermes { showToken = false }
            if section == .phone || section == .overview || section == .library || section == .diagnostics {
                showsVMMonitor = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { notification in
            if let window = notification.object as? NSWindow, window === fullScreenWindow {
                isVMFullScreen = false
                fullScreenWindow = nil
            }
        }
        .sheet(isPresented: $model.showsCreateVM) {
            createVMSheet
                .interactiveDismissDisabled(manager.isBusy)
        }
        .tint(.accentColor)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Tether Host")
                        .font(.title2.bold())
                    Text("Your private assistant")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if canShowVMMonitor {
                    Button(showsVMMonitor ? "Hide VM" : "Show VM") { showsVMMonitor.toggle() }
                        .buttonStyle(.borderless)
                }
            }

            HStack(spacing: 3) {
                dependencyButton(.vm, number: 1, title: "Prepare Mac")
                dependencyButton(.tailscale, number: 2, title: "Set up VM")
                dependencyButton(.hermes, number: 3, title: "Verify")
                dependencyButton(.phone, number: 4, title: "iPhone")
            }

            HStack(spacing: 12) {
                utilityButton(.library, title: "VMs", symbol: "square.stack")
                Menu("Help") {
                    Button("Health") { model.workspaceSection = .overview }
                    Button("Diagnostics") { model.workspaceSection = .diagnostics }
                    Button("Refresh status") { Task { await model.refresh() } }
                }
                .font(.caption)
            }
            .font(.caption)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func dependencyButton(
        _ dependency: HostSetupDependency, number: Int, title: String
    ) -> some View {
        let completed = dependency == .phone
            ? model.isPhoneSetupComplete : model.setupDependencies.isCompleted(dependency)
        let section = HostWorkspaceSection(dependency)
        return Button {
            model.workspaceSection = section
        } label: {
            HStack(spacing: 5) {
                Image(systemName: completed ? "checkmark.circle.fill" : "\(number).circle")
                    .foregroundStyle(completed ? Color.accentColor : .secondary)
                Text(title).lineLimit(1)
            }
            .font(.caption.weight(model.workspaceSection == section ? .semibold : .regular))
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 7)
            .padding(.vertical, 8)
            .background(model.workspaceSection == section ? Color.accentColor.opacity(0.12) : .clear,
                        in: RoundedRectangle(cornerRadius: 7))
            .overlay(alignment: .bottom) {
                if model.workspaceSection == section {
                    RoundedRectangle(cornerRadius: 2).fill(Color.accentColor).frame(height: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Step \(number): \(title), \(completed ? "complete" : "needs attention")")
        .accessibilityAddTraits(model.workspaceSection == section ? .isSelected : [])
    }

    private func utilityButton(_ section: HostWorkspaceSection, title: String, symbol: String) -> some View {
        Button {
            model.workspaceSection = section
        } label: {
            Label(title, systemImage: symbol)
                .foregroundStyle(model.workspaceSection == section ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(model.workspaceSection == section ? .isSelected : [])
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
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader(model.designatedVM == nil ? "Set up your private assistant" : "Prepare your Mac",
                          detail: model.designatedVM == nil
                            ? "Your assistant runs in a private macOS virtual machine on this Mac."
                            : "Get the macOS desktop ready, then continue setup inside the VM.")

            if let vm = model.designatedVM {
                Label(vm.name, systemImage: "desktopcomputer")
                    .font(.headline)
                if model.setupDependencies.vmReady {
                    Label("macOS desktop ready", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                    Button("Continue") { model.workspaceSection = .tailscale }
                        .buttonStyle(.borderedProminent)
                } else if model.designatedVMIsRunning {
                    Text("Finish the macOS welcome screens in the VM. When you can see the desktop, confirm it here.")
                        .foregroundStyle(.secondary)
                    if model.providerSetup.provider == .builtIn {
                        Button("Desktop is ready") { manager.confirmDesktopReady() }
                            .buttonStyle(.borderedProminent)
                            .disabled(manager.isBusy)
                    } else {
                        Button("Desktop is ready") { model.confirmUTMDesktopReady() }
                            .buttonStyle(.borderedProminent)
                    }
                    if canShowVMMonitor && !showsVMMonitor {
                        Button("Show VM desktop") { showsVMMonitor = true }
                    }
                } else if model.providerSetup.provider == .utm {
                    Text("This VM is off. Start it in UTM, then refresh its status here.")
                        .foregroundStyle(.secondary)
                    Button("Open UTM") { model.openUTM() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.providerSetup.availability.canContinue)
                } else {
                    Text(manager.hasOtherHostCopy
                         ? "Another Tether Host window is managing your VM. Finish there and quit that copy before starting it here."
                         : manager.isRunning && manager.runningVMID != vm.id
                         ? "Another VM is running. Shut it down before starting this one."
                         : "This VM is off. Start it to continue setup.")
                        .foregroundStyle(.secondary)
                    Button("Start VM") { Task { await manager.startOrShow(vm.id) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(manager.isRunning || manager.isBusy || manager.hasOtherHostCopy)
                }
            } else {
                Text("You'll need a compatible macOS installation image and enough free space for the VM. Setup can take a while; keep this Mac awake until it finishes.")
                    .foregroundStyle(.secondary)
                if manager.hasOtherHostCopy {
                    Text("Another copy of Tether Host is open. Quit that copy before creating a VM here.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Button("Get started") { model.showsCreateVM = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(manager.isBusy || manager.isRunning || manager.hasOtherHostCopy)
            }

            providerAvailability
            if manager.isBusy {
                ProgressView(manager.status)
            } else if manager.status != "No VM installation has started.", !manager.status.isEmpty,
                      (managerHasError || !model.setupDependencies.vmReady) {
                Text(manager.status).font(.callout).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            DisclosureGroup("VM options") {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Run with", selection: Binding(
                        get: { model.providerSetup.provider },
                        set: { provider in
                            model.selectProvider(provider)
                            Task { await model.refresh() }
                        }
                    )) {
                        Text("Built-in Apple").tag(VMProvider.builtIn)
                        Text("UTM").tag(VMProvider.utm)
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.isRefreshing || model.isRemovingVM || manager.isBusy || manager.isRunning)
                    Text(model.providerSetup.provider == .utm
                         ? "UTM displays the VM in its own window."
                         : "Tether Host displays the VM here.")
                        .font(.callout).foregroundStyle(.secondary)
                    if !model.candidateVMs.isEmpty {
                        Text("Your virtual machines").font(.headline)
                        ForEach(model.candidateVMs) { candidate in
                            Button { model.selectVM(candidate.id) } label: {
                                HStack {
                                    Image(systemName: model.designatedVM?.id == candidate.id ? "checkmark.circle.fill" : "circle")
                                    Text(candidate.name).lineLimit(1)
                                    if model.isDuplicate(candidate) {
                                        Text(String(candidate.id.description.suffix(8))).font(.caption.monospaced())
                                    }
                                    Spacer()
                                    Text(candidate.state == .started ? "Running" : "Off").font(.caption)
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(manager.isBusy)
                            .help(candidate.id.description)
                            .accessibilityAddTraits(model.designatedVM?.id == candidate.id ? .isSelected : [])
                        }
                    }
                    Button("Create another VM…") { model.showsCreateVM = true }
                        .disabled(manager.isBusy || manager.isRunning || manager.hasOtherHostCopy)
                    HStack {
                        Button("Refresh VMs") { Task { await model.refresh() } }
                            .disabled(model.isRefreshing)
                        Button("Manage VMs") { model.workspaceSection = .library }
                    }
                    if let vm = model.designatedVM {
                        if model.vmBundleURL(for: vm) != nil {
                            Button("Show in Finder") { model.revealVMInFinder(vm) }
                        }
                        if model.providerSetup.provider == .builtIn {
                            if manager.isRunning && manager.runningVMID == vm.id {
                                Button("Shut Down VM") { manager.requestShutdown() }
                                    .disabled(manager.isBusy || manager.shutdownRequested)
                            } else if !manager.isRunning {
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
                            }
                        }
                    }
                    if model.providerSetup.provider == .utm {
                        Link("UTM setup guide", destination: UTMInstallation.macOSGuideURL)
                    }
                }
                .padding(.top, 10)
                .buttonStyle(.borderless)
            }
            .font(.callout)
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
                    Text("A new VM needs a compatible Apple macOS image and free space for macOS and apps. The available download is about 18 GB.")
                        .font(.callout).foregroundStyle(.secondary)
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
                    } else if NativeVMManager.canDownloadHostImage && manager.imageURL == nil {
                        Button("Download macOS 26.2") { Task { await manager.downloadHostImage() } }
                            .buttonStyle(.borderedProminent)
                    }
                    Button("Choose an existing IPSW…") { manager.chooseIPSW() }
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
                    Button("Cancel") { model.showsCreateVM = false }
                    Spacer()
                    Button(model.providerSetup.provider == .utm ? "Create in UTM" : "Create built-in VM") {
                        Task {
                            if let id = await manager.install(for: model.providerSetup.provider) {
                                await model.refresh()
                                model.selectVM(id)
                                model.showsCreateVM = false
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
        VStack(alignment: .leading, spacing: 18) {
            sectionHeader("Finish setup in your VM", detail: "The guest guide handles the private network and assistant setup.")
            if model.setupDependencies.tailscaleReady {
                Label("Tailscale sign-in confirmed for this VM", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                Button("Continue") { model.workspaceSection = .hermes }
                    .buttonStyle(.borderedProminent)
            } else if !model.setupDependencies.vmReady {
                Text(model.designatedVMIsRunning
                     ? "Confirm the macOS desktop before opening the guest guide."
                     : "Your VM is off. Start it to continue setup.")
                    .foregroundStyle(.secondary)
                Button("Prepare VM") { model.workspaceSection = .vm }
                    .buttonStyle(.borderedProminent)
            } else if model.providerSetup.provider == .utm && !model.selectedUTMVMHasGuestSetupDisk {
                Text(model.guestSetupDiskURL == nil
                     ? "Create the guest setup disk, then attach it to this VM in UTM as a removable drive."
                     : "Attach the guest setup disk to this VM in UTM as a removable drive, then refresh status.")
                    .foregroundStyle(.secondary)
                if model.guestSetupDiskURL != nil {
                    Button("Show setup disk in Finder") { model.revealGuestSetupDisk() }
                        .buttonStyle(.borderedProminent)
                    Button("Refresh status") { Task { await model.refresh() } }
                        .disabled(model.isRefreshing)
                } else {
                    Button(model.isExportingGuestSetupDisk ? "Creating disk…" : "Create Guest Setup Disk…") {
                        model.exportGuestSetupDisk()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isExportingGuestSetupDisk)
                }
                Text(model.guestSetupDiskStatus).font(.callout).foregroundStyle(.secondary)
            } else {
                Label("In your VM, open Tether Guest Setup, then Tether Guest Installer.app.",
                      systemImage: "opticaldisc")
                    .fixedSize(horizontal: false, vertical: true)
                Text("Follow the guide to join Tailscale and sign in. The Tailscale app on this physical Mac does not count.")
                    .foregroundStyle(.secondary)
                if canShowVMMonitor && !showsVMMonitor {
                    Button("Show VM desktop") { showsVMMonitor = true }
                        .buttonStyle(.borderedProminent)
                } else if model.providerSetup.provider == .utm {
                    Button("Open UTM") { model.openUTM() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("I signed in to Tailscale in the VM") { model.confirmTailscaleSetup() }
                        .buttonStyle(.borderedProminent)
                }
                if canShowVMMonitor && !showsVMMonitor {
                    Button("I signed in to Tailscale in the VM") { model.confirmTailscaleSetup() }
                } else if model.providerSetup.provider == .utm {
                    Button("I signed in to Tailscale in the VM") { model.confirmTailscaleSetup() }
                }
            }
            DisclosureGroup("Guest setup help") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("In the VM's Finder, open the Tether Guest Setup disk and run Tether Guest Installer.app. Its six-step guide checks Internet, sets up Tailscale and Hermes, requests any needed permissions, and verifies the connection.")
                    if model.providerSetup.provider == .utm {
                        Text("For an existing UTM VM, attach the exported disk as a removable drive in UTM first.")
                        if model.guestSetupDiskURL != nil {
                            Button("Show setup disk in Finder") { model.revealGuestSetupDisk() }
                        }
                    }
                    if model.setupDependencies.tailscaleReady {
                        Button("Tailscale needs attention") { model.clearTailscaleSetup() }
                    }
                }
                .padding(.top, 10)
            }
            .font(.callout)
        }
    }

    private var hermesSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionHeader("Verify your assistant", detail: "Check the private connection from this Mac before using your iPhone.")
            if model.setupDependencies.hermesReady {
                Label("Assistant verified from this Mac", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                Button("Connect iPhone") { model.workspaceSection = .phone }
                    .buttonStyle(.borderedProminent)
            } else if !model.setupDependencies.tailscaleReady {
                Text(model.designatedVMIsRunning
                     ? "Finish Tailscale sign-in in the VM before verifying the connection."
                     : "Your VM is off. Start it and resume the guest setup guide.")
                    .foregroundStyle(.secondary)
                Button("Continue VM setup") {
                    model.workspaceSection = model.setupDependencies.vmReady ? .tailscale : .vm
                }
                .buttonStyle(.borderedProminent)
            } else {
                Text(model.providerSetup.provider == .builtIn
                     ? "In the VM, finish the guest installer's Verify connection step. Connection details are detected automatically."
                     : "Finish Verify connection in the guest installer, then import its private connection.json file or enter the details below.")
                    .foregroundStyle(.secondary)
                if model.connectionURL.isEmpty || model.connectionToken.isEmpty {
                    if model.providerSetup.provider == .builtIn {
                        Button("Check guest connection") { model.useDetectedGuestConnection() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.designatedVMIsRunning || model.isVerifyingConnection)
                    } else {
                        Button("Import Guest Connection…") { model.importConnectionFile() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.isVerifyingConnection)
                    }
                } else {
                    Button(model.isVerifyingConnection ? "Verifying…" : "Verify connection") {
                        Task { await model.verifyConnection() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isVerifyingConnection)
                }
            }
            Text(model.connectionMessage)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            DisclosureGroup("Connection details and help") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("The guest installer sets up Hermes, asks for model sign-in and permissions, then checks a model response. After its final Verify connection step, Tether Host checks access from this Mac.")
                    if model.providerSetup.provider == .builtIn {
                        Button("Use detected guest connection") { model.useDetectedGuestConnection() }
                            .disabled(!model.designatedVMIsRunning || model.isVerifyingConnection)
                    }
                    Button("Import Guest Connection…") { model.importConnectionFile() }
                        .disabled(model.isVerifyingConnection)
                    TextField("Guest URL", text: Binding(
                        get: { model.connectionURL }, set: { model.setConnectionURLFromUser($0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.isVerifyingConnection)
                    .accessibilityHint("Private HTTPS URL of the guest VM")
                    HStack {
                        Group {
                            if showToken {
                                TextField("API token", text: Binding(
                                    get: { model.connectionToken }, set: { model.setConnectionTokenFromUser($0) }
                                ))
                            } else {
                                SecureField("API token", text: Binding(
                                    get: { model.connectionToken }, set: { model.setConnectionTokenFromUser($0) }
                                ))
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        .privacySensitive()
                        .disabled(model.isVerifyingConnection)
                        Button(showToken ? "Hide token" : "Reveal token") { showToken.toggle() }
                    }
                    if model.connectionVerifiedAt != nil {
                        HStack {
                            Button("Copy Tailscale URL") { model.copyConnectionURL() }
                                .disabled(model.connectionURL.isEmpty)
                            Button("Copy Hermes Token") { model.copyConnectionToken() }
                                .disabled(model.connectionToken.isEmpty)
                        }
                    }
                    if let copyMessage = model.connectionCopyMessage {
                        Text(copyMessage).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 10)
                .buttonStyle(.borderless)
            }
            .font(.callout)
        }
    }

    private var phoneSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            if model.isPhoneSetupComplete && !showsPhoneInstructions {
                sectionHeader(model.setupDependencies.hermesReady ? "You're ready" : "Resume your assistant",
                              detail: "Your iPhone connection was confirmed by you.")
                Label(model.setupDependencies.hermesReady
                      ? "Assistant verified from this Mac"
                      : "Current Mac connection needs a fresh check",
                      systemImage: model.setupDependencies.hermesReady ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(.secondary)
                if model.setupDependencies.hermesReady {
                    if canShowVMMonitor {
                        Button("Open VM") { showsVMMonitor = true }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Connection details") { showsPhoneInstructions = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    Button(model.designatedVMIsRunning ? "Check connection" : "Prepare VM") {
                        model.workspaceSection = model.designatedVMIsRunning ? .hermes : .vm
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button("Connect another iPhone") { showsPhoneInstructions = true }
                    .buttonStyle(.borderless)
            } else {
                sectionHeader("Connect your iPhone", detail: "Test the private connection in Tether on your iPhone.")
                if model.setupDependencies.hermesReady {
                    Label("Connection verified from this Mac; phone test still needed",
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                } else {
                    Label(model.connectionURL.isEmpty
                          ? "Verify your assistant on this Mac before connecting your iPhone."
                          : "Current Mac verification is unavailable. Saved connection details remain below.",
                          systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                    Button(model.designatedVMIsRunning ? "Verify connection" : "Prepare VM") {
                        model.workspaceSection = model.designatedVMIsRunning ? .hermes : .vm
                    }
                    .buttonStyle(.borderedProminent)
                }
                if !model.connectionURL.isEmpty {
                    Text("1. Join the same Tailscale network on your iPhone.\n2. In Tether, add a Hermes API Server using the URL and token below.\n3. Tap Test Connection in Tether.")
                        .fixedSize(horizontal: false, vertical: true)
                    Text(model.connectionURL).font(.callout.monospaced())
                        .textSelection(.enabled)
                        .accessibilityLabel("Guest connection URL, \(model.connectionURL)")
                    HStack {
                        Button("Copy URL") { model.copyConnectionURL() }
                            .disabled(model.connectionVerifiedAt == nil)
                        Button("Copy token") { model.copyConnectionToken() }
                            .disabled(model.connectionToken.isEmpty || model.connectionVerifiedAt == nil)
                    }
                }
                if let copyMessage = model.connectionCopyMessage {
                    Text(copyMessage).font(.callout).foregroundStyle(.secondary)
                }
                if model.setupDependencies.hermesReady && !model.isPhoneSetupComplete {
                    Button("I tested the connection on my iPhone") {
                        model.confirmPhoneSetup()
                        showsPhoneInstructions = false
                    }
                    .buttonStyle(.borderedProminent)
                }
                if model.isPhoneSetupComplete {
                    Button("Done") { showsPhoneInstructions = false }
                        .buttonStyle(.borderedProminent)
                }
                DisclosureGroup("Connection help") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("The token clipboard clears after 45 seconds. After a VM reboot, unlock macOS and log in so the guest gateway and desktop permissions can resume.")
                        if model.isPhoneSetupComplete {
                            Button("Phone test needs attention") {
                                model.resetPhoneSetup()
                                showsPhoneInstructions = true
                            }
                        }
                    }
                    .padding(.top, 10)
                }
                .font(.callout)
            }
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
    let isFullScreen: Bool
    let toggleFullScreen: () -> Void
    @State private var showingForcePowerOff = false
    @State private var clipboardIsBusy = false
    @State private var clipboardMessage: String?

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

    private var hasManagerError: Bool {
        let status = manager.status.localizedLowercase
        return status.contains("could not") || status.contains("failed")
            || status.contains("did not accept") || status.contains("stopped:")
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
                if model.providerSetup.provider == .builtIn, manager.isRunning {
                    Menu {
                        Button("Send host text to VM") { sendHostClipboard() }
                        Button("Get VM text on host") { receiveGuestClipboard() }
                    } label: {
                        Label("Clipboard", systemImage: "doc.on.clipboard")
                    }
                    .disabled(clipboardIsBusy)
                    .help("Transfer copied text only when you choose an action")
                    Button {
                        toggleFullScreen()
                    } label: {
                        Label(isFullScreen ? "Exit Full Screen" : "Full Screen",
                              systemImage: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(.borderless)
                    .help(isFullScreen ? "Return to the setup workspace" : "Show the VM across the entire screen")
                }
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
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

            if !isFullScreen {
                VStack(alignment: .leading, spacing: 10) {
                if hasManagerError || !model.setupDependencies.vmReady {
                    Text(manager.status).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                } else {
                    Label("macOS desktop ready", systemImage: "checkmark.circle.fill")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if model.providerSetup.provider == .builtIn {
                    if let clipboardMessage {
                        Text(clipboardMessage).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2).textSelection(.enabled)
                    }
                    if manager.shutdownRequested && manager.isRunning {
                        Button("Force Power Off", role: .destructive) {
                            showingForcePowerOff = true
                        }
                        .disabled(manager.isBusy)
                    }
                }
                if model.preventsHostSleep {
                    Label("Keeping this Mac awake while the VM runs", systemImage: "moon.zzz.slash")
                        .font(.caption).foregroundStyle(.secondary)
                }
                }
                .padding(16)
            }
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

    private func sendHostClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            clipboardMessage = "Copy text on this Mac first, then choose Send host text to VM."
            return
        }
        clipboardIsBusy = true
        Task {
            defer { clipboardIsBusy = false }
            do {
                try await manager.writeGuestClipboardText(text)
                clipboardMessage = "Text sent to the VM clipboard. Press Command-V inside the VM to paste it."
            } catch {
                clipboardMessage = error.localizedDescription
            }
        }
    }

    private func receiveGuestClipboard() {
        clipboardIsBusy = true
        Task {
            defer { clipboardIsBusy = false }
            do {
                let text = try await manager.readGuestClipboardText()
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                guard pasteboard.setString(text, forType: .string) else {
                    clipboardMessage = "Could not copy the VM text to this Mac."
                    return
                }
                clipboardMessage = "VM text is on this Mac's clipboard. Press Command-V here to paste it."
            } catch {
                clipboardMessage = error.localizedDescription
            }
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

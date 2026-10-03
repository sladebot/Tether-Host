import SwiftUI
import TetherHostCore

/// A native sidebar leads from the VM workspace through guest setup and pairing.
struct HostWorkspaceView: View {
    @EnvironmentObject private var model: AppViewModel
    @ObservedObject var manager: NativeVMManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var previousColumnVisibility: NavigationSplitViewVisibility = .all
    @State private var workspaceWindow: NSWindow?
    @State private var healthTab = 0
    @State private var showToken = false
    @State private var showsVMConfiguration = false
    @State private var isVMFullScreen = false
    @State private var fullScreenWindow: NSWindow?

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            sectionContent
                .navigationTitle(model.workspaceSection == .vm ? (model.designatedVM?.name ?? "Virtual machine") : pageTitle)
                .navigationSubtitle(model.workspaceSection == .vm ? "Virtual machine" : (model.designatedVM?.name ?? "Tether Host for Mac"))
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        if model.workspaceSection != .vm, manager.isRunning {
                            Button("Show VM", systemImage: "display") { model.workspaceSection = .vm }
                        }
                        Button {
                            Task {
                                await model.refresh()
                                await model.refreshVerifiedGuestConnection()
                            }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .disabled(model.isRefreshing)
                        .help("Refresh status")
                        SettingsLink { Label("Settings", systemImage: "slider.horizontal.3") }
                    }
                }
        }
        .background(WorkspaceWindowReader { workspaceWindow = $0 })
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1040, minHeight: 700)
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
        .onChange(of: model.setupDependencies) { _, gates in
            model.syncHostSleepAssertion()
            if let step = model.workspaceSection.dependency, !canOpenDependency(step) {
                model.workspaceSection = .vm
            }
        }
        .onChange(of: manager.isRunning) { _, running in
            model.syncHostSleepAssertion()
            if !running { model.invalidateLiveGuestReadiness() }
        }
        .onChange(of: model.workspaceSection) { _, section in
            if section != .hermes { showToken = false }
        }
        .onChange(of: isVMFullScreen) { _, fullScreen in
            if fullScreen {
                previousColumnVisibility = columnVisibility
                columnVisibility = .detailOnly
            } else {
                columnVisibility = previousColumnVisibility
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { notification in
            if let window = notification.object as? NSWindow, window === workspaceWindow,
               model.workspaceSection == .vm {
                fullScreenWindow = window
                isVMFullScreen = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { notification in
            if let window = notification.object as? NSWindow, window === fullScreenWindow {
                isVMFullScreen = false
                fullScreenWindow = nil
            }
        }
        .onChange(of: model.showsCreateVM) { _, shown in
            if shown { showsVMConfiguration = false }
        }
        .sheet(isPresented: $model.showsCreateVM) {
            createVMSheet
                .interactiveDismissDisabled(manager.isBusy)
        }
        .tint(.accentColor)
    }

    private func canOpenDependency(_ dependency: HostSetupDependency) -> Bool {
        dependency == .vm || model.designatedVM != nil
    }

    private var managerHasError: Bool {
        manager.status.localizedCaseInsensitiveContains("failed")
            || manager.status.localizedCaseInsensitiveContains("could not")
            || manager.status.localizedCaseInsensitiveContains("unavailable")
    }

    private var pageTitle: String {
        switch model.workspaceSection {
        case .vm: "Virtual machine"
        case .tailscale: "Tailscale"
        case .hermes: "Hermes"
        case .phone: "Connect iPhone"
        case .library: "VM library"
        case .overview, .diagnostics: "Health & diagnostics"
        }
    }

    private var sidebar: some View {
        List(selection: Binding<HostWorkspaceSection?>(
            get: { model.workspaceSection },
            set: { selection in
                guard let section = selection else { return }
                if let dependency = section.dependency,
                   !canOpenDependency(dependency) { return }
                model.workspaceSection = section
            }
        )) {
            Section("Workspace") {
                navigationRow(.vm, title: "Virtual machine", symbol: "desktopcomputer")
                navigationRow(.phone, title: "Connect iPhone", symbol: "iphone")
            }
            Section("Guest setup") {
                navigationRow(.tailscale, title: "Tailscale", symbol: "network")
                navigationRow(.hermes, title: "Hermes", symbol: "shippingbox")
            }
            Section("Manage") {
                navigationRow(.library, title: "VM library", symbol: "square.stack")
                navigationRow(.overview, title: "Health & diagnostics", symbol: "waveform.path.ecg")
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Divider().padding(.bottom, 8)
                HStack(spacing: 7) {
                    Circle().fill(manager.isRunning ? Color.green : Color.secondary).frame(width: 6, height: 6)
                    Text(model.designatedVM?.name ?? "No VM selected").lineLimit(1)
                }.font(.caption.weight(.medium))
                Text(manager.isRunning ? (model.setupDependencies.hermesReady ? "Running · Connected and ready" : "Running · Guest setup in progress") : "Stopped · Ready when you are")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
        }
    }

    private func navigationRow(_ section: HostWorkspaceSection, title: String, symbol: String) -> some View {
        let dependency = section.dependency
        let enabled = dependency.map { canOpenDependency($0) } ?? true
        let completed = dependency.map { model.setupDependencies.isCompleted($0) } ?? false
        return HStack(spacing: 8) {
            Label(title, systemImage: symbol)
            Spacer(minLength: 0)
            if completed && section != .vm {
                Image(systemName: "checkmark").font(.caption).foregroundStyle(.green)
            } else if !enabled {
                Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .tag(section)
        .disabled(!enabled)
        .help(enabled ? title : dependency?.lockReason ?? title)
        .accessibilityValue(completed ? "Complete" : enabled ? "Available" : "Locked")
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch model.workspaceSection {
        case .vm:
            GeometryReader { geometry in
                vmSection
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
        case .tailscale:
            scrollContent { tailscaleSection }
        case .hermes:
            scrollContent { hermesSection }
        case .phone:
            scrollContent { phoneSection }
        case .library:
            VMInventoryView(createVM: { model.showsCreateVM = true })
        case .overview:
            VStack(spacing: 0) {
                Picker("View", selection: $healthTab) {
                    Text("Health").tag(0)
                    Text("Diagnostics").tag(1)
                }
                .pickerStyle(.segmented).frame(width: 280).padding()
                if healthTab == 0 { HostDashboardView() } else { DiagnosticsView() }
            }
        case .diagnostics:
            DiagnosticsView()
        }
    }

    private func scrollContent<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            content()
                .frame(maxWidth: 860, alignment: .leading)
                .padding(32)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var vmSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !isVMFullScreen {
                providerAvailability
            }
            if model.candidateVMs.isEmpty && !manager.isRunning {
                ContentUnavailableView {
                    Label("A Mac for your agent", systemImage: "desktopcomputer")
                } description: {
                    Text("Create a macOS virtual machine, then connect it to Tether on your iPhone.")
                } actions: {
                    Button("Create virtual machine…") { model.showsCreateVM = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(manager.isBusy || manager.hasOtherHostCopy)
                }
            } else {
                if !isVMFullScreen { nextStepBanner }
                VMMonitorView(manager: manager, isFullScreen: isVMFullScreen) {
                    guard let window = workspaceWindow else { return }
                    fullScreenWindow = window
                    isVMFullScreen = !window.styleMask.contains(.fullScreen)
                    window.toggleFullScreen(nil)
                }
                .clipShape(RoundedRectangle(cornerRadius: isVMFullScreen ? 0 : 10))
                .overlay(RoundedRectangle(cornerRadius: isVMFullScreen ? 0 : 10)
                    .strokeBorder(.quaternary, lineWidth: isVMFullScreen ? 0 : 1))
                if !isVMFullScreen {
                    DisclosureGroup("VM options") {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Enable internet access on next start", isOn: $manager.networkEnabled)
                                .disabled(manager.isBusy || manager.isRunning)
                            Text(manager.networkStatus).font(.caption).foregroundStyle(.secondary)
                            if let vm = model.designatedVM {
                                Button("Show in Finder") { model.revealVMInFinder(vm) }
                            }
                        }.padding(.top, 8)
                    }
                    .font(.callout)
                }
            }
        }
        .padding(isVMFullScreen ? 0 : 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var nextStepBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: model.setupDependencies.hermesReady ? "checkmark.circle.fill" : "info.circle.fill")
                .font(.title2).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(nextStepTitle).font(.headline)
                Text(nextStepDetail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if model.setupDependencies.hermesReady {
                Button("Connect iPhone") { model.workspaceSection = .phone }.buttonStyle(.borderedProminent)
            } else if model.setupDependencies.vmReady {
                Button("Continue setup") {
                    model.workspaceSection = model.setupDependencies.tailscaleReady ? .hermes : .tailscale
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }

    private var nextStepTitle: String {
        if model.setupDependencies.hermesReady { return "Ready for your iPhone" }
        if model.setupDependencies.vmReady { return "Finish guest setup" }
        return manager.isRunning ? "Finish setting up macOS" : "Start your virtual machine"
    }

    private var nextStepDetail: String {
        if model.setupDependencies.hermesReady { return "Hermes is connected. Keep this VM running while you use Tether." }
        if model.setupDependencies.vmReady { return "Open Tether Guest Installer on the setup disk in the guest." }
        return manager.isRunning ? "When you reach the macOS desktop, choose Desktop is ready below." : "Start the VM to continue where you left off."
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

            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var createVMSheet: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text(showsVMConfiguration ? "Configure your VM" : "Choose macOS")
                    .font(.title2.bold())
                Text(showsVMConfiguration ? "Step 2 of 2 · Configure and create" : "Step 1 of 2 · Installation image")
                    .font(.callout).foregroundStyle(.secondary)
                Text(manager.isRunning
                     ? "Tether Host installs macOS in a separate VM."
                     : "Tether Host installs macOS and opens the new VM here.")
                .foregroundStyle(.secondary)
                if manager.isRunning {
                    Text("Your current VM will keep running. The new VM will be saved for you to start later.")
                        .font(.callout).foregroundStyle(.secondary)
                }
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
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if showsVMConfiguration {
                            Label(manager.imageDescription, systemImage: "checkmark.circle.fill")
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Divider().padding(.vertical, 4)
                            VMCreationSettingsView(manager: manager)
                            Divider().padding(.vertical, 4)
                            creationStoragePicker
                            if manager.hasOtherHostCopy {
                                Text("Quit the other Tether Host copy before creating this VM.")
                                    .font(.callout).foregroundStyle(.orange)
                            }
                            if managerHasError {
                                Text(manager.status).font(.callout).foregroundStyle(.orange)
                            }
                        } else {
                        Text("macOS installation image").font(.headline)
                        Text("Download a compatible macOS restore image or choose an IPSW on this Mac. The download is cached on this Mac. You can store the VM on an external drive in the next step.")
                            .font(.callout).foregroundStyle(.secondary)
                        downloadVersionPicker
                        if manager.hasCachedHostImage {
                            Label("A downloaded macOS image is available on this Mac.",
                                  systemImage: "checkmark.circle.fill")
                                .font(.callout).foregroundStyle(.secondary)
                            HStack {
                                if manager.imageURL == nil {
                                    Button("Reuse image") { Task { await manager.useCachedHostImage() } }
                                        .buttonStyle(.borderedProminent)
                                } else {
                                    Button("Reuse image") { Task { await manager.useCachedHostImage() } }
                                        .buttonStyle(.bordered)
                                }
                                Button("Show in Finder") { manager.revealCachedHostImageInFinder() }
                            }
                        }
                        HStack(spacing: 12) {
                            if NativeVMManager.canDownloadHostImage {
                                if !manager.hasCachedHostImage && manager.imageURL == nil {
                                    Button("Download macOS") { Task { await manager.downloadHostImage() } }
                                        .buttonStyle(.borderedProminent)
                                        .disabled(manager.downloadImageOptions.isEmpty || manager.isLoadingDownloadImageOptions)
                                } else {
                                    Button("Download macOS") { Task { await manager.downloadHostImage() } }
                                        .buttonStyle(.bordered)
                                        .disabled(manager.downloadImageOptions.isEmpty || manager.isLoadingDownloadImageOptions)
                                }
                            }
                            Button("Choose an IPSW…") { manager.chooseIPSW() }
                        }
                        Label(manager.imageDescription,
                              systemImage: manager.imageURL == nil ? "doc" : "checkmark.circle.fill")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if manager.imageURL != nil {
                            Button("Show selected image in Finder") { manager.revealSelectedImageInFinder() }
                                .font(.caption)
                        }
                        Link("Find a macOS IPSW", destination: URL(string: "https://ipsw.me/product/Mac")!)
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
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: showsVMConfiguration ? 440 : 380)
                HStack {
                    Button("Cancel") { model.showsCreateVM = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                    if showsVMConfiguration {
                    Button("Back") { showsVMConfiguration = false }
                    Button("Create VM") {
                        Task {
                            if let id = await manager.install() {
                                await model.refresh()
                                if !manager.isRunning || manager.runningVMID == id {
                                    model.selectVM(id)
                                } else {
                                    model.workspaceSection = .library
                                }
                                model.showsCreateVM = false
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(manager.imageURL == nil
                        || manager.creationResourceError != nil
                        || manager.creationStorageValidationMessage != nil
                        || !model.providerSetup.availability.canContinue || manager.hasOtherHostCopy)
                    } else {
                        Button("Continue to configuration") { showsVMConfiguration = true }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                    .disabled(manager.imageURL == nil)
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 520)
        .frame(minHeight: 340)
    }

    private var creationStoragePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Storage location").font(.headline)
            Label(manager.creationStorageDisplayName, systemImage: "externaldrive")
                .font(.callout).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Choose folder…") { manager.chooseCreationStorageFolder() }
                if manager.selectedCreationStorageURL != nil {
                    Button("Use this Mac") { manager.resetCreationStorageToDefault() }
                        .buttonStyle(.borderless)
                }
            }
            Text("Choose a folder on this Mac or an external drive. Keep the drive connected while the VM runs.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = manager.creationStorageValidationMessage {
                Text(error).font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var downloadVersionPicker: some View {
        Group {
            if !manager.downloadImageOptions.isEmpty {
                Picker("macOS version", selection: $manager.selectedDownloadVersion) {
                    ForEach(manager.downloadImageOptions) { option in
                        Text(option.title + (option.id == manager.recommendedDownloadVersion
                                             ? " — Recommended" : ""))
                            .tag(option.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 400, alignment: .leading)
            } else if manager.isLoadingDownloadImageOptions {
                ProgressView("Finding macOS versions…")
                    .controlSize(.small)
            } else {
                Button("Find macOS versions") {
                    Task { await manager.loadDownloadImageOptions() }
                }
                .buttonStyle(.borderless)
            }
        }
        .task { await manager.loadDownloadImageOptions() }
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
            sectionHeader("Connect Tailscale", detail: "Connect your virtual machine to the same private network as your iPhone.")
            setupInstruction(1, "Open the guest installer", detail: "Choose Show VM, then open Tether Guest Installer on the Tether Guest Setup disk.")
            setupInstruction(2, "Sign in to Tailscale", detail: "Run Check Internet, then Set up Tailscale. Sign in using the account you use on your iPhone.")
            setupInstruction(3, "Confirm sign-in", detail: "When Tailscale is connected inside the VM, confirm below to continue.")
            Divider()
            if model.setupDependencies.tailscaleReady {
                Label("You confirmed Tailscale sign-in for this VM.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                HStack {
                    Button("Continue to Hermes") { model.workspaceSection = .hermes }
                        .buttonStyle(.borderedProminent)
                    Button("Tailscale needs attention") { model.clearTailscaleSetup() }
                }
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
            sectionHeader("Set up Hermes", detail: "Give your agent a model and access to the guest desktop.")
            setupInstruction(1, "Install and configure Hermes", detail: "In Tether Guest Installer, complete Install Hermes and Set up Hermes. Sign in to your model provider when prompted.")
            setupInstruction(2, "Enable computer use", detail: "Follow the guest permission prompts, then let the installer check desktop access.")
            setupInstruction(3, "Verify the connection", detail: "Complete Verify connection in the guest. Tether Host detects the details and tests the connection automatically.")
            Divider()
            if model.providerSetup.provider == .builtIn {
                Button("Use detected guest connection") { model.useDetectedGuestConnection() }
                    .disabled(!model.designatedVMIsRunning || model.isVerifyingConnection)
            }
            DisclosureGroup("Manual connection details") {
                VStack(alignment: .leading, spacing: 12) {
                    Button("Import Guest Connection…") { model.importConnectionFile() }
                        .disabled(model.isVerifyingConnection)
                    HStack {
                        TextField("Guest URL — https://your-vm.your-tailnet.ts.net", text: Binding(
                            get: { model.connectionURL }, set: { model.setConnectionURLFromUser($0) }
                        ))
                            .textFieldStyle(.roundedBorder)
                            .disabled(model.isVerifyingConnection)
                        Button("Copy Tailscale URL") { model.copyConnectionURL() }
                            .disabled(model.isVerifyingConnection || model.connectionVerifiedAt == nil || model.connectionURL.isEmpty)
                    }
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
                        Button(showToken ? "Hide" : "Reveal") { showToken.toggle() }
                        Button("Copy Hermes Token") { model.copyConnectionToken() }
                            .disabled(model.isVerifyingConnection || model.connectionVerifiedAt == nil || model.connectionToken.isEmpty)
                    }
                }.padding(.top, 8)
            }
            if let copyMessage = model.connectionCopyMessage {
                Label(copyMessage, systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            }
            Button(model.isVerifyingConnection ? "Verifying…" : "Verify Hermes Connection") {
                Task { await model.verifyConnection() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isVerifyingConnection || model.connectionURL.isEmpty || model.connectionToken.isEmpty
                || !model.setupDependencies.tailscaleReady)
            Text(model.connectionMessage).font(.callout).fixedSize(horizontal: false, vertical: true)
            if model.setupDependencies.hermesReady {
                Label("Hermes connection verified for this VM.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("Connect iPhone") { model.workspaceSection = .phone }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var phoneSection: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 36) {
                phoneInstructions.frame(minWidth: 510)
                phoneIllustration.padding(.top, 90)
            }
            phoneInstructions
        }
    }

    private var phoneIllustration: some View {
        VStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 14) {
                Capsule().fill(Color.primary).frame(width: 58, height: 15).frame(maxWidth: .infinity)
                Text("Add server").font(.headline).padding(.top, 24)
                Text("Connect to your Hermes agent.").font(.caption).foregroundStyle(.secondary)
                ForEach([model.designatedVM?.name ?? "Tether Mac", "Server URL", "••••••••••••"], id: \.self) { value in
                    Text(value).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                }
                Text("Test Connection").font(.caption.weight(.medium)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(10)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 6))
                Spacer(minLength: 20)
            }
            .padding(14).frame(width: 180, height: 350)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 30))
            .overlay(RoundedRectangle(cornerRadius: 30).strokeBorder(Color.primary.opacity(0.85), lineWidth: 5))
            Text("Complete these steps in Tether on your iPhone.")
                .font(.caption).foregroundStyle(.secondary).frame(width: 180)
        }
        .accessibilityHidden(true)
    }

    private var phoneInstructions: some View {
        VStack(alignment: .leading, spacing: 24) {
            sectionHeader("Connect your iPhone", detail: "Add this Mac as a server in Tether on your iPhone.")
            Label(model.setupDependencies.hermesReady
                  ? "Guest connection verified. Keep this VM running while you connect."
                  : "Saved connection details. Start the VM and verify Hermes to reconnect.",
                  systemImage: model.setupDependencies.hermesReady ? "checkmark.circle.fill" : "info.circle")
                .foregroundStyle(model.setupDependencies.hermesReady ? Color.green : .secondary)
            Divider()
            setupInstruction(1, "Join the same Tailscale network", detail: "Open Tailscale on your iPhone and connect.")
            setupInstruction(2, "Add this server in Tether", detail: "Choose Hermes API Server and paste these connection details.")
            VStack(alignment: .leading, spacing: 14) {
                connectionRow("Server URL", value: model.connectionURL, copy: model.copyConnectionURL)
                Divider()
                connectionRow("API token", value: "••••••••••••••••••••••••", copy: model.copyConnectionToken)
            }
            .padding(18)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .padding(.leading, 38)
            Text("Copied tokens clear from the clipboard after 45 seconds.").font(.caption).foregroundStyle(.secondary)
            if let message = model.connectionCopyMessage {
                Label(message, systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green)
            }
            setupInstruction(3, "Test the connection", detail: "Tap Test Connection on your iPhone, then save the server.")
            if model.isPhoneSetupComplete {
                Label("You confirmed the iPhone connection.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("Phone test needs attention") { model.resetPhoneSetup() }
            } else {
                Button("I tested the connection on my iPhone") { model.confirmPhoneSetup() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.setupDependencies.hermesReady)
            }
            Text("After restarting the VM, unlock macOS and log in to resume the guest services.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func connectionRow(_ title: String, value: String, copy: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.callout.weight(.medium))
                Text(value).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            Button("Copy", action: copy).accessibilityLabel("Copy \(title)")
                .disabled(model.connectionVerifiedAt == nil)
        }
    }

    private func setupInstruction(_ number: Int, _ title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(String(number)).font(.caption.weight(.semibold))
                .frame(width: 24, height: 24)
                .background(.quaternary, in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
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
    @State private var showingShutdown = false
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

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Menu {
                        ForEach(model.candidateVMs) { vm in
                            Button(vm.name) { model.selectVM(vm.id) }
                                .disabled(manager.isBusy || manager.isRunning)
                        }
                        Divider()
                        Button("Manage VMs…") { model.workspaceSection = .library }
                    } label: {
                        Label(displayedVMName, systemImage: "display")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Choose a virtual machine")
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
                }
                if manager.isRunning || isFullScreen {
                    Button {
                        toggleFullScreen()
                    } label: {
                        Label(isFullScreen ? "Exit Full Screen" : "Full Screen",
                              systemImage: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(.borderless)
                    .help(isFullScreen ? "Return to the setup workspace" : "Show the VM across the entire screen")
                }
                Label(isOn ? "Running" : "Stopped", systemImage: "circle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(isOn ? .green : .secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            ZStack {
                Color.black
                if model.providerSetup.provider == .builtIn,
                   manager.isRunning, let vm = manager.virtualMachine {
                    NativeVMDisplay(virtualMachine: vm)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "display")
                            .font(.system(size: 54, weight: .ultraLight))
                        Text("VM is off")
                            .font(.title3.weight(.medium))
                        Text("Start this VM to open its macOS desktop.")
                            .font(.callout)
                        Button("Start VM") {
                            guard let vm = model.designatedVM else { return }
                            Task { await manager.startOrShow(vm.id) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(manager.isBusy || manager.hasOtherHostCopy || model.designatedVM == nil || model.designatedVM?.state == .unavailable)
                    }
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .padding()
                }
            }
            .frame(maxWidth: .infinity, minHeight: 220, maxHeight: .infinity)

            if !isFullScreen {
                VStack(alignment: .leading, spacing: 10) {
                if model.providerSetup.provider == .builtIn {
                    Text(manager.status).font(.callout).foregroundStyle(.secondary)
                        .lineLimit(3).textSelection(.enabled)
                    if let clipboardMessage {
                        Text(clipboardMessage).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2).textSelection(.enabled)
                    }
                    HStack {
                        Button("Shut Down…") { showingShutdown = true }
                            .buttonStyle(.bordered)
                            .disabled(!manager.isRunning || manager.isBusy || manager.shutdownRequested)
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
                }
                if model.preventsHostSleep {
                    Label("Keeping this Mac awake while the VM runs", systemImage: "moon.zzz.slash")
                        .font(.caption).foregroundStyle(.secondary)
                }
                }
                .padding(12)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog("Shut down this virtual machine?", isPresented: $showingShutdown) {
            Button("Shut Down") { manager.requestShutdown() }
        } message: {
            Text("macOS will shut down and your iPhone will disconnect until you start the VM again.")
        }
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

/// Resolves this SwiftUI workspace's window without borrowing another window's focus.
private struct WorkspaceWindowReader: NSViewRepresentable {
    let resolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowView {
        let view = WindowView()
        view.resolve = resolve
        return view
    }

    func updateNSView(_ view: WindowView, context: Context) {
        view.resolve = resolve
    }

    final class WindowView: NSView {
        var resolve: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let currentWindow = window
            DispatchQueue.main.async { [weak self] in
                self?.resolve?(currentWindow)
            }
        }
    }
}

/// Shared by first-run setup and VM creation; edits apply only to the new VM.
struct VMCreationSettingsView: View {
    @ObservedObject var manager: NativeVMManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Virtual machine settings").font(.headline)
            resourceRow("Memory (RAM)", value: $manager.creationMemoryGiB,
                        range: manager.creationMemoryRange, unit: "GB")
            resourceRow("CPU cores", value: $manager.creationCPUCount,
                        range: manager.creationCPURange, unit: "cores")
            resourceRow("Disk space", value: $manager.creationDiskGiB,
                        range: manager.creationDiskRange, unit: "GB", step: 8)
            Text("Disk space grows as the VM uses it, up to this limit.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if manager.creationDiskGiB < 64 {
                Text(manager.creationDiskGiB < 40
                     ? "Experimental disk size. macOS installation may fail; use 64 GB or more for room to install and update."
                     : "Below 64 GB, space for macOS and updates is limited. Installation may require a larger disk.")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Use recommended settings") { manager.resetCreationResources() }
                .buttonStyle(.borderless).font(.callout)
            if let error = manager.creationResourceError {
                Text(error).font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 400, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .disabled(manager.isBusy)
    }

    private func resourceRow(_ title: String, value: Binding<Int>,
                             range: ClosedRange<Int>, unit: String, step: Int = 1) -> some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer()
            TextField(title, value: value, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 68)
                .accessibilityLabel(title)
            Text(unit).foregroundStyle(.secondary).frame(width: 38, alignment: .leading)
            Stepper(title, value: value, in: range, step: step)
                .labelsHidden()
                .accessibilityLabel(title)
        }
    }
}

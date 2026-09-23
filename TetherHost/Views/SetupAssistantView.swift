import SwiftUI
#if canImport(TetherHostCore)
import TetherHostCore
#endif

struct SetupAssistantView: View {
    @EnvironmentObject private var model: AppViewModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if model.isInsideGuest || model.providerSetup.hasContinued {
                GuestConnectionSetupView()
            } else {
                welcome
            }
        }
        .navigationTitle("Setup Assistant")
        .task { model.checkProviderInstallation() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.checkProviderInstallation() }
        }
    }

    private var welcome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Welcome to Tether Host")
                        .font(.largeTitle.bold())
                    Text("Choose where your agent’s virtual machine will run.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                Picker("Virtual machine provider", selection: Binding(
                    get: { model.providerSetup.provider },
                    set: { model.selectProvider($0) }
                )) {
                    Text("Apple Virtualization — saved in Tether Host").tag(VMProvider.builtIn)
                    Text("UTM — VMs registered with UTM").tag(VMProvider.utm)
                }
                .pickerStyle(.radioGroup)
                .disabled(model.isRefreshing)

                VStack(alignment: .leading, spacing: 12) {
                    Text(model.providerSetup.provider == .utm
                         ? "Choose an existing UTM VM without an IPSW, or create a new one from an Apple macOS restore image. New VMs created here appear and open in UTM."
                         : "Tether Host stores and opens built-in Apple VMs itself; they do not appear in UTM. A new macOS VM needs Apple's restore image (IPSW), but an existing VM does not.")
                    if model.providerSetup.provider == .utm {
                        Text("This build requires UTM \(UTMInstallation.supportedVersion) in Applications.")
                            .font(.callout).foregroundStyle(.secondary)
                        Link("Download UTM", destination: UTMInstallation.downloadURL)
                            .accessibilityHint("Opens the official UTM website in your browser")
                    }
                    availabilityStatus
                    if model.providerSetup.provider == .utm {
                        Button("Check Again") { model.checkProviderInstallation() }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))

                if model.providerSetup.provider == .utm {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Get macOS for your VM").font(.headline)
                        Text("In Tether Host, select an existing UTM VM or choose a compatible IPSW and press Create UTM VM. Tether Host installs macOS and registers the new VM in UTM. You can also create one manually in UTM.")
                            .font(.callout).foregroundStyle(.secondary)
                        Link("macOS setup guide", destination: UTMInstallation.macOSGuideURL)
                        Link("Download macOS restore image (IPSW)", destination: UTMInstallation.macOSImageURL)
                        Text("IPSW.me is a third-party index linking to Apple-hosted images. Apple Virtualization and UTM both use this macOS installer format for new VMs; existing VMs do not need it again.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Text("Continue to create or select a VM, then install the guest components and verify the phone connection.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer(minLength: 24)
                    Button(model.providerSetup.provider == .builtIn ? "Create New VM…" : "Continue with UTM") {
                        model.continueProviderSetup()
                    }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.providerSetup.availability.canContinue || model.isRefreshing)
                        .accessibilityHint("Requires the selected VM provider to be available")
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(40)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var availabilityStatus: some View {
        switch model.providerSetup.availability {
        case .unchecked:
            Label("Checking availability…", systemImage: "arrow.clockwise")
        case .ready:
            Label(model.providerSetup.provider == .utm ? "UTM is installed. The guided installer can continue." : "Built-in VM installer is available.",
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .blocked(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

}

private struct NativeVMSetupView: View {
    @EnvironmentObject private var model: AppViewModel
    @ObservedObject var manager: NativeVMManager

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SetupPhaseBox(number: 1, title: "Create a new macOS VM", symbol: "internaldrive") {
                Text("Choose a macOS restore image on this Mac or download one from Apple. Allow about 65 GB of free space for the image and VM.")
                    .foregroundStyle(.secondary)
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
                }
                VMCreationSettingsView(manager: manager)
                HStack {
                    Button("Choose macOS IPSW…") { manager.chooseIPSW() }
                    Text(manager.imageDescription)
                        .font(.callout)
                        .textSelection(.enabled)
                }
                if manager.hasCachedHostImage {
                    Text("A downloaded macOS image is available on this Mac.")
                        .font(.callout)
                    HStack {
                        Button("Reuse image") { Task { await manager.useCachedHostImage() } }
                        Button("Show in Finder") { manager.revealCachedHostImageInFinder() }
                    }
                    .disabled(manager.isBusy)
                }
                if NativeVMManager.canDownloadHostImage {
                    Button("Download macOS") {
                        Task { await manager.downloadHostImage() }
                    }
                    .disabled(manager.isBusy || manager.downloadImageOptions.isEmpty
                              || manager.isLoadingDownloadImageOptions)
                }
                if manager.imageURL != nil {
                    Button("Show selected image in Finder") { manager.revealSelectedImageInFinder() }
                }
                Button(manager.isBusy ? "Installing…" : "Create New VM from Selected IPSW") {
                    Task {
                        if let id = await manager.install() {
                            await model.refresh()
                            if !manager.isRunning || manager.runningVMID == id {
                                model.selectVM(id)
                            } else {
                                model.workspaceSection = .library
                            }
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(manager.imageURL == nil || manager.isBusy || manager.creationResourceError != nil)
                if manager.imageURL == nil {
                    Text("First choose an IPSW above or download the compatible image. Then Create New VM becomes available.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if manager.isBusy { ProgressView().controlSize(.small) }
                Text(manager.status).font(.callout).textSelection(.enabled)
            }
            SetupPhaseBox(number: 2, title: "Finish the macOS welcome screens", symbol: "power") {
                if model.candidateVMs.isEmpty {
                    Text("No completed Tether Host VM is installed yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(model.candidateVMs) { vm in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(vm.name).fontWeight(.medium)
                                Text(vm.id.description).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.vmBundleURL(for: vm) != nil {
                                Button("Show in Finder") { model.revealVMInFinder(vm) }
                            }
                            Button(manager.runningVMID == vm.id ? "Show VM" : "Start VM") {
                                model.selectVM(vm.id)
                                Task { await manager.startOrShow(vm.id) }
                            }
                        }
                        if manager.isDesktopReady(for: vm.id) {
                            HStack {
                                Label("You confirmed the macOS desktop is ready.", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Spacer()
                                Button("Setup isn't finished") { manager.clearDesktopReady(for: vm.id) }
                                    .font(.caption)
                            }
                        } else {
                            Label("Waiting for you to finish macOS Setup Assistant in the VM.", systemImage: "hourglass")
                                .foregroundStyle(.orange)
                        }
                    }
                }
                Button("Refresh VM List") { Task { await model.refresh() } }
                    .disabled(model.isRefreshing)
                Text(manager.status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                Text("Create the macOS user and complete Apple's first-run screens inside the VM. Its network uses this Mac's Internet through Apple NAT. When the desktop appears, click “Desktop is ready — Continue” below the VM display. That returns here without shutting the VM down. Use Show VM whenever you need to go back.")
                    .foregroundStyle(.secondary)
            }
            SetupPhaseBox(number: 3, title: "Install Tailscale inside the VM", symbol: "network") {
                if let vm = model.designatedVM, !manager.isDesktopReady(for: vm.id) {
                    Label("Finish step 2 before installing guest components.", systemImage: "hourglass")
                        .foregroundStyle(.orange)
                }
                Text("The guest setup disk is attached automatically when the VM starts. In the VM, open the disk and launch Tether Guest Installer.app. It checks real HTTPS access from the VM, then configures Tailscale and Hermes. Tether Host stays installed only on this Mac.")
                    .foregroundStyle(.secondary)
                if let vm = model.designatedVM, manager.isDesktopReady(for: vm.id) {
                    Button("Show VM to open the guest setup disk") {
                        Task { await manager.startOrShow(vm.id) }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            SetupPhaseBox(number: 4, title: "Install Hermes inside the VM", symbol: "shippingbox") {
                Text("The same in-VM setup checks Hermes, installs or configures it, and verifies the private connection before you connect Tether on your phone.")
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $manager.showsDisplay) {
            if let vm = manager.virtualMachine {
                VStack(spacing: 0) {
                    HStack {
                        Text("Tether Host VM").font(.headline)
                        Spacer()
                        Text(manager.status).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(10)
                    NativeVMDisplay(virtualMachine: vm)
                    HStack {
                        Text("Finish the macOS account setup here. Tether Host cannot inspect the fresh desktop until its guest app is installed.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Return to Setup Guide") { manager.showsDisplay = false }
                            .disabled(manager.isBusy)
                        Button("Desktop is ready — Continue") { manager.confirmDesktopReady() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!manager.isRunning || manager.isBusy)
                    }
                    .padding(10)
                }
                .frame(minWidth: 900, minHeight: 650)
                .interactiveDismissDisabled(manager.isBusy)
            }
        }
        .task { await manager.loadDownloadImageOptions() }
    }
}

private struct GuestConnectionSetupView: View {
    @EnvironmentObject private var model: AppViewModel
    @State private var showToken = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.isInsideGuest ? "Install the Tether backend" : "Install Tether in your VM")
                        .font(.largeTitle.bold())
                    Text(model.isInsideGuest
                         ? "Tether checks Tailscale and Hermes in this VM, helps configure what is missing, and verifies the finished backend."
                         : "Follow the four checks in order. Tether Host verifies the exact VM and creates a read-only transfer disk for guest-only dependency setup.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                if !model.isInsideGuest, model.providerSetup.provider == .utm {
                    HStack(alignment: .center, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Want to create a new macOS VM?").font(.headline)
                            Text("Use Tether Host's built-in Apple VM setup. The UTM steps below are for existing UTM VMs.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        Button("Create New VM") { model.startNewNativeVMSetup() }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(16)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                }
                if model.isInsideGuest {
                    guestInstallation
                } else if model.providerSetup.provider == .builtIn {
                    NativeVMSetupView(manager: model.nativeVM)
                } else {
                    hostInstallation
                }
                Divider()
                connectionSetup
            }
            .frame(maxWidth: 660, alignment: .leading)
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .task {
            model.scanGuestDependencies()
            while !Task.isCancelled {
                model.refreshGuestStatus()
                if model.isInsideGuest { model.scanGuestDependencies() }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onDisappear { showToken = false }
    }

    private var hostInstallation: some View {
        VStack(alignment: .leading, spacing: 16) {
            SetupPhaseBox(number: 1, title: "Check that the VM exists", symbol: "macpro.gen3") {
                Text("Choose the exact UTM VM to manage. This check does not inspect dependencies on the physical Mac or change any VM.")
                    .foregroundStyle(.secondary)
                if let vm = model.designatedVM {
                    Label("VM found", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    HStack {
                        Text(vm.id.description)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Spacer()
                        if model.vmBundleURL(for: vm) != nil {
                            Button("Show in Finder") { model.revealVMInFinder(vm) }
                        }
                        if model.candidateVMs.count > 1 {
                            Button("Choose Different VM") { model.clearVMSelection() }
                        }
                    }
                } else {
                    Label("No UTM VM is selected.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    if !model.candidateVMs.isEmpty {
                        Text("Choose the exact VM to manage:")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        ForEach(model.candidateVMs) { vm in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(vm.name) — \(vm.state.rawValue)").fontWeight(.medium)
                                    Text(vm.id.description)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if model.vmBundleURL(for: vm) != nil {
                                    Button("Show in Finder") { model.revealVMInFinder(vm) }
                                }
                                Button("Use This VM") { model.selectVM(vm.id) }
                            }
                        }
                    }
                }
                HStack {
                    Button("Open UTM") { model.openUTM() }
                        .buttonStyle(.borderedProminent)
                    Button("Refresh VM List") { Task { await model.refresh() } }
                        .disabled(model.isRefreshing)
                    Button("Change Provider") { model.changeSetupProvider() }
                }
                Divider()
                Text("Need a macOS restore image for a new UTM VM?")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Link("Download macOS IPSW (IPSW.me)", destination: UTMInstallation.macOSImageURL)
                    Link("UTM macOS setup guide", destination: UTMInstallation.macOSGuideURL)
                }
                Text("IPSW.me is a third-party index linking to Apple-hosted restore images. UTM can also download a compatible image automatically when you create a macOS VM.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SetupPhaseBox(number: 2, title: "Check the UTM VM process", symbol: "power") {
                if let vm = model.designatedVM {
                    if model.designatedVMIsRunning {
                        Label("\(vm.name) process is running. Confirm macOS appears in its display before continuing.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("\(vm.name) is \(vm.state.rawValue). Start it in UTM, then check again.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                } else {
                    Label("Find the VM in step 1 before checking its boot state.", systemImage: "circle.dashed")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Open UTM") { model.openUTM() }
                    Button("Check Boot State Again") { Task { await model.refresh() } }
                        .disabled(model.isRefreshing)
                }
                Divider()
                Text(model.selectedUTMVMHasGuestSetupDisk
                     ? "The read-only Tether guest installer is included with this VM. Open it inside the VM after reaching the macOS desktop."
                     : "For an existing UTM VM, create a read-only ISO containing the Tether guest helper and attach it as a removable drive. Host folders and shared clipboard can stay disabled.")
                    .foregroundStyle(.secondary)
                if !model.selectedUTMVMHasGuestSetupDisk {
                    HStack {
                        Button(model.isExportingGuestSetupDisk ? "Creating…" : "Create Guest Setup Disk…") {
                            model.exportGuestSetupDisk()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isExportingGuestSetupDisk || !model.designatedVMIsRunning)
                        if model.isExportingGuestSetupDisk { ProgressView().controlSize(.small) }
                        if model.guestSetupDiskURL != nil {
                            Button("Show in Finder") { model.revealGuestSetupDisk() }
                        }
                    }
                    Text(model.guestSetupDiskStatus)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }

            SetupPhaseBox(number: 3, title: "Check and configure Tailscale inside the VM", symbol: "network") {
                VStack(alignment: .leading, spacing: 7) {
                    if !model.selectedUTMVMHasGuestSetupDisk {
                        Text("1. In UTM, attach **Tether Guest Setup.iso** to the running VM as a removable drive.")
                    }
                    Text("After the macOS desktop appears, open the guest setup disk and launch **Tether Guest Installer.app**. Click Start setup and follow its prompts. It keeps the VM awake, checks guest Internet, then installs or configures Tailscale and Hermes. Do not install a second copy of Tether Host.")
                }
                .foregroundStyle(.secondary)
            }

            SetupPhaseBox(number: 4, title: "Check and configure Hermes inside the VM", symbol: "shippingbox") {
                Text("Tether checks the guest’s Hermes runtime. It installs Hermes when missing, or configures the existing guest installation for authenticated API access, model login, computer use, and private Tailscale HTTPS.")
                    .foregroundStyle(.secondary)
                Text("After verification succeeds, load the guest connection and enter its URL and token in Tether on your iPhone.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var guestInstallation: some View {
        VStack(alignment: .leading, spacing: 16) {
            SetupPhaseBox(number: 3, title: "Check and configure Tailscale", symbol: "network") {
                Text("This inventory is read from inside the VM. The physical Mac's Hermes, Tailscale, and developer tools are never used to satisfy guest installation checks.")
                    .foregroundStyle(.secondary)
                ForEach(model.guestDependencies.filter { $0.id == "tailscale" }) { dependency in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: dependency.state == .installed ? "checkmark.circle.fill" : "arrow.down.circle")
                            .foregroundStyle(dependency.state == .installed ? .green : .secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(dependency.title).fontWeight(.medium)
                            Text(dependency.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Button("Scan This VM Again") { model.scanGuestDependencies() }
            }
            SetupPhaseBox(number: 4, title: "Check and configure Hermes", symbol: "shippingbox.fill") {
                ForEach(model.guestDependencies.filter { $0.id == "hermes" || $0.id == "verification" }) { dependency in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: dependency.state == .installed ? "checkmark.circle.fill" : "wrench.and.screwdriver")
                            .foregroundStyle(dependency.state == .installed ? .green : .secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(dependency.title).fontWeight(.medium)
                            Text(dependency.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if model.guestDependencies.isEmpty { Text("Scanning this VM…").foregroundStyle(.secondary) }
                Text("Setup preserves a working Hermes installation and configures it for Tether. If Hermes is missing, it installs the pinned runtime. It then pauses for model login and guest Accessibility and Screen Recording approval.")
                    .foregroundStyle(.secondary)
                Button("Run Guest Setup") { model.startGuestSetup() }
                    .buttonStyle(.borderedProminent)
                Label(model.guestSetupStatus, systemImage: "progress.indicator")
                    .font(.callout)
                    .textSelection(.enabled)
                Text("Tether checks loopback binding, API authentication, durable runs, private HTTPS, computer use, and a real model response before producing connection details.")
                    .foregroundStyle(.secondary)
                Button("Load Guest Connection") { Task { await model.loadGuestConnection() } }
                    .disabled(model.isVerifyingConnection)
            }
        }
    }

    private var connectionSetup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect Tether iOS").font(.title2.bold())
            Button("Import Guest Connection…") { model.importConnectionFile() }
                .disabled(model.isVerifyingConnection)
            HStack {
                TextField("VM URL — https://your-vm.your-tailnet.ts.net", text: $model.connectionURL)
                    .textFieldStyle(.roundedBorder).disabled(model.isVerifyingConnection)
                Button("Copy Tailscale URL") { model.copyConnectionURL() }
                    .disabled(model.isVerifyingConnection || model.connectionVerifiedAt == nil || model.connectionURL.isEmpty)
            }
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
                Button("Copy Hermes Token") { model.copyConnectionToken() }
                    .disabled(model.isVerifyingConnection || model.connectionVerifiedAt == nil || model.connectionToken.isEmpty)
            }
            if let copyMessage = model.connectionCopyMessage {
                Label(copyMessage, systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            }
            HStack {
                Button(model.isVerifyingConnection ? "Verifying…" : "Verify Connection") {
                    Task { await model.verifyConnection() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isVerifyingConnection || model.connectionURL.isEmpty || model.connectionToken.isEmpty)
                if model.isVerifyingConnection { ProgressView().controlSize(.small) }
            }
            Text(model.connectionMessage).font(.callout).fixedSize(horizontal: false, vertical: true)
            if let date = model.connectionVerifiedAt {
                Label("Verified \(date.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                HStack {
                    Button("Copy Tailscale URL") { model.copyConnectionURL() }
                    Button("Copy Hermes Token") { model.copyConnectionToken() }
                }
                Text("In Tether iOS, add a Hermes API Server connection, enter this URL and token, and tap Test Connection. Your iPhone must be connected to the same Tailscale network. The token clipboard clears after 45 seconds unless you copy something else.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("The VM must remain running. After a reboot, unlock macOS and log in to restore the guest gateway and desktop permissions.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

private struct SetupPhaseBox<Content: View>: View {
    let number: Int
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    init(number: Int, title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.number = number
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        } label: {
            Label("\(number). \(title)", systemImage: symbol)
                .font(.headline)
        }
    }
}

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
                    Text("Built-in Apple VM — production target").tag(VMProvider.builtIn)
                    Text("UTM — available in this preview").tag(VMProvider.utm)
                }
                .pickerStyle(.radioGroup)
                .disabled(model.isRefreshing)

                VStack(alignment: .leading, spacing: 12) {
                    Text(model.providerSetup.provider == .utm
                         ? "Keep UTM’s desktop window and VM settings. Install UTM separately before continuing."
                         : "Use Apple’s virtualization through Tether Host. No separate VM app is required.")
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
                        Text("In UTM, create a new VM and choose Virtualize → macOS. Leave the IPSW selection empty to let UTM download a compatible restore image.")
                            .font(.callout).foregroundStyle(.secondary)
                        Link("macOS setup guide", destination: UTMInstallation.macOSGuideURL)
                        Link("Download macOS restore image (IPSW)", destination: UTMInstallation.macOSImageURL)
                        Text("Manual download opens IPSW.me, a third-party index linking to Apple’s downloads. Choose an image compatible with your Mac; UTM’s automatic download is recommended.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Text("Continue to guest setup and connection verification. Create and boot your VM before installing its components.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer(minLength: 24)
                    Button("Continue") { model.continueProviderSetup() }
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
                if model.isInsideGuest {
                    guestInstallation
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
                Text("Tether looks for one exact **\(model.expectedVMName)** VM. This read-only check does not inspect dependencies on the physical Mac or change any VM.")
                    .foregroundStyle(.secondary)
                if let vm = model.designatedVM {
                    Label("VM found", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(vm.id.description)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    Label("No single \(model.expectedVMName) VM was found.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    if model.candidateVMs.count > 1 {
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
            }

            SetupPhaseBox(number: 2, title: "Check that the VM boots", symbol: "power") {
                if let vm = model.designatedVM {
                    if model.designatedVMIsRunning {
                        Label("\(vm.name) is running", systemImage: "checkmark.circle.fill")
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
                Text("Once the VM is running, create a read-only ISO containing Tether Host. Attach it as a removable drive; host folders and shared clipboard can stay disabled.")
                    .foregroundStyle(.secondary)
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

            SetupPhaseBox(number: 3, title: "Check and configure Tailscale inside the VM", symbol: "network") {
                VStack(alignment: .leading, spacing: 7) {
                    Text("1. In UTM, attach **Tether Guest Setup.iso** to the running VM as a removable drive.")
                    Text("2. Inside the VM, open the mounted disk and copy **Tether Host for Mac** to Applications.")
                    Text("3. Launch it inside the VM and choose **Run Guest Setup**.")
                    Text("Tether checks the guest’s Tailscale app and connection. If either is missing, it installs Tailscale or guides sign-in and Apple approval inside the VM.")
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
            TextField("VM URL — https://your-vm.your-tailnet.ts.net", text: $model.connectionURL)
                .textFieldStyle(.roundedBorder).disabled(model.isVerifyingConnection)
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
                    Button("Copy URL") { model.copyConnectionURL() }
                    Button("Copy Token") { model.copyConnectionToken() }
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

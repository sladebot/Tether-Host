import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TetherHostCore

struct HostDashboardSnapshot: Sendable {
    var observations: [HealthObservation]
    var inventory: [VirtualMachineRecord]
    var setup: SetupJournal
    var diagnostics: [DiagnosticEntry]

    static var unobserved: HostDashboardSnapshot {
        HostDashboardSnapshot(
            observations: HealthComponent.allCases.map {
                HealthObservation(component: $0, state: .unknown, summary: "Not checked", validFor: 60)
            },
            inventory: [],
            setup: SetupJournal(),
            diagnostics: []
        )
    }
}

protocol HostStatusProviding: Sendable {
    func snapshot(for vmProvider: VMProvider) async throws -> HostDashboardSnapshot
}

struct LiveHostStatusProvider: HostStatusProviding {
    private let nativeReader: (any VirtualMachineReading)?
    private let journalStore: FileSetupJournalStore?

    init() {
        var applicationSupport: URL?
        if let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            applicationSupport = support.appendingPathComponent("Tether Host for Mac", isDirectory: true)
            nativeReader = NativeVirtualMachineStore(
                rootURL: applicationSupport!.appendingPathComponent("Virtual Machines", isDirectory: true)
            )
        } else {
            nativeReader = nil
        }
        if let applicationSupport {
            journalStore = FileSetupJournalStore(
                fileURL: applicationSupport.appendingPathComponent("setup-journal.json")
            )
        } else {
            journalStore = nil
        }
    }

    func snapshot(for vmProvider: VMProvider) async throws -> HostDashboardSnapshot {
        let inventory: [VirtualMachineRecord]
        let evidenceSource: EvidenceSource
        switch vmProvider {
        case .builtIn:
            guard let nativeReader else { throw NativeVirtualMachineStoreError.invalidRoot }
            inventory = try await nativeReader.list()
            evidenceSource = .appleVirtualization
        }
        let now = Date()
        let matches = inventory
        let vmState: HealthState = matches.count == 1 ? .healthy : .degraded
        let detail: String
        if matches.count == 1 {
            detail = "Tether's native Apple VM is available by exact UUID."
        } else if inventory.isEmpty {
            detail = "No VM was found. Create a VM in Setup Assistant."
        } else {
            detail = "Found \(matches.count) matching VMs; exact designation is required."
        }
        var observations = HostDashboardSnapshot.unobserved.observations
        if let index = observations.firstIndex(where: { $0.component == .virtualMachine }) {
            observations[index] = HealthObservation(
                component: .virtualMachine,
                state: vmState,
                summary: detail,
                source: evidenceSource,
                observedAt: now,
                validFor: 60
            )
        }
        let setup = try await journalStore?.load() ?? SetupJournal(now: now)
        return HostDashboardSnapshot(
            observations: observations,
            inventory: inventory,
            setup: setup,
            diagnostics: [DiagnosticEntry(event: .inventoryRead, date: now)]
        )
    }
}

enum HostDestination: String, CaseIterable, Identifiable {
    case overview, setup, virtualMachines, diagnostics
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: "Overview"
        case .setup: "Setup Assistant"
        case .virtualMachines: "Virtual Machines"
        case .diagnostics: "Diagnostics"
        }
    }
    var symbol: String {
        switch self {
        case .overview: "shield.lefthalf.filled"
        case .setup: "checklist"
        case .virtualMachines: "macpro.gen3"
        case .diagnostics: "stethoscope"
        }
    }
}

enum HostWorkspaceSection: String, CaseIterable, Identifiable {
    case vm, tailscale, hermes, phone, library, overview, diagnostics
    var id: String { rawValue }
}

private enum VMRemovalError: LocalizedError {
    case unavailable
    case filesRemain(URL)

    var errorDescription: String? {
        switch self {
        case .unavailable: "The exact stopped VM bundle is no longer available. Refresh the list and try again."
        case .filesRemain(let bundle):
            "The VM registration was removed, but files remain at \(bundle.path). Delete that bundle in Finder to reclaim space."
        }
    }
}

@MainActor
final class AppViewModel: ObservableObject {
    @Published var selection: HostDestination? = .overview
    @Published var workspaceSection: HostWorkspaceSection = .vm {
        didSet {
            // Initial return routing is allowed only until the user picks a
            // section. Later inventory polls must never move them away.
            if workspaceSection != oldValue { pendingPhoneRestoration = false }
        }
    }
    @Published var showsCreateVM = false
    @Published private(set) var observations: [HealthObservation]
    @Published private(set) var inventory: [VirtualMachineRecord]
    @Published private(set) var setup: SetupJournal
    @Published private(set) var diagnostics: [DiagnosticEntry]
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var statusMessage = "No host evidence has been collected yet."
    @Published private(set) var isRemovingVM = false
    @Published private(set) var vmRemovalMessage: String?
    @Published private(set) var locatedVMBundles: [VirtualMachineID: URL] = [:]
    private var bundleLookupRevision = UUID()
    @Published private(set) var preventsHostSleep = false
    private var hostSleepActivity: NSObjectProtocol?

    @Published var connectionURL = "" {
        didSet {
            connectionVerifiedAt = nil
            if !isHydratingSavedConnection && connectionURL != oldValue {
                isClearingTokenForURLChange = true
                connectionToken = ""
                isClearingTokenForURLChange = false
            }
            if !isHydratingSavedConnection && PhoneSetupConfirmation.normalizedEndpoint(oldValue) !=
                PhoneSetupConfirmation.normalizedEndpoint(connectionURL) {
                resetPhoneSetup()
            }
        }
    }
    @Published var connectionToken = "" {
        didSet {
            connectionVerifiedAt = nil
            if connectionToken != oldValue && !isHydratingSavedConnection &&
                !isClearingTokenForURLChange && !isRestoringConnectionToken {
                resetPhoneSetup()
            }
        }
    }
    @Published private(set) var connectionVerifiedAt: Date?
    @Published private(set) var isVerifyingConnection = false
    @Published private(set) var connectionMessage = "Verify the guest endpoint before connecting your phone."
    @Published private(set) var connectionCopyMessage: String?
    @Published private(set) var guestSetupStatus = "Guest setup has not started."
    @Published private(set) var guestDependencies: [GuestDependencyStatus] = []
    let isInsideGuest: Bool
    private let connectionVault: any SecretStoring
    private let connectionVerifier: ConnectionVerifier
    private let now: @MainActor () -> Date
    private var connectionID = VirtualMachineID(rawValue: UUID())
    private var connectionInputRevision = 0
    private var hasManualConnectionOverride = false
    private var hasDetectedGuestConnection = false
    private var isReadingVerifiedGuestConnection = false
    private var lastAutomaticVerificationAt: Date?
    private var isClearingTokenForURLChange = false
    private var isRestoringConnectionToken = false
    private var isHydratingSavedConnection = true
    private var pendingPhoneRestoration = true

    @Published private(set) var providerSetup: VMProviderSetup
    let nativeVM: NativeVMManager
    @Published private(set) var selectedVMID: VirtualMachineID?
    @Published private(set) var tailscaleConfirmedVMID: VirtualMachineID?
    @Published private(set) var verifiedForVMID: VirtualMachineID?
    @Published private(set) var phoneSetupConfirmation: PhoneSetupConfirmation?
    private let preferences: UserDefaults
    private let provider: any HostStatusProviding

    init(provider: any HostStatusProviding = LiveHostStatusProvider(), preferences: UserDefaults = .standard,
         nativeVM: NativeVMManager? = nil,
         connectionVerifier: ConnectionVerifier = ConnectionVerifier(),
         connectionVault: any SecretStoring = KeychainSecretStore(service: "app.tether.host.connection"),
         isInsideGuest: Bool = GuestSetupEnvironment.isVirtualMac,
         now: @escaping @MainActor () -> Date = { Date() }) {
        self.nativeVM = nativeVM ?? NativeVMManager(preferences: preferences)
        self.connectionVerifier = connectionVerifier
        self.connectionVault = connectionVault
        self.isInsideGuest = isInsideGuest
        self.now = now
        self.preferences = preferences
        selectedVMID = preferences.string(forKey: "setup.vmID").flatMap(VirtualMachineID.init)
        tailscaleConfirmedVMID = preferences.string(forKey: "setup.tailscaleConfirmedVMID").flatMap(VirtualMachineID.init)
        // Retire legacy preferences only; never move or delete existing VM disks.
        if let previous = preferences.string(forKey: "setup.vmProvider"), previous != "builtIn" {
            selectedVMID = nil
            preferences.removeObject(forKey: "setup.vmID")
            preferences.removeObject(forKey: "connection.endpoint")
            preferences.removeObject(forKey: "connection.id")
            preferences.removeObject(forKey: "setup.phoneConfirmation")
        }
        for key in ["setup.vmProvider", "setup.builtInDefaultApplied", "setup.utmDesktopReadyVMID"] {
            preferences.removeObject(forKey: key)
        }
        phoneSetupConfirmation = preferences.data(forKey: "setup.phoneConfirmation")
            .flatMap { try? JSONDecoder().decode(PhoneSetupConfirmation.self, from: $0) }
        providerSetup = VMProviderSetup()
        tailscaleConfirmedVMID = nil
        preferences.removeObject(forKey: "setup.tailscaleConfirmedVMID")
        selection = .setup
        self.provider = provider
        let initial = HostDashboardSnapshot.unobserved
        observations = initial.observations
        inventory = initial.inventory
        setup = initial.setup
        diagnostics = initial.diagnostics
        if let endpoint = preferences.string(forKey: "connection.endpoint"),
           let idString = preferences.string(forKey: "connection.id"),
           let id = VirtualMachineID(idString) {
            connectionID = id
            connectionURL = endpoint
            let revision = connectionInputRevision
            Task { await restoreConnectionToken(for: id, endpoint: endpoint, revision: revision) }
        }
        isHydratingSavedConnection = false
    }

    func selectProvider(_ provider: VMProvider) {
        clearConnectionForVMChange()
        providerSetup.select(provider)
        selectedVMID = nil
        preferences.removeObject(forKey: "setup.vmID")
        inventory = []
        locatedVMBundles = [:]
        bundleLookupRevision = UUID()
        vmRemovalMessage = nil
        observations = HostDashboardSnapshot.unobserved.observations
        checkProviderInstallation()
        syncHostSleepAssertion()
    }

    private static func availability(for provider: VMProvider) -> VMProviderAvailability {
        guard AppleVirtualizationSupport.isAvailable else {
            return .blocked("Built-in VM requires an Apple silicon Mac with macOS 14 or later.")
        }
        return .ready
    }

    func checkProviderInstallation() {
        providerSetup.refresh(using: Self.availability)
    }

    func continueProviderSetup() {
        guard providerSetup.advance(using: Self.availability) else { return }
        Task { await refresh() }
    }

    func changeSetupProvider() { providerSetup.back() }

    func startNewNativeVMSetup() {
        selectProvider(.builtIn)
        continueProviderSetup()
        selection = .setup
        workspaceSection = .vm
    }

    func startNewVMSetup() {
        selection = .setup
        workspaceSection = .vm
        showsCreateVM = true
    }

    /// A persisted iPhone pairing acknowledgement, scoped to this VM and
    /// canonical HTTPS endpoint. It does not claim the guest is online now.
    var isPhoneSetupComplete: Bool {
        phoneSetupConfirmation?.matches(vmID: designatedVM?.id, endpoint: connectionURL) ?? false
    }

    func confirmPhoneSetup() {
        guard setupDependencies.hermesReady, let vmID = designatedVM?.id,
              let confirmation = PhoneSetupConfirmation(vmID: vmID, endpoint: connectionURL) else { return }
        phoneSetupConfirmation = confirmation
        if let data = try? JSONEncoder().encode(confirmation) {
            preferences.set(data, forKey: "setup.phoneConfirmation")
        }
    }

    func resetPhoneSetup() {
        phoneSetupConfirmation = nil
        preferences.removeObject(forKey: "setup.phoneConfirmation")
    }

    private func restorePhoneSectionIfReady() {
        guard pendingPhoneRestoration,
              workspaceSection == .vm,
              selection == .setup,
              !connectionToken.isEmpty,
              isPhoneSetupComplete else { return }
        pendingPhoneRestoration = false
        workspaceSection = .phone
    }

    var candidateVMs: [VirtualMachineRecord] {
        inventory.map { record in
            if providerSetup.provider == .builtIn, record.id == nativeVM.runningVMID {
                return VirtualMachineRecord(id: record.id, name: record.name, state: .started)
            }
            return record
        }
    }

    var designatedVM: VirtualMachineRecord? {
        if let selectedVMID {
            return inventory.first { $0.id == selectedVMID }
        }
        let matches = candidateVMs
        return matches.count == 1 ? matches[0] : nil
    }

    var designatedVMIsRunning: Bool {
        if providerSetup.provider == .builtIn {
            guard let id = designatedVM?.id else { return false }
            return id == nativeVM.runningVMID
        }
        return designatedVM?.state == .started
    }

    var setupDependencies: HostSetupDependencies {
        let vm = designatedVM
        let desktopConfirmed: Bool
        if let vm {
            desktopConfirmed = nativeVM.isDesktopReady(for: vm.id)
        } else {
            desktopConfirmed = false
        }
        return HostSetupDependencies(
            vmSelected: vm != nil,
            vmRunning: designatedVMIsRunning,
            desktopConfirmed: desktopConfirmed,
            tailscaleConfirmed: vm != nil && tailscaleConfirmedVMID == vm?.id,
            backendVerified: vm != nil && ConnectionVerificationFreshness.isFresh(connectionVerifiedAt, now: now()) && verifiedForVMID == vm?.id
        )
    }

    func confirmTailscaleSetup() {
        guard setupDependencies.vmReady, let vm = designatedVM else { return }
        tailscaleConfirmedVMID = vm.id
        preferences.set(vm.id.description, forKey: "setup.tailscaleConfirmedVMID")
    }

    func clearTailscaleSetup() {
        guard let vm = designatedVM, tailscaleConfirmedVMID == vm.id else { return }
        tailscaleConfirmedVMID = nil
        preferences.removeObject(forKey: "setup.tailscaleConfirmedVMID")
        // A previous backend check cannot unlock the phone again after the
        // guest's network configuration has been changed or reconfirmed.
        connectionVerifiedAt = nil
        verifiedForVMID = nil
    }

    func selectVM(_ id: VirtualMachineID) {
        guard candidateVMs.contains(where: { $0.id == id }) else { return }
        if selectedVMID != id { clearConnectionForVMChange() }
        selectedVMID = id
        preferences.set(id.description, forKey: "setup.vmID")
        syncHostSleepAssertion()
    }

    func clearVMSelection() {
        clearConnectionForVMChange()
        selectedVMID = nil
        preferences.removeObject(forKey: "setup.vmID")
        syncHostSleepAssertion()
    }

    private func clearConnectionForVMChange() {
        resetPhoneSetup()
        connectionInputRevision += 1
        hasManualConnectionOverride = false
        hasDetectedGuestConnection = false
        lastAutomaticVerificationAt = nil
        connectionVerifiedAt = nil
        verifiedForVMID = nil
        connectionURL = ""
        connectionToken = ""
        connectionID = VirtualMachineID(rawValue: UUID())
        preferences.removeObject(forKey: "connection.id")
        preferences.removeObject(forKey: "connection.endpoint")
    }

    func setConnectionURLFromUser(_ value: String) {
        connectionInputRevision += 1
        hasManualConnectionOverride = true
        connectionURL = value
    }

    func setConnectionTokenFromUser(_ value: String) {
        connectionInputRevision += 1
        hasManualConnectionOverride = true
        connectionToken = value
    }

    func useDetectedGuestConnection() {
        connectionInputRevision += 1
        hasManualConnectionOverride = false
        lastAutomaticVerificationAt = nil
        Task { await refreshVerifiedGuestConnection() }
    }

    func refreshVerifiedGuestConnection() async {
        if connectionVerifiedAt != nil && !ConnectionVerificationFreshness.isFresh(connectionVerifiedAt, now: now()) {
            invalidateConnectionVerification()
            connectionMessage = "Connection check expired. Verifying the backend again…"
        }
        if hasManualConnectionOverride, setupDependencies.tailscaleReady,
           !isVerifyingConnection, !ConnectionVerificationFreshness.isFresh(connectionVerifiedAt, now: now()),
           ConnectionVerificationFreshness.shouldAttempt(after: lastAutomaticVerificationAt, now: now()) {
            lastAutomaticVerificationAt = now()
            await verifyConnection()
            return
        }
        guard providerSetup.provider == .builtIn,
              let vmID = designatedVM?.id,
              vmID == nativeVM.runningVMID,
              !hasManualConnectionOverride,
              !isReadingVerifiedGuestConnection,
              !isVerifyingConnection else { return }
        guard ConnectionVerificationFreshness.shouldAttempt(after: lastAutomaticVerificationAt, now: now()) else { return }
        lastAutomaticVerificationAt = now()
        let revision = connectionInputRevision
        isReadingVerifiedGuestConnection = true
        defer { isReadingVerifiedGuestConnection = false }
        do {
            let json = try await nativeVM.readVerifiedGuestConnectionJSON()
            let receipt = try GuestConnectionReceipt(json: Data(json.utf8))
            guard providerSetup.provider == .builtIn,
                  designatedVM?.id == vmID,
                  nativeVM.runningVMID == vmID,
                  connectionInputRevision == revision,
                  !hasManualConnectionOverride else { return }
            nativeVM.confirmDesktopReadyFromGuestSetup()
            confirmTailscaleSetup()
            hasDetectedGuestConnection = true
            if ConnectionVerificationFreshness.isFresh(connectionVerifiedAt, now: now()),
               verifiedForVMID == vmID,
               connectionURL == receipt.endpoint,
               connectionToken == receipt.token { return }
            connectionID = vmID
            connectionURL = receipt.endpoint
            connectionToken = receipt.token
            lastAutomaticVerificationAt = now()
            connectionMessage = "Guest details received. Verifying Hermes from this Mac…"
            await verifyConnection()
        } catch {
            // The helper may be absent until guest setup completes. Keep manual
            // entry usable and never surface raw socket data or credentials.
            if hasDetectedGuestConnection,
               designatedVM?.id == vmID,
               nativeVM.runningVMID == vmID,
               connectionInputRevision == revision {
                invalidateLiveGuestReadiness()
                connectionMessage = "Guest handoff stopped. In the VM, open the guest installer’s Verify connection step and choose Retry host handoff."
            } else if connectionURL.isEmpty && !hasManualConnectionOverride,
                      connectionMessage == "Verify the guest endpoint before connecting your phone." {
                connectionMessage = "Waiting for the guest’s final Verify connection step. If it is already complete, choose Retry host handoff in the VM."
            }
        }
    }

    func invalidateLiveGuestReadiness() {
        guard providerSetup.provider == .builtIn else { return }
        invalidateConnectionVerification()
        lastAutomaticVerificationAt = nil
        hasDetectedGuestConnection = false
        tailscaleConfirmedVMID = nil
        preferences.removeObject(forKey: "setup.tailscaleConfirmedVMID")
    }

    private func invalidateConnectionVerification() {
        connectionVerifiedAt = nil
        verifiedForVMID = nil
    }

    func syncHostSleepAssertion() {
        let running = designatedVMIsRunning
        guard running != preventsHostSleep else { return }
        if running {
            hostSleepActivity = ProcessInfo.processInfo.beginActivity(
                options: .idleSystemSleepDisabled,
                reason: "Keep the active Tether virtual machine running"
            )
        } else if let hostSleepActivity {
            ProcessInfo.processInfo.endActivity(hostSleepActivity)
            self.hostSleepActivity = nil
        }
        preventsHostSleep = running
    }

    func vmBundleURL(for record: VirtualMachineRecord) -> URL? {
        guard !isInsideGuest, inventory.contains(where: { $0.id == record.id }) else { return nil }
        return locatedVMBundles[record.id]
    }

    private func locateVMBundles(_ ids: [VirtualMachineID], provider: VMProvider) {
        bundleLookupRevision = UUID()
        let revision = bundleLookupRevision
        locatedVMBundles = [:]
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let locator = VirtualMachineBundleLocator(
            nativeRoot: support.appendingPathComponent("Tether Host for Mac/Virtual Machines")
        )
        Task { @MainActor [weak self] in
            let located = await Task.detached(priority: .utility) {
                var result: [VirtualMachineID: URL] = [:]
                for id in ids {
                    if let bundle = locator.locate(id) {
                        result[id] = bundle
                    }
                }
                return result
            }.value
            guard let self, self.bundleLookupRevision == revision,
                  self.providerSetup.provider == provider else { return }
            self.locatedVMBundles = located
        }
    }

    func revealVMInFinder(_ record: VirtualMachineRecord) {
        guard let bundle = vmBundleURL(for: record) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([bundle])
    }

    func canDeleteVM(_ record: VirtualMachineRecord) -> Bool {
        guard !isInsideGuest, !isRemovingVM, !isRefreshing,
              record.state == .stopped,
              inventory.contains(where: { $0.id == record.id }),
              vmBundleURL(for: record) != nil else { return false }
        if providerSetup.provider == .builtIn {
            return !nativeVM.isBusy && !nativeVM.isRunning && !nativeVM.hasOtherHostCopy
        }
        return true
    }

    func deleteVM(_ record: VirtualMachineRecord, from source: VMProvider) async {
        guard source == providerSetup.provider, canDeleteVM(record),
              let bundle = vmBundleURL(for: record) else {
            vmRemovalMessage = VMRemovalError.unavailable.localizedDescription
            return
        }
        isRemovingVM = true
        vmRemovalMessage = nil
        defer { isRemovingVM = false }
        do {
            try nativeVM.deleteFiles(record.id)
            guard !FileManager.default.fileExists(atPath: bundle.path) else {
                throw VMRemovalError.filesRemain(bundle)
            }
            if selectedVMID == record.id { clearVMSelection() }
            vmRemovalMessage = "Deleted \(record.name) and its VM files."
            await refresh()
        } catch {
            vmRemovalMessage = (error as? LocalizedError)?.errorDescription
                ?? "Could not delete the VM. Refresh the list and try again."
            await refresh()
        }
    }

    private func restoreConnectionToken(for id: VirtualMachineID, endpoint: String, revision: Int) async {
        // Saved credentials are restored, but verification is never restored as a success.
        guard let secret = try? await connectionVault.load(.activeHermes(id)),
              connectionInputRevision == revision,
              connectionID == id,
              connectionURL == endpoint,
              connectionToken.isEmpty else { return }
        isRestoringConnectionToken = true
        connectionToken = secret.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
        isRestoringConnectionToken = false
        restorePhoneSectionIfReady()
    }

    func startGuestSetup() {
        guard isInsideGuest else {
            guestSetupStatus = "Open this Tether Host app inside the macOS VM to install guest components."
            return
        }
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("GuestSetup"),
              FileManager.default.fileExists(atPath: folder.appendingPathComponent("Set up Tether Guest.command").path) else {
            guestSetupStatus = "The guest installer is missing from this app bundle."
            return
        }
        // User-triggered launch in the guest's Terminal so sign-in and OS approvals remain interactive.
        let command = folder.appendingPathComponent("Set up Tether Guest.command")
        if !NSWorkspace.shared.open(command) { guestSetupStatus = "Could not open the guest installer in Terminal." }
    }

    func refreshGuestStatus() {
        guard isInsideGuest else { return }
        let file = GuestSetupEnvironment.stateDirectory.appendingPathComponent("status.txt")
        if let data = try? Data(contentsOf: file), data.count < 4096,
           let text = String(data: data, encoding: .utf8) {
            guestSetupStatus = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func scanGuestDependencies() {
        guard isInsideGuest else {
            guestDependencies = []
            return
        }
        guestDependencies = GuestDependencyScanner.scan()
    }

    func importConnectionFile() {
        guard !isVerifyingConnection else { return }
        let panel = NSOpenPanel()
        panel.title = "Import Guest Connection"
        panel.message = "Choose the private connection.json generated by guest setup. The token stays masked and is verified before saving."
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let file = panel.url {
            Task { await loadConnection(from: file) }
        }
    }

    func loadGuestConnection() async {
        guard isInsideGuest else { return }
        await loadConnection(from: GuestSetupEnvironment.stateDirectory.appendingPathComponent("connection.json"))
    }

    private func loadConnection(from file: URL) async {
        guard !isVerifyingConnection else { return }
        struct GuestConnection: Decodable { let id: UUID; let endpoint: String; let token: String }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) < 16_384 else {
                throw ConnectionVerificationError.failed("Guest connection details must be a private file owned by this user.")
            }
            let details = try JSONDecoder().decode(GuestConnection.self, from: Data(contentsOf: file))
            connectionInputRevision += 1
            hasManualConnectionOverride = true
            connectionID = VirtualMachineID(rawValue: details.id)
            connectionURL = details.endpoint
            connectionToken = details.token
            await verifyConnection()
        } catch {
            connectionMessage = "Could not import connection details. Choose a valid connection.json owned by you with owner-only read/write permissions."
        }
    }

    func verifyConnection() async {
        guard !isVerifyingConnection else { return }
        if !isInsideGuest && !setupDependencies.tailscaleReady {
            connectionMessage = "Finish VM setup and Tailscale sign-in before verifying the private connection."
            return
        }
        isVerifyingConnection = true
        connectionVerifiedAt = nil
        verifiedForVMID = nil
        let endpoint = connectionURL
        let token = connectionToken
        let vmID = designatedVM?.id
        let vmProvider = providerSetup.provider
        let secretID = isInsideGuest ? connectionID : (vmID ?? connectionID)
        let revision = connectionInputRevision
        defer { isVerifyingConnection = false }
        connectionMessage = "Checking HTTPS, API authentication, durable runs, and model discovery…"
        do {
            let result = try await connectionVerifier.verify(endpoint: endpoint, token: token)
            guard revision == connectionInputRevision,
                  endpoint == connectionURL, token == connectionToken,
                  isInsideGuest || (vmProvider == providerSetup.provider && vmID == designatedVM?.id
                      && setupDependencies.tailscaleReady) else { return }
            try await connectionVault.store(SecretValue(data: Data(token.utf8)), for: .activeHermes(secretID))
            guard revision == connectionInputRevision,
                  endpoint == connectionURL, token == connectionToken,
                  isInsideGuest || (vmProvider == providerSetup.provider && vmID == designatedVM?.id
                      && setupDependencies.tailscaleReady) else { return }
            connectionID = secretID
            preferences.set(secretID.description, forKey: "connection.id")
            preferences.set(result.endpoint.url.absoluteString, forKey: "connection.endpoint")
            connectionVerifiedAt = now()
            verifiedForVMID = vmID
            connectionMessage = "Backend connection verified from this Mac. Now test the connection in Tether iOS on the same tailnet."
        } catch {
            // Do not render raw network/server errors; they can contain credentials or remote text.
            connectionMessage = (error as? ConnectionVerificationError)?.errorDescription
                ?? (error as? EndpointValidationError)?.errorDescription
                ?? "Verification failed. Check Tailscale connectivity, the URL, and the API token."
        }
    }

    func copyConnectionURL() {
        guard ConnectionVerificationFreshness.isFresh(connectionVerifiedAt, now: now()), !connectionURL.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(connectionURL, forType: .string) else { return }
        showConnectionCopyMessage("Tailscale URL copied.")
    }

    func copyConnectionToken() {
        guard ConnectionVerificationFreshness.isFresh(connectionVerifiedAt, now: now()), !connectionToken.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // Mark the credential as concealed/transient for clipboard consumers.
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        guard pasteboard.setString(connectionToken, forType: .string) else { return }
        showConnectionCopyMessage("Hermes token copied. It will clear from the clipboard in 45 seconds.")
        let count = pasteboard.changeCount
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(45))
            if pasteboard.changeCount == count { pasteboard.clearContents() }
        }
    }

    private func showConnectionCopyMessage(_ message: String) {
        connectionCopyMessage = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard self?.connectionCopyMessage == message else { return }
            self?.connectionCopyMessage = nil
        }
    }

    var securityState: HealthState { HealthAggregator.aggregate(observations).overall }
    var completedSetupCount: Int { setup.stages.count { $0.state == .completed } }
    var setupProgress: Double {
        setup.stages.isEmpty ? 0 : Double(completedSetupCount) / Double(setup.stages.count)
    }
    var duplicatedVMNames: Set<String> {
        let names = Dictionary(grouping: inventory) {
            $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        }
        return Set(names.filter { $0.value.count > 1 }.keys)
    }

    func isDuplicate(_ vm: VirtualMachineRecord) -> Bool {
        duplicatedVMNames.contains(vm.name.folding(
            options: [.caseInsensitive, .diacriticInsensitive], locale: .current
        ))
    }

    func refresh() async {
        guard !isRefreshing else { return }
        checkProviderInstallation()
        let selectedProvider = providerSetup.provider
        let wasDesignatedVMRunning = designatedVMIsRunning
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let next = try await provider.snapshot(for: selectedProvider)
            guard selectedProvider == providerSetup.provider else { return }
            observations = normalized(next.observations)
            inventory = next.inventory.map { record in
                if selectedProvider == .builtIn, record.id == nativeVM.runningVMID {
                    return VirtualMachineRecord(id: record.id, name: record.name, state: .started)
                }
                return record
            }.sorted {
                let order = $0.name.localizedStandardCompare($1.name)
                return order == .orderedSame
                    ? $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
                    : order == .orderedAscending
            }
            if wasDesignatedVMRunning && !designatedVMIsRunning {
                invalidateLiveGuestReadiness()
            }
            locateVMBundles(inventory.map(\.id), provider: selectedProvider)
            setup = next.setup
            diagnostics = next.diagnostics
            lastRefresh = Date()
            statusMessage = "Evidence refreshed. Review its source and collection time before acting."
            syncHostSleepAssertion()
            restorePhoneSectionIfReady()
        } catch {
            guard selectedProvider == providerSetup.provider else { return }
            observations = HostDashboardSnapshot.unobserved.observations
            inventory = []
            locatedVMBundles = [:]
            bundleLookupRevision = UUID()
            lastRefresh = Date()
            statusMessage = (error as? LocalizedError)?.errorDescription
                ?? "Host status is unavailable. No security claim can be made."
        }
    }

    private func normalized(_ input: [HealthObservation]) -> [HealthObservation] {
        let grouped = Dictionary(grouping: input, by: \.component)
        return HealthComponent.allCases.map { component in
            guard let values = grouped[component], values.count == 1, let value = values.first else {
                return HealthObservation(component: component, state: .unknown, summary: "Not checked", validFor: 60)
            }
            return value
        }
    }
}

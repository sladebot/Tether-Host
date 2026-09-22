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
        case .utm:
            // Recreate detection so installing UTM does not require restarting Tether.
            inventory = try await UTMCTLAdapter(executor: UTMCTLProcessExecutor()).list()
            evidenceSource = .utm
        }
        let now = Date()
        let matches = inventory
        let vmState: HealthState = matches.count == 1 ? .healthy : .degraded
        let detail: String
        if matches.count == 1 {
            detail = evidenceSource == .appleVirtualization
                ? "Tether's native Apple VM is available by exact UUID."
                : "A UTM VM is available by exact UUID."
        } else if inventory.isEmpty {
            detail = "No VM was found for the selected provider. Choose a provider in Setup Assistant."
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
    @Published var workspaceSection: HostWorkspaceSection = .vm
    @Published private(set) var observations: [HealthObservation]
    @Published private(set) var inventory: [VirtualMachineRecord]
    @Published private(set) var setup: SetupJournal
    @Published private(set) var diagnostics: [DiagnosticEntry]
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var statusMessage = "No host evidence has been collected yet."
    @Published private(set) var isRemovingVM = false
    @Published private(set) var vmRemovalMessage: String?
    @Published private(set) var preventsHostSleep = false
    private var hostSleepActivity: NSObjectProtocol?

    @Published var connectionURL = "" { didSet { connectionVerifiedAt = nil; if connectionURL != oldValue { connectionToken = "" } } }
    @Published var connectionToken = "" { didSet { connectionVerifiedAt = nil } }
    @Published private(set) var connectionVerifiedAt: Date?
    @Published private(set) var isVerifyingConnection = false
    @Published private(set) var connectionMessage = "Verify the guest endpoint before connecting your phone."
    @Published private(set) var guestSetupStatus = "Guest setup has not started."
    @Published private(set) var guestSetupDiskStatus = "No guest setup disk has been created yet."
    @Published private(set) var guestSetupDiskURL: URL?
    @Published private(set) var isExportingGuestSetupDisk = false
    @Published private(set) var guestDependencies: [GuestDependencyStatus] = []
    let isInsideGuest = GuestSetupEnvironment.isVirtualMac
    private let connectionVault = KeychainSecretStore(service: "app.tether.host.connection")
    private var connectionID = VirtualMachineID(rawValue: UUID())

    @Published private(set) var providerSetup: VMProviderSetup
    let nativeVM = NativeVMManager()
    @Published private(set) var selectedVMID: VirtualMachineID?
    @Published private(set) var utmDesktopReadyVMID: VirtualMachineID?
    @Published private(set) var tailscaleConfirmedVMID: VirtualMachineID?
    @Published private(set) var verifiedForVMID: VirtualMachineID?
    private let preferences: UserDefaults
    private let provider: any HostStatusProviding

    init(provider: any HostStatusProviding = LiveHostStatusProvider(), preferences: UserDefaults = .standard) {
        self.preferences = preferences
        selectedVMID = preferences.string(forKey: "setup.vmID").flatMap(VirtualMachineID.init)
        utmDesktopReadyVMID = preferences.string(forKey: "setup.utmDesktopReadyVMID").flatMap(VirtualMachineID.init)
        tailscaleConfirmedVMID = preferences.string(forKey: "setup.tailscaleConfirmedVMID").flatMap(VirtualMachineID.init)
        let savedProvider = preferences.string(forKey: "setup.vmProvider").flatMap(VMProvider.init(rawValue:))
        // Older releases defaulted to Apple Virtualization. Migrate that implicit
        // choice once, then preserve the user's subsequent provider selection.
        let hasUTMDefault = preferences.bool(forKey: "setup.utmDefaultApplied")
        let initialProvider: VMProvider = hasUTMDefault ? (savedProvider ?? .utm) : .utm
        if !hasUTMDefault {
            preferences.set(VMProvider.utm.rawValue, forKey: "setup.vmProvider")
            preferences.set(true, forKey: "setup.utmDefaultApplied")
            preferences.removeObject(forKey: "setup.vmID")
            selectedVMID = nil
        }
        providerSetup = VMProviderSetup(provider: initialProvider)
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
            Task { await restoreConnectionToken() }
        }
    }

    func selectProvider(_ provider: VMProvider) {
        providerSetup.select(provider)
        preferences.set(provider.rawValue, forKey: "setup.vmProvider")
        selectedVMID = nil
        preferences.removeObject(forKey: "setup.vmID")
        inventory = []
        vmRemovalMessage = nil
        observations = HostDashboardSnapshot.unobserved.observations
        checkProviderInstallation()
        syncHostSleepAssertion()
    }

    private static func availability(for provider: VMProvider) -> VMProviderAvailability {
        if provider == .utm { return UTMInstallation.detect().availability }
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
            desktopConfirmed = providerSetup.provider == .builtIn
                ? nativeVM.isDesktopReady(for: vm.id)
                : utmDesktopReadyVMID == vm.id
        } else {
            desktopConfirmed = false
        }
        return HostSetupDependencies(
            vmSelected: vm != nil,
            vmRunning: designatedVMIsRunning,
            desktopConfirmed: desktopConfirmed,
            tailscaleConfirmed: vm != nil && tailscaleConfirmedVMID == vm?.id,
            backendVerified: vm != nil && connectionVerifiedAt != nil && verifiedForVMID == vm?.id
        )
    }

    func confirmUTMDesktopReady() {
        guard providerSetup.provider == .utm, designatedVMIsRunning,
              let vm = designatedVM else { return }
        utmDesktopReadyVMID = vm.id
        preferences.set(vm.id.description, forKey: "setup.utmDesktopReadyVMID")
    }

    func clearUTMDesktopReady() {
        guard providerSetup.provider == .utm, let vm = designatedVM,
              utmDesktopReadyVMID == vm.id else { return }
        utmDesktopReadyVMID = nil
        preferences.removeObject(forKey: "setup.utmDesktopReadyVMID")
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
    }

    func selectVM(_ id: VirtualMachineID) {
        guard candidateVMs.contains(where: { $0.id == id }) else { return }
        selectedVMID = id
        preferences.set(id.description, forKey: "setup.vmID")
        syncHostSleepAssertion()
    }

    func clearVMSelection() {
        selectedVMID = nil
        preferences.removeObject(forKey: "setup.vmID")
        syncHostSleepAssertion()
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
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let locator = VirtualMachineBundleLocator(
            nativeRoot: support.appendingPathComponent("Tether Host for Mac/Virtual Machines"),
            utmRoots: [
                home.appendingPathComponent("Library/Containers/com.utmapp.UTM/Data/Documents"),
                home.appendingPathComponent("Documents/UTM"),
                support.appendingPathComponent("Tether Host for Mac/UTM Virtual Machines"),
                home.appendingPathComponent("Documents")
            ]
        )
        return locator.locate(record.id, provider: providerSetup.provider)
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
            switch source {
            case .builtIn:
                try nativeVM.deleteFiles(record.id)
            case .utm:
                try await UTMCTLAdapter(executor: UTMCTLProcessExecutor(timeout: 30)).delete(record.id)
                // UTM can unregister a shortcut without deleting its local bundle.
                // Remove only the same path if it still resolves to this UUID.
                if FileManager.default.fileExists(atPath: bundle.path) {
                    guard vmBundleURL(for: record) == bundle else {
                        throw VMRemovalError.filesRemain(bundle)
                    }
                    try FileManager.default.removeItem(at: bundle)
                }
            }
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

    func openUTM() {
        guard UTMInstallation.detect() == .installed else {
            guestSetupDiskStatus = "UTM is not installed in Applications."
            return
        }
        NSWorkspace.shared.open(UTMInstallation.applicationURL)
    }

    func exportGuestSetupDisk() {
        guard !isExportingGuestSetupDisk else { return }
        let destination = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tether Host for Mac/Tether Guest Setup.iso")
        isExportingGuestSetupDisk = true
        guestSetupDiskStatus = "Creating a read-only setup disk…"
        let appURL = Bundle.main.bundleURL
        Task {
            defer { isExportingGuestSetupDisk = false }
            do {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try await GuestSetupDiskExporter.export(appURL: appURL, to: destination)
                guestSetupDiskURL = destination
                guestSetupDiskStatus = "Guest setup disk is ready. Attach it to your VM in UTM."
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch {
                guestSetupDiskURL = nil
                guestSetupDiskStatus = (error as? LocalizedError)?.errorDescription
                    ?? "Could not create the guest setup disk."
            }
        }
    }

    func revealGuestSetupDisk() {
        guard let guestSetupDiskURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([guestSetupDiskURL])
    }

    var selectedUTMVMHasGuestSetupDisk: Bool {
        guard providerSetup.provider == .utm,
              let vm = designatedVM,
              let bundle = vmBundleURL(for: vm) else { return false }
        return FileManager.default.fileExists(
            atPath: bundle.appendingPathComponent("Data/Tether Guest Setup.iso").path
        )
    }

    private func restoreConnectionToken() async {
        // Saved credentials are restored, but verification is never restored as a success.
        guard let secret = try? await connectionVault.load(.activeHermes(connectionID)), connectionToken.isEmpty else { return }
        connectionToken = secret.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
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
        if !isInsideGuest && !setupDependencies.isUnlocked(.hermes) {
            connectionMessage = "Finish the VM and Tailscale steps before verifying Hermes."
            return
        }
        isVerifyingConnection = true
        connectionVerifiedAt = nil
        verifiedForVMID = nil
        let endpoint = connectionURL
        let token = connectionToken
        let vmID = designatedVM?.id
        defer { isVerifyingConnection = false }
        connectionMessage = "Checking HTTPS, API authentication, durable runs, and model discovery…"
        do {
            let result = try await ConnectionVerifier().verify(endpoint: endpoint, token: token)
            guard endpoint == connectionURL, token == connectionToken,
                  isInsideGuest || (vmID == designatedVM?.id && setupDependencies.isUnlocked(.hermes)) else { return }
            try await connectionVault.store(SecretValue(data: Data(token.utf8)), for: .activeHermes(connectionID))
            guard endpoint == connectionURL, token == connectionToken,
                  isInsideGuest || (vmID == designatedVM?.id && setupDependencies.isUnlocked(.hermes)) else { return }
            preferences.set(connectionID.description, forKey: "connection.id")
            preferences.set(result.endpoint.url.absoluteString, forKey: "connection.endpoint")
            connectionVerifiedAt = result.verifiedAt
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
        guard connectionVerifiedAt != nil else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(connectionURL, forType: .string)
    }

    func copyConnectionToken() {
        guard connectionVerifiedAt != nil else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // Mark the credential as concealed/transient for clipboard consumers.
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pasteboard.setString(connectionToken, forType: .string)
        let count = pasteboard.changeCount
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(45))
            if pasteboard.changeCount == count { pasteboard.clearContents() }
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
            setup = next.setup
            diagnostics = next.diagnostics
            lastRefresh = Date()
            statusMessage = "Evidence refreshed. Review its source and collection time before acting."
            syncHostSleepAssertion()
        } catch {
            guard selectedProvider == providerSetup.provider else { return }
            observations = HostDashboardSnapshot.unobserved.observations
            inventory = []
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

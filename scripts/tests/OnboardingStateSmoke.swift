import Foundation
import TetherHostCore

private struct FixtureProvider: HostStatusProviding {
    let vmID: VirtualMachineID
    func snapshot(for vmProvider: VMProvider) async throws -> HostDashboardSnapshot {
        var snapshot = HostDashboardSnapshot.unobserved
        snapshot.inventory = [VirtualMachineRecord(id: vmID, name: "Onboarding test VM", state: .stopped)]
        return snapshot
    }
}

/// Exercises the real app model with isolated preferences and synthetic inventory.
/// Never starts a VM, contacts a guest, or writes a credential.
@main
struct OnboardingStateSmoke {
    @MainActor
    static func main() async throws {
        let suite = "app.tether.tests.onboarding.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let vmID = VirtualMachineID(rawValue: UUID())
        let endpoint = "https://onboarding-test.example.ts.net"
        let confirmation = PhoneSetupConfirmation(vmID: vmID, endpoint: endpoint)!
        preferences.set(VMProvider.builtIn.rawValue, forKey: "setup.vmProvider")
        preferences.set(vmID.description, forKey: "setup.vmID")
        preferences.set(vmID.description, forKey: "setup.utmDesktopReadyVMID")
        preferences.set(vmID.description, forKey: "setup.tailscaleConfirmedVMID")
        preferences.set(try JSONEncoder().encode(confirmation), forKey: "setup.phoneConfirmation")
        preferences.set(endpoint, forKey: "connection.endpoint")
        // A unique nonexistent credential identity exercises the missing-key path.
        preferences.set(UUID().uuidString, forKey: "connection.id")

        let model = AppViewModel(provider: FixtureProvider(vmID: vmID), preferences: preferences)
        precondition(model.providerSetup.provider == .builtIn, "Upgrade lost Apple provider")
        precondition(model.selectedVMID == vmID, "Upgrade lost selected VM")
        precondition(preferences.string(forKey: "setup.utmDesktopReadyVMID") == nil && model.tailscaleConfirmedVMID == nil,
                     "Launch reused stale guest readiness")
        precondition(model.phoneSetupConfirmation == confirmation, "Hydration erased phone confirmation")
        await model.refresh()
        precondition(model.isPhoneSetupComplete, "Saved confirmation does not match restored VM")
        precondition(!model.setupDependencies.hermesReady, "Saved confirmation became live verification")

        model.resetPhoneSetup()
        model.confirmPhoneSetup()
        precondition(!model.isPhoneSetupComplete, "Offline phone confirmation was accepted")
        model.startNewVMSetup()
        precondition(model.workspaceSection == .vm && model.showsCreateVM, "Create VM did not open its sheet")
        model.showsCreateVM = false
        model.workspaceSection = .hermes
        await model.refresh()
        precondition(model.workspaceSection == .hermes, "Refresh redirected the user's navigation")

        preferences.set(try JSONEncoder().encode(confirmation), forKey: "setup.phoneConfirmation")
        let restored = AppViewModel(provider: FixtureProvider(vmID: vmID), preferences: preferences)
        await restored.refresh()
        precondition(restored.isPhoneSetupComplete, "Relaunch lost phone confirmation")
        restored.connectionToken = "test-only-not-a-real-credential"
        precondition(!restored.isPhoneSetupComplete, "Credential replacement retained phone confirmation")

        preferences.set(try JSONEncoder().encode(confirmation), forKey: "setup.phoneConfirmation")
        let changedEndpoint = AppViewModel(provider: FixtureProvider(vmID: vmID), preferences: preferences)
        await changedEndpoint.refresh()
        changedEndpoint.connectionURL = "https://different.example.ts.net"
        precondition(!changedEndpoint.isPhoneSetupComplete, "Changed endpoint retained phone confirmation")

        preferences.set(try JSONEncoder().encode(confirmation), forKey: "setup.phoneConfirmation")
        let changedVM = AppViewModel(provider: FixtureProvider(vmID: vmID), preferences: preferences)
        await changedVM.refresh()
        changedVM.selectProvider(.builtIn)
        precondition(!changedVM.isPhoneSetupComplete, "Changed VM provider retained phone confirmation")
        print("PASS: onboarding migration, stale readiness, hydration, completion gating, direct creation, navigation, credential/endpoint/provider invalidation")
    }
}

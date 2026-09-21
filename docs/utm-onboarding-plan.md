# Tether Host DMG onboarding plan

## Scope

Distribute the welcome flow in Tether Host for Mac, the app inside the DMG.
A DMG is a drag-to-Applications container; the provider wizard runs on app launch.
Offer Built-in VM (recommended) and UTM, persist the choice, and query only the
selected provider. No implicit fallback or migration-only UTM treatment in this flow.

## Welcome and prerequisites

Use native macOS system typography, accent tint, semantic backgrounds and status
colors for dark/light appearances. Approximate light palette: canvas #FFFFFF,
text #1D1D1F, secondary #6E6E73, accent #007AFF, success #248A3D, warning #B25000.
A left-aligned desktop icon and welcome heading lead to a radio-group choice,
provider requirements, download links, status, and a bottom Continue action.
Keep the layout in a scroll view so instructions remain accessible at minimum
window size. Use real labels, keyboard navigation, and visible status reasons.
This extends the native Mac utility rather than introducing a web-style theme.

1. Restore the saved provider. On a fresh preview install, prefer compatible UTM
   when present because Built-in VM remains blocked until lifecycle support ships.
2. For UTM, link to https://mac.getutm.app/ and instruct installation in Applications.
3. Link macOS image downloads to https://ipsw.me/product/Mac/ (identified as a
   third-party index), plus https://docs.getutm.app/guest-support/macos/#installation.
   Recommend UTM's automatic compatible IPSW download from its new-VM wizard.
4. Read UTM's Info.plist fresh; require the expected bundle identifier, the existing
   adapter's supported 4.7.x version family, and executable Contents/MacOS/utmctl.
5. Block Continue for missing, invalid, unsupported, or incomplete installations.
   Keep Check Again and provider switching available; no "installed" checkbox bypass.
6. Recheck on view entry, app activation, Check Again, and inside Continue.
   If availability disappears, revoke advancement and show the welcome gate again.
7. Continue opens the current setup journal. It does not mark provisioning complete.

## Files

- TetherHost/Views/SetupAssistantView.swift: welcome UI, links, activation checks.
- TetherHost/Models/VMProviderSetup.swift: provider choice and enforced advance gate.
- TetherHost/Services/UTMInstallation.swift: shared installation detector and URLs.
- TetherHost/Services/UTMCTLAdapter.swift: uses the same prerequisite detector.
- TetherHost/App/AppViewModel.swift: persistence, action recheck, selected inventory.
- TetherHost/Tests/TetherHostCoreTests/VMProviderSetupTests.swift: regression tests.

## Verification and limits

Test missing UTM, freshly installed UTM, removal after a successful check,
unsupported versions, wrong app identity, and non-executable command tools.
Test direct Continue calls and switching providers to prevent stale approval.
Build the macOS app and package a local preview DMG with an Applications shortcut.
Do not claim release signing/notarization or complete VM provisioning from this change.
A downloaded IPSW is a stock macOS installer, not Tether's provisioned guest image.
The existing 4.7.x version restriction remains until newer adapters are validated.

## Results (2026-09-20)

- Historical checkpoint: `swift test` passed 34 tests, including four
  onboarding/detection regression tests. The current suite has expanded since then.
- Xcode Debug build: succeeded for the macOS app.
- Historical UI check verified provider selection, installed UTM status,
  all three links, Check Again, and Continue opening the journal with UTM shown.
- Missing/invalid/unsupported/removal cases verified with isolated filesystem
  fixtures; the user's installed UTM was not moved or modified.
- Preview DMG output: `build/Tether-Host-for-Mac-v<version>-build-<number>-preview.dmg`.
- This preview is not Developer ID signed or notarized for public distribution.

The expanded complete-installer requirement is tracked in `complete-installer-plan.md`.

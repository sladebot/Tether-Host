# Complete Tether Host installer

The requested deliverable is a Mac DMG whose app takes a new user from provider
selection to a verified connection from Tether iOS to Hermes inside the VM.
The onboarding preview is an intermediate artifact, not completion of this goal.

## Acceptance contract

Do not show “Ready to connect” merely because UTM exists, a VM boots, or a health
endpoint returns HTTP 200. Require all of the following for the designated VM:

- A supported guest OS is installed, booted, and associated with an exact VM UUID.
- Hermes and its Python/uv, Node, and tool dependencies are installed from a
  versioned, verified release manifest; repeat setup preserves existing data.
- The user has authenticated a model provider inside the guest, and a bounded
  test inference succeeds with the selected model.
- A guest-specific random API key is generated and persisted privately. Hermes
  listens only on 127.0.0.1:8642 with bearer authentication enabled.
- The gateway is supervised in the guest and becomes available after login;
  resume and recovery behavior are tested. FileVault unlock is an explicit
  manual step after a full VM reboot.
- Tailscale is installed in the guest; the user completes sign-in and approvals.
  Guest Serve exposes private HTTPS to loopback 8642, without public Funnel.
  The iPhone is signed into the intended tailnet with permission to reach the VM.
- Computer-use dependencies run in the guest GUI session. The wizard requests
  guest Accessibility/Screen Recording permissions and verifies actual capture
  and control. Never grant host desktop access as a substitute.
- The iOS app receives the exact HTTPS endpoint and credentials through user-entered
  URL/token (the requested first handoff) or a future authenticated, expiring,
  single-use exchange, stored in origin-bound Keychain.
  Existing iOS connections and conversations are preserved. Reusable bearer
  tokens must not appear in QR codes, URLs, logs, or diagnostics.
- Phone-side verification checks DNS/TLS, authenticated durable-run capabilities,
  refusal of missing/wrong authentication, and a real completed test run.
- Chat, mini-app create/edit, app-close recovery, approval, stop, and guest CUA
  acceptance pass before claiming all Tether workflows are available.

## Installation sequence

1. Welcome: Built-in VM or UTM. Block missing/incompatible UTM and supply the
   UTM download plus macOS restore-image links (implemented in this change).
2. Guest creation/adoption: verify guest image, exact VM identity, disk ownership,
   supported host resources, and provider-specific creation. Preserve adopted VMs.
3. Guest bootstrap: authenticated transport into the correct guest; signed,
   idempotent installer; receipts written before advancing journal stages.
4. Runtime: install pinned Hermes/tool dependencies and gateway service; generate
   API key; verify loopback configuration and authenticated capabilities.
5. User actions: model login, Tailscale login, guest CUA permissions; pause on the
   specific action and recheck actual state before continuing.
6. Connectivity: private Tailscale HTTPS endpoint, endpoint/certificate validation,
   gateway readiness, guest-only tool support, no anonymous API admission.
7. Phone handoff: implement the exchange service and the missing iOS pairing
   receiver. Scan once, approve the matching host, store endpoint-bound key,
   verify from the phone, then acknowledge completion to the host.
8. Final verification: require the complete evidence set above. On partial failure,
   show the failed step and retry it without regenerating identities or credentials.
9. DMG release: embed every host/helper/guest bootstrap asset, sign with Developer
   ID, notarize and staple, then run fresh-Mac/VM/iPhone acceptance.

## Earlier gaps established before guest setup implementation

The guest-local installer and manual URL/token handoff are now implemented; see
`guest-setup-implementation.md` for current behavior, verification and limitations.
The following inventory is historical and does not describe the new guest flow.

### Original inventory

- NativeVirtualMachineStore creates metadata bundles and inventories them; it
  does not currently create bootable disks or implement VM start/stop.
- UTMCTLAdapter supports read-only list/status; VM lifecycle and guest bootstrap
  transport are not implemented.
- VirtualMachineProvisioning is a protocol with no execution implementation.
- Provisioning manifests have validation types but no published signed guest
  image/component manifest or artifact distribution is present in this repository.
- PairingPayloadBuilder formats a token-free link; the exchange service and an
  iOS onOpenURL/QR pairing receiver are absent. Manual connection currently works.
- Setup Assistant now performs VM existence and running-state checks, exports a
  read-only guest setup ISO, and runs guest-local Tailscale/Hermes inventory.
  Automatic VM lifecycle, ISO attachment, resumable stage receipts, and a live
  clean-machine end-to-end acceptance run are still pending.
- Public-release signatures/notarization and fresh-install acceptance are pending.

A bootable installer cannot be represented as finished by changing these labels
or marking journal stages complete. The existing manually configured sandbox is
useful acceptance evidence, but is not proof of reproducible installation.

## OS direction

The implemented guest installer targets macOS for both providers. UTM users
create a macOS guest; the native macOS VM lifecycle remains to be implemented.
The older Linux-image direction is not used by this guest installer.

## References

- https://docs.getutm.app/guest-support/macos/
- https://hermes-agent.nousresearch.com/docs/getting-started/installation/
- https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server/
- https://hermes-agent.nousresearch.com/docs/user-guide/features/computer-use/
- https://tailscale.com/docs/reference/tailscale-cli

## Deliverable paths

- Plan: docs/complete-installer-plan.md
- Onboarding implementation: TetherHost/Views/SetupAssistantView.swift
- Intermediate DMG: build/Tether-Host-Guest-Setup-Preview.dmg

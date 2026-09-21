# Tether Host for Mac entitlements and approvals

The committed entitlement files use separate least-privilege baselines:

- `Config/TetherHost.entitlements`
- `Config/TetherHostNetworkHelper.entitlements`

The host app has only `com.apple.security.virtualization`, which is required to
run a VM with Apple's Virtualization framework. The future network helper file
remains empty. Hardened runtime is a code-signing option and Xcode build setting,
not an entitlement key. Regular per-app Keychain storage also needs no
entitlement.

## Host application

The primary host path manages its application-owned VM through
`Virtualization.framework`; users do not install UTM. The compatibility adapter
may inspect an existing UTM installation through `utmctl`, using absolute
executable resolution, fixed argument arrays, exact VM identity matching,
bounded output, and no shell interpolation. That path needs no Apple Events
entitlement. If a future migration release requires UTM AppleScript, add
`com.apple.security.automation.apple-events` only after the implementation and
usage description are reviewed. It creates a visible Automation consent prompt
and must be scoped to UTM. Do not add temporary Apple Events exception
entitlements as a shortcut.

The Developer ID build is currently outside the Mac App Store. Enabling App
Sandbox without a complete design for UTM automation, XPC, file selection, and
updates can break the product; disabling it also means entitlements are not the
primary containment boundary. The host app still runs as the logged-in user and
must keep secrets in Keychain, validate all untrusted VM output, and talk to the
root helper only through a narrow authenticated XPC protocol.

Do not add these Release entitlements unless a concrete reviewed feature cannot
work without one:

| Entitlement | Reason to keep absent |
| --- | --- |
| `com.apple.security.get-task-allow` | Allows debugger attachment and is incompatible with a production trust model. |
| `com.apple.security.cs.disable-library-validation` | Permits untrusted or other-team libraries in the process. |
| `com.apple.security.cs.allow-unsigned-executable-memory` | Weakens hardened runtime code integrity. |
| `com.apple.security.cs.allow-jit` | Tether Host for Mac has no planned JIT workload. |
| Broad file, camera, microphone, USB, screen capture | Outside host-app responsibilities and the isolation goal. |
| Keychain access groups | Unnecessary while only the GUI owns host-side credentials. |

If the app later uses an app group or shared Keychain access group, the Developer
ID provisioning/capability setup, Team ID prefix, and every participant must be
reviewed together. The privileged helper should not receive the Hermes bearer
token merely to simplify sharing.

## Privileged network helper

`SMAppService` does not itself require a broad privileged entitlement. Privilege
comes from launchd installing/running the signed daemon as root after the macOS
authorization flow. Keep the helper entitlement file empty unless a specific
Apple framework documents a required capability.

The helper must:

- ship inside the signed app with a launch daemon property list at the path
  required by `SMAppService`;
- use a stable helper identifier and a code signature from the same Developer
  Team as the host app;
- authenticate every connecting process from its audit token and designated
  code requirement, and have the app validate the helper endpoint as well;
- expose only typed operations over XPC and derive owned paths, interfaces,
  addresses, and policy text from root-owned validated state;
- reject arbitrary commands, paths, rule text, VM names, interface names, and
  addresses received from the GUI;
- use ownership receipts, atomic installation, validation, rollback, boot-time
  reconciliation, and scoped removal for Tether-owned policy only;
- omit network credentials, tokens, headers, and sensitive paths from logs.

A matching Team ID is necessary but not sufficient for XPC trust. The code
requirement should also constrain the intended signing anchor and bundle
identifier. Development/ad-hoc identities must never satisfy the Release helper's
production requirement.

## Approval inventory

| Approval | Location | Why it is required | Security consequence |
| --- | --- | --- | --- |
| Helper/background item authorization | Host macOS | Registers the signed root network-policy daemon | Grants a narrowly implemented component root authority; a flaw can affect host networking. |
| Tailscale VPN/network extension and login | Guest macOS | Joins the guest to the user's tailnet | Gives the guest the tailnet reachability allowed by account policy. Funnel remains forbidden. |
| Accessibility | Guest macOS | Allows CUA to drive the guest UI | CUA can control the guest desktop session. It must have no path to the host desktop. |
| Screen Recording | Guest macOS | Allows CUA to observe the guest display | CUA can capture guest display contents, which may contain user data. |
| Provider login | Guest or user-owned browser flow | Authorizes model/provider access | Grants provider-specific account and data access. Store resulting credentials only in the intended guest store. |
| Automation, only if AppleScript migration is adopted | Host macOS | Lets Tether Host for Mac send Apple Events to UTM | Applies only to optional migration; avoid by preferring `utmctl`. |

Tailscale account ACLs/grants are account-side controls. The app may generate and
validate a proposed scoped policy, but it cannot silently approve or broaden the
tailnet. macOS privacy approvals similarly cannot be bypassed in an ordinary
installer. Setup must show pending, denied, and approved as distinct states and
must never report isolation healthy merely because a prompt appeared.

Any entitlement addition changes the attack surface and the notarized signature.
Update this document, the target-specific file, signing tests, threat model, and
fresh-Mac approval expectations in the same reviewed change.

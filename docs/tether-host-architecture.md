# Tether Host architecture

Updated 2026-10-01. This describes the current Apple-only application. Earlier
migration and isolation investigations in this directory are historical evidence,
not supported runtime options or proof of deployed protection.

## Runtime and ownership

Tether Host owns macOS VMs through Apple's `Virtualization.framework`. The host
app creates a fresh hardware identity, installs a compatible IPSW, and stores the
VM disk and manifest in its application-support directory under an immutable UUID.
The display is embedded in the host workspace. VM operations are serialized before
asynchronous work begins; deletion requires a stopped VM and exact confirmation.

There is no third-party VM provider, command-line adapter, package conversion,
registration, or migration action. Obsolete provider preferences are reconciled
without opening or deleting previously managed external VM packages. Historical
user disks remain the user's property.

The `TetherHostCore` package contains identity, inventory, lifecycle coordination,
media generation, verification, and security-policy value types. The SwiftUI app
owns presentation and the live Virtualization objects. Guest provisioning runs
only in the separate macOS guest; host-installed agent tools never satisfy guest
dependency checks.

## Guest provisioning and credentials

A read-only setup image contains the guest installer and its signed clipboard /
connection helper. Installer media is generated atomically so failed replacement
does not remove a usable previous image. The installer verifies guest networking,
Tailscale identity and Serve configuration, loopback bearer authentication, durable
run capabilities, computer-use permission and full-screen capture, and a real
model response. Pending model checks retain their admission identity; terminal
unsuccessful checks can be retried as a new deliberate attempt.

The guest sends its connection receipt over a private VM socket. That receipt is
untrusted input: the host independently validates the HTTPS endpoint, missing and
incorrect token rejection, capabilities, and available models. Verification expires
and must be refreshed even when the receipt's endpoint and token are unchanged.
The host stores accepted credentials in Keychain. Clipboard transfer is explicit;
there is no automatic host-folder sharing or clipboard synchronization.

## Network boundary and remaining containment work

Internet mode uses `VZNATNetworkDeviceAttachment`. NAT does not enforce a
host/LAN/tailnet destination deny policy. A private phone connection, a guest-only
filesystem, and successful API authentication are separate properties and cannot
certify network containment. The policy generators and audit scripts are offline
research tools; no privileged networking service is installed by this app.

Offline mode provides a VM with no network device. It is useful for disconnected
work but cannot support Tailscale, model access, or phone connectivity. The network choice persists across app launches and applies to subsequent VM
starts. Selecting Internet mode provides ordinary NAT connectivity, not
approved-service containment.

The following remain prerequisites for a production containment claim:

- A host-controlled network attachment or independently enforced gateway covering
  both IPv4 and IPv6, source spoofing, alternate routes, and existing sessions.
- An explicit service policy derived from the actual guest clients, with trusted
  DNS resolution and no arbitrary proxy or transport bypass.
- Enforced startup ordering, failure behavior, update/rollback, and policy drift
  handling. A polling script or guest-admin-editable firewall is insufficient.
- Fresh negative probes for host, LAN, tailnet, and public host endpoints alongside
  successful phone/model connectivity. Test guest-root behavior under the claimed
  threat model.

Do not install the environment-specific PF examples as a generic fix. They contain
historical topology assumptions and are not wired into VM startup.

## Verification and release

`bash scripts/verify.sh` runs Python and Swift tests, guest helper checks, Debug and
Release builds, and ad-hoc nested-signature/hardened-runtime validation. It does not
boot a VM, exercise OS permission prompts, install host policy, or contact a phone.
Developer ID export, secure timestamps, notarization, and clean-machine acceptance
are additional release checks. See [verification](tether-host-verification.md) and
[distribution](tether-host-distribution.md).

Apple references: [NAT attachment](https://developer.apple.com/documentation/virtualization/vznatnetworkdeviceattachment),
[custom packet attachment](https://developer.apple.com/documentation/virtualization/vzfilehandlenetworkdeviceattachment),
[vmnet attachment](https://developer.apple.com/documentation/virtualization/vzvmnetnetworkdeviceattachment).

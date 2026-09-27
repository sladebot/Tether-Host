# Tether Host architecture

Tether Host runs on the physical Mac and owns a macOS guest created with Apple’s `Virtualization.framework`. The guest contains Tailscale, Hermes, model credentials, and computer-use permissions. Tether Flow on iPhone connects to Hermes over private tailnet HTTPS.

## Components

```text
Tether Flow on iPhone
        │ private Tailscale HTTPS
        ▼
macOS guest: Tailscale → Hermes → CUA
        │ explicit VM sockets and Apple NAT
        ▼
Tether Host on the physical Mac
```

- **Tether Host** creates, stores, boots, displays, and deletes application-owned VM bundles by exact UUID.
- **Tether Guest Installer** runs from a read-only disk attached by the host. It configures only the guest.
- **Hermes** listens on guest loopback. Tailscale Serve exposes the authenticated endpoint to the tailnet; Funnel must remain disabled.
- **Tether Flow** performs its own phone-side connection test before saving the profile.

Tether Host has no UTM integration or runtime dependency. Inventory refreshes read only the app-owned Apple Virtualization store, so background polling cannot launch another virtualization app.

## Trust boundaries

- Physical-host installations never satisfy guest dependency checks.
- The guest receives no shared host folders and no automatic clipboard synchronization.
- Clipboard transfer is explicit, text-only, size-bounded, and initiated by the user.
- Guest URL and token handoff uses a private VM socket after the guest completes verification.
- The host stores the verified token in Keychain and clears transient clipboard copies after 45 seconds when unchanged.
- VM removal requires a stopped VM, an exact manifest UUID match, and typed confirmation of the final eight UUID characters.
- Accessibility and Screen Recording approvals are granted interactively inside the guest.

## VM storage and identity

VM bundles live under the app’s Application Support directory. Each bundle directory is named with its UUID and contains a signed-format manifest whose UUID must match the directory. Display names are never used as filesystem identity.

The VM uses Apple NAT for outbound networking. Network isolation claims require independent host-side evidence; a booted VM or successful guest request is not proof of containment.

## Connection readiness

The iPhone step unlocks only after:

1. The exact VM is selected and running.
2. The macOS desktop is confirmed ready.
3. Tailscale is confirmed inside that guest.
4. Hermes authentication, required capabilities, model discovery, and a bounded model run verify from the host.

A saved credential does not restore a past readiness result. The connection is verified again after relevant VM or network state changes.

# Tether Host for Mac

Tether Host for Mac is the macOS companion for the Tether iOS app. Its first-launch
Setup Assistant defaults to UTM and also offers Apple Virtualization. Both paths
accept a compatible macOS IPSW and install a fresh VM in Tether Host. For UTM,
the app creates a UTM Apple-backend package, registers it in UTM, and removes
the original installer bundle only after UTM reports the exact VM UUID. The
Apple Virtualization path keeps the VM in Tether Host and renders its display
inline. The **Virtual Machines** page can switch between Apple Virtualization
and UTM inventories and reveal
an exact local VM bundle in Finder. For built-in VMs, the bundle's Finder
modified date is updated when Tether Host starts or stops the VM.
Existing built-in VMs with the same saved name are distinguished by their UUID
prefix in the inventory, and new VMs receive a unique name when created.
The **Virtual Machines** page has a **Create New VM** button that opens creation
for the selected provider. The Apple Virtualization section can also move a
stopped Tether-created VM into UTM, preserving its exact identity and disk.
Choose an IPSW or use the in-app macOS download before creating a new VM.
The built-in VM has a Virtio network adapter attached to Apple's NAT, which
routes guest traffic through the Mac's network connection. Guest internet
reachability still needs a check inside macOS after first-run setup.
The setup guide waits for the user to finish Apple's macOS account screens in
that window. **Desktop is ready — Continue** returns to the guide without
stopping the VM, and **Show VM** reopens it for guest setup.
The IPSW must not require a newer macOS host; the app rejects a macOS 27 IPSW
on a macOS 26 host before creating a disk. Apple's installer also reported a
required host software update for that combination in local testing. On a
macOS 26.2 host, setup can download Apple's macOS 26.2 IPSW in-app and verify
its pinned SHA-256 digest before installation.
The UTM path requires a compatible installation in `/Applications/UTM.app`.

The welcome screen links to the official UTM download, a macOS IPSW download
index, and UTM's macOS setup guide. UTM can download a compatible restore image
automatically. Continue is blocked until the selected provider is available;
the app checks again on return, on Check Again, and inside the Continue action.
This build retains the existing UTM 4.7.x compatibility restriction.

After provider selection, the app follows four checks: find the exact VM, verify
that it reaches the running state, check/configure Tailscale inside the guest,
and check/configure Hermes inside the guest. The physical Mac is used only for
the provider and VM-state checks. Guest dependency detection never uses host
Hermes, Tailscale, or developer tools.

The app creates a read-only `Tether Guest Setup.iso` containing only a small
guest helper, without shared host folders or clipboard. Inside the macOS guest,
double-click **Tether Guest Installer.app** on that disk and click Start setup; no second Tether Host
installation is needed. The helper first checks real guest HTTPS access through
the host's NAT, then checks Tailscale, verifies its publisher signature, and
guides sign-in when needed.
It then installs the pinned Hermes runtime when absent or configures a working
existing guest installation, enables loopback bearer authentication, prompts for
model login and guest permissions, starts the gateway, configures private HTTPS,
and verifies a real model response. It refuses to run on the physical host.

The helper displays the verified URL/token in its guest Terminal for entry in
Tether iOS. The host connection screen also offers **Import Guest Connection…** for a private, user-owned
`connection.json`, accepts an existing endpoint manually, checks TLS and
API authentication/capabilities, stores the credential in Keychain, and provides
masked reveal/copy controls for use in Tether iOS. The phone still needs Tailscale
and its own Test Connection check. A host-side check does not certify phone reachability.

For the built-in VM, Tether Host creates a read-only guest setup disk and
refreshes and attaches it at every boot. New UTM VMs created by Tether Host
include that disk automatically; an existing UTM VM needs it attached once.
UTM's public command-line interface does not create a macOS VM
from an IPSW, so Tether Host installs macOS before creating the UTM package.
The development DMG is
not a notarized production installer, and the new guest installation flow has not
yet passed a clean-VM, real-phone end-to-end run. See `docs/guest-setup-implementation.md`.

## Build the app

Open `TetherHost.xcodeproj`, select the `Tether Host for Mac` scheme, and build
for My Mac. The deployment target is macOS 14 and the bundle identifier is
`app.tether.host`.

Build the ad-hoc signed development DMG with `./scripts/build-preview.sh`.
The output filename includes the app marketing version and build number, for
example `build/Tether-Host-for-Mac-v1.0.0-build-19-preview.dmg`, with a matching
`.sha256` checksum file. Bump `MARKETING_VERSION` for a product release and
`CURRENT_PROJECT_VERSION` for every distributed build. The script verifies the
app signature and DMG checksum; this is not a notarized public release.
See `docs/mac-studio-install-test.md` for the installed-app test results.

On the host, setup uses a two-column workspace. The selected dependency and
its controls stay on the left; the built-in VM display, power state, and
controls stay on the right as you move between steps. The order is VM desktop,
Tailscale sign-in, Hermes verification, then iPhone connection. Later steps
stay locked until the preceding state is ready. Tailscale sign-in and first
desktop readiness are explicitly confirmed by the user because the host does
not inspect the guest before its helper is installed. The guest helper still
checks Tailscale inside the VM before configuring Hermes. For UTM VMs,
Tether shows its power state, but UTM owns its live display window.
The built-in VM has a graceful Shut Down control and, if the guest does not
respond, a separately confirmed Force Power Off control that warns about
unsaved work.

The Virtual Machines page can permanently delete a stopped VM and its local
files. It shows the exact VM UUID and requires its last eight characters before
deletion. Tether Host deletes its built-in VM bundle directly; for a UTM VM it
uses UTM's deletion command and removes the exact local bundle if UTM leaves
it behind.
The action is unavailable when the VM is running or its bundle cannot be
matched by UUID. Deletion cannot be undone and does not move files to Trash.
The shared macOS restore image is retained for creating another VM.

## Test the core

```sh
cd TetherHost
swift test
```

## Architecture and release

- `docs/tether-host-architecture.md` defines the trust boundaries and phases.
- `docs/tether-host-verification.md` records verified behavior and remaining gates.
- `docs/tether-host-distribution.md` describes Developer ID and notarization.
- `scripts/release/` contains the fail-closed release pipeline scaffold.

This repository was extracted from the Tether iOS repository at source commit
`4f27ab1`. Phone UI, chat, mini-app, and mobile Keychain code remain in the iOS
repository.

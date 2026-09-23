# Tether Host for Mac

## Guided onboarding

Setup keeps the current task in focus: prepare a VM, connect its private network,
verify the assistant, and connect an iPhone. Provider choices, existing VM
management, and manual connection entry are available in contextual details.
The running VM stays visible beside setup instructions. Health and diagnostics
are secondary tools.
After the VM desktop, private network, and assistant connection are currently
verified and iPhone setup is confirmed, the built-in VM uses the full workspace.
Starting the VM alone keeps setup visible. A saved phone confirmation does not
replace those live checks. The panel can also be closed or reopened manually
from the VM toolbar at any stage while the VM is running.
Opening the VM from the completion screen also closes the setup panel; stopping
the VM restores setup and recovery controls.

Setup pages remain readable when the VM stops. Live checks must pass again before
connection verification or phone completion is available. After a successful
**Test Connection** on the phone, **I tested the connection on my iPhone** records the user's
confirmation for that VM and endpoint; it does not claim ongoing phone reachability.
Previously selected UTM VMs survive upgrades, while desktop and network checks
are repeated when the host app relaunches.

## VM setup

Tether Host for Mac is the macOS companion for the Tether iOS app. Its first-launch
Setup Assistant defaults to built-in Apple Virtualization and also offers UTM. Both paths
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
required host software update for that combination in local testing.
**Download macOS** is available throughout built-in VM creation on supported Macs.
The first setup step includes a macOS version picker. It defaults to the newest
available image matching the host release and not exceeding its full version.
Users can choose an older available release instead (macOS 14 or newer).
VM creation follows **Choose macOS → Configure your VM → Create**. After selecting
an installation image, a dedicated configuration screen lets users enter memory,
CPU cores, and disk capacity, with host-aware defaults and a reset button. Back
preserves the settings. These are saved per VM for later starts and UTM export. Existing VMs retain
their previous defaults. **Create another VM** remains available with existing VMs,
including while one is running. Installation leaves the running VM untouched and
saves the new VM for a later start. Disk capacity is a growing sparse disk limit, not an
immediate reservation of that much host space. Images
newer than the host are excluded by Tether's conservative selection policy. Historical versions are discovered
through ipsw.me metadata; image downloads and redirects are restricted to Apple HTTPS
servers. Published SHA-256 digests are checked when available, and the downloaded
image's compatibility, version, and build are verified before caching. Apple's current
image discovery and the pinned 26.2 image provide fallback candidates. If discovery
fails or no matching image exists, setup explains the issue and retains manual IPSW
selection. Downloads need about 65 GB free for the image and a fresh VM.
The UTM path requires a compatible installation in `/Applications/UTM.app`.

## Install the latest preview

Download the newest versioned DMG from [GitHub Releases](https://github.com/sladebot/Tether-Host/releases),
open it, and drag **Tether Host for Mac** to Applications. Preview builds are
ad-hoc signed and are not notarized production releases; macOS may ask you to
confirm the first launch. Keep only one installed copy so VM state and privacy
permissions stay attached to the expected app.

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

The app creates a read-only `Tether Guest Setup.iso` containing a small
guest helper, without shared host folders or automatic clipboard synchronization.
Inside the macOS guest, double-click **Tether Guest Installer.app** on that disk
and follow its six-step guide. Users do not need to install Tether Host in the
VM or run a separate manual Hermes setup. The helper first checks real guest HTTPS access through
the host's NAT, then checks Tailscale, verifies its publisher signature, and
guides sign-in when needed.
It then installs the pinned Hermes runtime when absent or configures a working
existing guest installation, enables loopback bearer authentication, prompts for
model login and guest permissions, starts the gateway, configures private HTTPS,
and verifies a real model response. It refuses to run on the physical host.
The computer-use step installs CuaDriver, requests Accessibility and Screen &
System Audio Recording inside the VM, and tells the user to click **Allow** when
macOS asks whether CuaDriver may bypass the private window picker. The step does
not complete until direct guest-screen capture and Accessibility control both
pass. macOS requires this one-time interactive consent; Tether Host cannot grant
it silently.

The helper displays the verified URL/token in its embedded setup console for entry in
Tether iOS. For a built-in VM, the completed guest verification also releases
those details over a private VM socket. Tether Host fills the URL and masked token,
confirms live guest Tailscale status, and verifies Hermes from the Mac before
unblocking the phone step. The host connection screen retains **Import Guest Connection…**
for a private, user-owned `connection.json`, accepts an existing endpoint manually, checks TLS and
API authentication/capabilities, stores the credential in Keychain, and provides
separate **Copy Tailscale URL** and **Copy Hermes Token** controls beside the
verified values for use in Tether iOS. The token stays masked in the UI, is marked
as concealed/transient on the macOS clipboard, and clears after 45 seconds when
unchanged. The phone still needs Tailscale
and its own Test Connection check. A host-side check does not certify phone reachability.
If the guest helper cannot start, the guest Verify step keeps the connection
verified but shows **Retry host handoff**. The same action can restart the helper
after a later failure without reinstalling macOS, Tailscale, or Hermes.

For the built-in VM, Tether Host creates a read-only guest setup disk and
refreshes and attaches it at every boot. Updating Tether Host refreshes the
guest installer on the VM's next boot without reinstalling macOS or removing
its installed apps. New UTM VMs created by Tether Host
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

On the host, setup uses a focused workspace with an optional VM display. The
selected task stays on the left when the display is shown; connection and
management pages can use the space when it is hidden. Tailscale and Hermes
setup both become available after the VM desktop is ready; the iPhone step
waits for the verified private connection. Tailscale sign-in and first
desktop readiness are explicitly confirmed by the user because the host does
not inspect the guest before its helper is installed. Inside the guest, Hermes
installation and configuration only require Internet; Tailscale is required
when verifying the final private connection. For UTM VMs,
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

# Tether Host for Mac

Tether Host prepares an isolated macOS guest for [Tether Flow on iPhone](https://github.com/sladebot/Tether). It manages the VM, installs and verifies guest-only Tailscale and Hermes services, and hands the phone a private connection without exposing the physical Mac's agent environment.

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
preserves the settings. The configuration step also offers a folder picker for
internal or external VM storage. New disk capacities start at 24 GB; capacities
below 64 GB may not leave enough space for installation and updates. The selected
resources and location are saved per VM for later starts and UTM export. Existing VMs retain
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
selection. The macOS download cache stays on this Mac and requires 25 GB free.
Installation checks free space on the selected VM volume separately; the required
amount depends on the virtual disk capacity and filesystem. Keep external storage
connected while its VM is running.
The UTM path requires a compatible installation in `/Applications/UTM.app`.

[Download the latest preview](https://github.com/sladebot/Tether-Host/releases)

## Screenshots

### Guided host workspace

![Tether Host workspace with guided VM setup and an embedded macOS guest](./screenshots/host-workspace.png)

## Overview

Tether Host supports two VM providers:

- **Built-in Apple Virtualization:** creates and runs a Tether-owned macOS VM with its display embedded in the host workspace.
- **UTM:** creates an Apple-backend VM package, registers it by exact UUID, and lets UTM own the live display.

Both paths use a compatible macOS IPSW. The built-in path can download a supported restore image and verify its pinned SHA-256 digest before installation. The current UTM path supports the tested UTM 4.7.x line.

After macOS setup, Tether Host attaches a read-only **Tether Guest Setup** disk. Its six-step guest installer:

1. Verifies real guest internet access.
2. Installs or validates Tailscale and guides sign-in.
3. Installs the pinned Hermes runtime when needed, or preserves a compatible existing installation.
4. Configures loopback-only bearer-authenticated Hermes API access.
5. Installs CuaDriver and verifies Accessibility plus direct full-screen capture inside the guest.
6. Configures private Tailscale HTTPS and verifies capabilities, authentication, computer use, and a real model response.

## Host and guest responsibilities

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

| Component | Responsibility |
| --- | --- |
| Tether Host | VM creation, exact VM identity, lifecycle controls, guest setup media, host-side connection verification |
| macOS guest | Tailscale identity, Hermes runtime, model login, computer-use permissions, durable agent execution |
| Tether Flow | Phone-side connection test, origin-bound Keychain credential, chat, approvals, and mini apps |

For built-in VMs, the verified guest sends its private URL and token to Tether Host through a private VM socket. Tether Host fills the connection screen, confirms guest Tailscale status, verifies Hermes from the Mac, and stores the token in Keychain. UTM guests can use private file import or manual entry.

## Security model

- Guest dependency checks never use Hermes, Tailscale, or developer tools from the physical Mac.
- Hermes listens on guest loopback at `127.0.0.1:8642`; Tailscale Serve provides tailnet-only HTTPS and Funnel must remain disabled.
- The setup disk is read-only. There are no shared host folders or automatic clipboard synchronization.
- Connection tokens remain masked, are marked concealed/transient when explicitly copied, and clear from the clipboard after 45 seconds if unchanged.
- CuaDriver permissions must be granted interactively inside the guest; Tether Host cannot silently grant macOS privacy access.
- A host-side connection check does not prove phone reachability. Tether Flow performs its own **Test Connection** from the iPhone.
- Destructive VM removal is limited to a stopped, exactly matched UUID and requires typing its final eight characters.

## Current status

The current preview is version 1.0.0, build 48. It is ad-hoc signed and is not a notarized production release, so macOS may request confirmation on first launch. The new guest installation flow has not yet completed a clean-VM, physical-phone end-to-end acceptance run.

Deployment target: macOS 14 or newer. Bundle identifier: `app.tether.host`.

## Documentation

- [Architecture and trust boundaries](docs/tether-host-architecture.md)
- [Guest setup implementation](docs/guest-setup-implementation.md)
- [Verification status](docs/tether-host-verification.md)
- [Distribution and notarization](docs/tether-host-distribution.md)
- [Mac Studio installation tests](docs/mac-studio-install-test.md)

This repository was extracted from the Tether iOS repository at source commit `4f27ab1`. Phone UI, chat, mini-app, and mobile Keychain code remain in [sladebot/Tether](https://github.com/sladebot/Tether).

## Instructions

### Install the latest preview

1. Open [GitHub Releases](https://github.com/sladebot/Tether-Host/releases).
2. Download the newest versioned DMG and its matching `.sha256` file.
3. Verify the download from the directory containing both files:

   ```sh
   shasum -a 256 -c Tether-Host-for-Mac-v1.0.0-build-48-preview.dmg.sha256
   ```

4. Open the DMG and drag **Tether Host for Mac** to Applications.
5. Keep only one installed copy so VM state and privacy permissions stay associated with the expected app.

### Create the macOS guest

1. Open Tether Host and choose **Built-in Apple** or **UTM**.
2. Choose a compatible macOS IPSW or use the in-app restore-image download.
3. Create the VM and complete Apple's macOS welcome and account screens.
4. Return to Tether Host and choose **Desktop is ready — Continue**.

For UTM, install the supported app at `/Applications/UTM.app`. Tether Host installs macOS before creating and registering the UTM package because UTM's public command-line interface does not create a macOS VM directly from an IPSW.

### Install guest services

1. Start the VM. Tether Host refreshes and attaches `Tether Guest Setup.iso` at boot.
2. Inside the guest, open the setup disk and launch **Tether Guest Installer.app**. Do not install a second copy of Tether Host in the VM.
3. Follow the installer through internet, Tailscale, Hermes, model login, and computer-use setup.
4. When macOS asks whether CuaDriver may bypass the private window picker and directly access the guest screen and audio, choose **Allow**.
5. Complete **Verify connection**. The installer must pass private HTTPS, authentication, durable-run capability, direct screen capture, and a real model response.

### Connect Tether Flow on iPhone

1. Keep the guest VM running and join the same tailnet on the iPhone.
2. In Tether Host, open **Connect iPhone** and verify the guest connection.
3. Copy the **Tailscale URL** and **Hermes Token**.
4. In Tether Flow, add a **Hermes API Server** connection with those values.
5. Tap **Test Connection** on the phone, then save the profile.

### Build from source

Open `TetherHost.xcodeproj`, select the `Tether Host for Mac` scheme, and build for **My Mac**.

Run the core tests:

```sh
cd TetherHost
swift test
```

Build an ad-hoc signed preview DMG and checksum:

```sh
./scripts/build-preview.sh
```

Increment `CURRENT_PROJECT_VERSION` for every distributed build and `MARKETING_VERSION` for product releases. The preview script verifies the app signature and DMG checksum; the Developer ID and notarization pipeline is documented separately.

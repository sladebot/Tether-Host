# Tether Host for Mac

Tether Host is the macOS companion for [Tether Flow on iPhone](https://github.com/sladebot/Tether). It creates and manages a private macOS virtual machine, prepares the guest services, and verifies the phone connection without using the physical Mac’s agent environment.

![Tether Host workspace with guided VM setup and an embedded macOS guest](./screenshots/host-workspace.png)

[Download the latest preview](https://github.com/sladebot/Tether-Host/releases/tag/v1.0.0-build.77-preview)

## What it does

- Creates and runs macOS guests with Apple Virtualization.
- Downloads a compatible Apple restore image or accepts a local IPSW.
- Supports multiple VMs, configurable CPU, memory, disk capacity, and external storage.
- Displays the running guest beside the guided setup.
- Attaches a read-only guest setup disk for Tailscale, Hermes, model login, and computer-use configuration.
- Receives the verified guest URL and token through a private VM socket and stores the token in Keychain.
- Requires exact VM identity and explicit confirmation before permanent deletion.

## Setup flow

1. Create or select a VM and finish the macOS welcome screens.
2. Open **Tether Guest Installer** inside the VM.
3. Join Tailscale and configure Hermes in the guest.
4. Verify the private connection from the Mac.
5. Test the connection in Tether Flow on the iPhone.

The physical Mac’s Hermes, Tailscale, and developer tools never satisfy guest dependency checks. The VM display, lifecycle, storage, and inventory are managed directly by Tether Host.

## Requirements

- Apple silicon Mac
- macOS 14 or newer
- A compatible macOS IPSW, or enough free space to download one
- Tether Flow on an iPhone connected to the same tailnet

The current preview is version 1.0.0, build 77. It is ad-hoc signed and not notarized, so macOS may ask for confirmation on first launch.

## Project layout

| Path | Purpose |
| --- | --- |
| `TetherHost/App` | App state and Apple Virtualization lifecycle |
| `TetherHost/Models` | VM, health, setup, and connection models |
| `TetherHost/Services` | VM storage, verification, Keychain, and guest media |
| `TetherHost/Views` | Setup workspace, embedded display, inventory, and diagnostics |
| `scripts/guest` | Guest installer and helper resources |
| `scripts/build-preview.sh` | Ad-hoc preview DMG build |

## Documentation

- [Architecture and trust boundaries](docs/tether-host-architecture.md)
- [Guest setup implementation](docs/guest-setup-implementation.md)
- [Verification status](docs/tether-host-verification.md)
- [Distribution and notarization](docs/tether-host-distribution.md)
- [Entitlements](docs/tether-host-entitlements.md)

This repository was extracted from the Tether iOS repository at source commit `4f27ab1`. Phone UI, chat, mini-app, and mobile Keychain code remain in [sladebot/Tether](https://github.com/sladebot/Tether).

## Instructions

### Install the latest preview

1. Open the [build 77 release](https://github.com/sladebot/Tether-Host/releases/tag/v1.0.0-build.77-preview).
2. Download `Tether-Host-for-Mac-v1.0.0-build-77-preview.dmg` and its matching `.sha256` file.
3. Verify the download from the directory containing both files:

   ```sh
   shasum -a 256 -c Tether-Host-for-Mac-v1.0.0-build-77-preview.dmg.sha256
   ```

4. Open the DMG and drag **Tether Host for Mac** to Applications.
5. Keep one installed copy so VM state and privacy permissions remain associated with the expected app.

### Create the macOS guest

1. Open Tether Host and choose **Create a VM**.
2. Download a supported macOS image or choose a compatible local IPSW.
3. Choose CPU, memory, disk capacity, and storage location.
4. Create the VM and complete Apple’s macOS welcome and account screens.
5. Return to Tether Host and choose **Desktop is ready**.

### Install guest services

1. In the running VM, open **Tether Guest Setup**, then launch **Tether Guest Installer.app**.
2. Follow the installer through internet, Tailscale, Hermes, model login, and computer-use setup.
3. Grant CuaDriver’s requested Accessibility and screen-capture permissions inside the guest.
4. Complete **Verify connection**.

### Connect Tether Flow on iPhone

1. Keep the guest running and join the same tailnet on the iPhone.
2. In Tether Host, open **Connect iPhone** and verify the guest connection.
3. Copy the Tailscale URL and Hermes token into a new **Hermes API Server** connection in Tether Flow.
4. Tap **Test Connection** on the phone, save the profile, then confirm the test in Tether Host.

### Build from source

Open `TetherHost.xcodeproj`, select the **Tether Host for Mac** scheme, and build for **My Mac**.

Run the core tests:

```sh
cd TetherHost
swift test --disable-sandbox
```

Build an ad-hoc preview DMG and checksum:

```sh
./scripts/build-preview.sh
```

Increment `CURRENT_PROJECT_VERSION` for every distributed build and `MARKETING_VERSION` for product releases. Developer ID signing and notarization are documented in [docs/tether-host-distribution.md](docs/tether-host-distribution.md).

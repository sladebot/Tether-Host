# Tether Host for Mac

Tether Host runs a private macOS virtual machine for [Tether Flow on iPhone](https://github.com/sladebot/Tether). It manages the VM, guides guest-only Tailscale and Hermes setup, verifies the private connection, and keeps the physical Mac separate from the agent environment.

![Tether Host workspace with guided VM setup and an embedded macOS guest](./screenshots/host-workspace.png)

[Download the latest preview](https://github.com/sladebot/Tether-Host/releases)

## What it does

- Creates and runs macOS VMs directly with Apple Virtualization.
- Downloads or accepts a compatible macOS IPSW and verifies supported downloads before installation.
- Attaches a read-only **Tether Guest Setup** disk when the VM boots.
- Installs or validates Tailscale, Hermes, and computer-use support inside the guest.
- Verifies loopback-only, bearer-authenticated Hermes access over private Tailscale HTTPS.
- Sends verified guest connection details to the host through a private VM socket and stores the token in Keychain.
- Provides explicit, text-only clipboard transfer; clipboard contents are never synchronized automatically.

## How the pieces fit

| Component | Responsibility |
| --- | --- |
| Tether Host | VM creation, lifecycle, display, setup media, and host-side connection verification |
| macOS guest | Tailscale identity, Hermes runtime, model login, permissions, and agent execution |
| Tether Flow | iPhone connection test, Keychain credential, chat, approvals, and mini apps |

The host app uses Apple Virtualization exclusively. It does not launch, poll, register, or depend on UTM.

## Current preview

Version 1.0.0, build 49 targets Apple silicon Macs running macOS 14 or newer. The preview is ad-hoc signed and not notarized, so macOS may ask for confirmation on first launch.

Bundle identifier: `app.tether.host`

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
2. Download the newest DMG and matching `.sha256` file.
3. Verify the download from the directory containing both files:

   ```sh
   shasum -a 256 -c Tether-Host-for-Mac-v1.0.0-build-49-preview.dmg.sha256
   ```

4. Open the DMG and drag **Tether Host for Mac** to Applications.
5. Keep one installed copy so VM state and privacy permissions remain associated with the expected app.

### Create the macOS guest

1. Open Tether Host and choose **Create new**.
2. Select a compatible macOS IPSW or use the in-app supported-image download.
3. Create the VM and complete Apple’s macOS welcome and account screens.
4. Choose **Desktop is ready** when the guest desktop appears.

### Install guest services

1. Start the VM. Tether Host attaches the read-only guest setup disk automatically.
2. In the guest, open the disk and launch **Tether Guest Installer.app**.
3. Follow the six checks for internet access, Tailscale, Hermes, model login, computer use, and connection verification.
4. Grant CuaDriver Accessibility and Screen Recording access when macOS prompts inside the guest.
5. Complete **Verify connection** and return to Tether Host.

### Connect Tether Flow on iPhone

1. Keep the VM running and join the same tailnet on the iPhone.
2. In Tether Host, open **Connect iPhone** and confirm the guest connection is verified.
3. Copy the **Tailscale URL** and **Hermes Token**.
4. In Tether Flow, add a **Hermes API Server** connection and tap **Test Connection**.

### Build from source

Open `TetherHost.xcodeproj`, select **Tether Host for Mac**, and build for **My Mac**.

```sh
cd TetherHost
swift test
```

```sh
./scripts/build-preview.sh
```

Increment `CURRENT_PROJECT_VERSION` for every distributed build. The preview script verifies the app signature and DMG checksum; Developer ID signing and notarization are documented separately.

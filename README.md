# Tether Host for Mac

Run a **macOS or Debian virtual machine** for your Hermes agent and connect to it from [Tether Flow on iPhone](https://github.com/sladebot/Tether). Tether Host manages the VM, guides guest setup, and verifies the private connection.

**[Download build 94](https://github.com/sladebot/Tether-Host/releases/tag/v1.0.0-build.94-preview)** · Requires Apple silicon and macOS 14 or newer.

![Tether Host workspace with a VM ready to start](./screenshots/host-workspace.png)

## Install or update

1. Download the DMG and matching `.sha256` file from the release above.
2. Verify the download:

   ```sh
   shasum -a 256 -c Tether-Host-for-Mac-v1.0.0-build-94-preview.dmg.sha256
   ```

3. Shut down any running VM, quit Tether Host, open the DMG, and drag **Tether Host for Mac** to Applications.

Updating the app preserves existing VM disks and configuration. Keep only one host copy running.

## Choose your guest OS

Both options use Apple Virtualization and the same native sidebar, VM display, power controls, and connection workflow.

| | macOS | Debian |
| --- | --- | --- |
| Installation image | Compatible Apple IPSW; download in the app or choose a local file | Official Debian 13 ARM64 cloud image; downloaded and SHA-512 checked in the app |
| Desktop | Apple's macOS desktop | Xfce on X11, with Chromium and accessibility tools |
| Account setup | Complete Apple's welcome screens inside the VM | Choose your Debian username and password before creating the VM |
| Guest installer | Open **Tether Guest Installer.app** on the **Tether Guest Setup** disk | Open **Tether Guest Installer** from the Debian applications menu after first-boot preparation |
| Disk guidance | At least 64 GB recommended; smaller disks are experimental | 24 GB default; grow it during configuration if needed |

The Debian disk converter, first-boot resources, and guest tools disk are bundled in the app. Disk images grow sparsely on supported filesystems; other drives may reserve their full capacity. Free-space checks account for the selected OS and filesystem.

## Reuse an existing VM

Open **Virtual machine**, choose your existing VM from the name menu above its display, and click **Start VM**. Existing macOS and Debian VMs appear in **VM library**. Reusing one does not require another OS download, disk, or account.

Keep external storage connected while its VM runs. Updating Tether Host does not reinstall the guest OS or erase its data. UTM runtime integration is retired; existing UTM disk bundles are not moved or deleted.

## Create and connect

1. **Create a VM.** Choose **Create virtual machine…** or **VM library → Create New VM**. Select **macOS** or **Debian**, prepare its installation image, then continue to configuration. Choose CPU, memory, disk capacity, and storage location. For Debian, also choose your account credentials.
2. **Reach the desktop.** Finish macOS welcome screens, or wait for Debian's first-boot desktop preparation and sign in with your chosen account. Choose **Desktop is ready** when the desktop is usable.
3. **Set up the guest.** Launch the installer using the OS-specific location above. Follow its steps for Internet, clipboard support, Tailscale, Hermes, model sign-in, computer use, and connection verification. Grant requested macOS computer-use permissions inside the macOS guest.
4. **Connect your iPhone.** Join the same Tailscale network. In Tether Host, open **Connect iPhone** and copy the server URL and API token. In Tether Flow, add a **Hermes API Server**, tap **Test Connection**, and save it.

Keep the VM running while using Tether. Creating an additional VM leaves the running VM untouched and saves the new VM for a later start.

## Preview status

- Build 94 is an **ad-hoc signed development preview**, not a Developer ID signed or notarized production release.
- Internet mode uses Apple NAT and does not block guest access to reachable host or local-network services. Disable **Enable internet access on next start** for an offline VM.
- The restored workflow was checked with an existing Debian VM: it booted to Xfce and Tether Host verified Tailscale and Hermes. Fresh-VM and physical-iPhone end-to-end acceptance remain outstanding.

The app does not share host folders or automatically synchronize clipboards. Connection tokens are stored in Keychain; explicitly copied tokens clear after 45 seconds if unchanged. VM deletion requires exact identity and a typed confirmation.

## Development

Open `TetherHost.xcodeproj` in Xcode with Swift 6, select **Tether Host for Mac**, and build for **My Mac**. Packaging both guest options requires Go and Homebrew `qemu-img` (install with `brew install go qemu`), or set `TETHER_GO_BINARY` and `TETHER_QEMU_IMG` to existing tools.

Run automated checks:

```sh
python3 -m venv build/test-venv
build/test-venv/bin/python -m pip install -r requirements-test.txt
TETHER_TEST_PYTHON="$PWD/build/test-venv/bin/python" bash scripts/verify.sh
```

Build a preview DMG and checksum with `./scripts/build-preview.sh`. Increment `CURRENT_PROJECT_VERSION` and `LinuxGuestSetup/installer-version.json` together for each distributed build.

## Details

- [Architecture and security boundaries](docs/tether-host-architecture.md)
- [Guest setup](docs/guest-setup-implementation.md)
- [Verification and acceptance status](docs/tether-host-verification.md)
- [Signing and notarization](docs/tether-host-distribution.md)

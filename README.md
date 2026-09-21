# Tether Host for Mac

Tether Host for Mac is the macOS companion for the Tether iOS app. Its first-launch
Setup Assistant offers Built-in VM (Apple Virtualization) and UTM. Built-in VM is
the production direction, but this preview blocks it because the native guest
image and lifecycle installer are not bundled yet. The working preview path uses
a compatible UTM installation in `/Applications/UTM.app`.

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

The app creates a read-only `Tether Guest Setup.iso` containing Tether Host for
transfer without shared host folders or clipboard. Inside the macOS guest,
**Run Guest Setup** launches the bundled interactive installer. It checks
Tailscale first, verifies its publisher signature, and guides sign-in when needed.
It then installs the pinned Hermes runtime when absent or configures a working
existing guest installation, enables loopback bearer authentication, prompts for
model login and guest permissions, starts the gateway, configures private HTTPS,
and verifies a real model response. It refuses to run on the physical host.

**Load Guest Connection** imports the generated URL/token in the guest. The
connection screen also offers **Import Guest Connection…** for a private, user-owned
`connection.json`, accepts an existing endpoint manually, checks TLS and
API authentication/capabilities, stores the credential in Keychain, and provides
masked reveal/copy controls for use in Tether iOS. The phone still needs Tailscale
and its own Test Connection check. A host-side check does not certify phone reachability.

Automatic VM creation is not implemented. Users must create/boot the VM and
manually attach the generated ISO in UTM. The development DMG is
not a notarized production installer, and the new guest installation flow has not
yet passed a clean-VM, real-phone end-to-end run. See `docs/guest-setup-implementation.md`.

## Build the app

Open `TetherHost.xcodeproj`, select the `Tether Host for Mac` scheme, and build
for My Mac. The deployment target is macOS 14 and the bundle identifier is
`app.tether.host`.

Build the ad-hoc signed development DMG with `./scripts/build-preview.sh`.
The output filename includes the app marketing version and build number, for
example `build/Tether-Host-for-Mac-v1.0.0-build-3-preview.dmg`, with a matching
`.sha256` checksum file. Bump `MARKETING_VERSION` for a product release and
`CURRENT_PROJECT_VERSION` for every distributed build. The script verifies the
app signature and DMG checksum; this is not a notarized public release.
See `docs/mac-studio-install-test.md` for the installed-app test results.

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

# Tether Host for Mac

Tether Host for Mac is the trusted macOS companion for the Tether iOS app. It
owns and runs the guest directly with Apple's Virtualization framework,
coordinates provisioning and health evidence, and will own the narrowly scoped
privileged networking helper. UTM is not an installation dependency; its adapter
is retained only to migrate or recover an existing guest.

The current milestone is read only. It inventories Tether-owned native VM bundles
by exact UUID, can fall back to read-only UTM discovery for migration, shows setup
and health evidence, and deliberately keeps management actions disabled until
their security and recovery gates are implemented.

The intended customer flow is one app install. First-run setup downloads a
Tether-signed guest image, verifies its manifest and digest, creates the native
VM bundle, and boots it through `Virtualization.framework`. The guest image and
provisioning implementation are still release gates; the current repository is
not yet a distributable one-click build.

## Build the app

Open `TetherHost.xcodeproj`, select the `Tether Host for Mac` scheme, and build
for My Mac. The deployment target is macOS 14 and the bundle identifier is
`app.tether.host`.

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

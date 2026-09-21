# Tether Host for Mac

Tether Host for Mac is the trusted macOS companion for the Tether iOS app. It
discovers and manages the designated UTM guest, coordinates provisioning and
health evidence, and will own the narrowly scoped privileged networking helper.

The current milestone is read only. It lists UTM virtual machines by exact UUID,
shows setup and health evidence, and deliberately keeps management actions
disabled until their security and recovery gates are implemented.

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

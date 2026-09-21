# Tether Host for Mac verification — 2026-09-20

This records evidence for the initial read-only milestone. It is not evidence
that the production installer, privileged helper, network boundary, guest
provisioner, pairing exchange, or signed/notarized DMG is complete.

## Implemented and verified

- The Xcode project has a shared macOS application target and scheme named
  `Tether Host for Mac`, with bundle identifier `app.tether.host`, macOS 14 minimum,
  hardened runtime enabled in target settings, and an explicit empty entitlement
  baseline.
- The host now builds from its own `TetherHost.xcodeproj`; the project contains
  no iOS application or test target.
- Debug and optimized Release builds succeeded for Apple silicon with code
  signing disabled for local verification. The Release build produced
  `/tmp/tether-host-split-release/Build/Products/Release/Tether Host for Mac.app`.
- The Debug app launched and remained running. Its provider is read-only and
  invokes only fixed `utmctl list` and exact-UUID `status` arguments.
- The installed UTM version is 4.7.5. A live read-only `utmctl list` returned:
  - running `Hermes Sandbox`: `738EECC5-6357-43D9-BE03-298E0B3DE206`
  - stopped `Hermes Sandbox`: `DBAD34AA-6E6F-41BB-A23D-2C57DC8B3334`
  - stopped `Home Assistant`: `C5E18D72-DC93-4F11-BCF4-B98FD479AB7E`
- Exact status lookup for the running Hermes UUID returned `started`. This is
  current lifecycle evidence, not containment evidence. The app displays the
  duplicate name and refuses to infer identity from the name alone.
- The standalone core suite passed 28/28 tests. Coverage includes setup journal
  recovery, exact identity and duplicates, endpoint rejection, secret redaction,
  two-phase token rotation, signed manifest verification, component digests,
  idempotent receipts, deterministic dual-stack firewall plans, insecure Serve
  rejection, health evidence freshness/source, pairing metadata without a
  reusable bearer token, and scoped repair/uninstall behavior.
- All release scripts pass `bash -n`; non-credential dry-run paths report the
  renamed archive, app, and DMG paths; credential and artifact checks fail
  closed when their prerequisites are absent. All configuration property lists
  and the Xcode project pass `plutil`, and `git diff --check` is clean.

## Deliberately unperformed

- No firewall/PF, route, Tailscale Serve, Funnel, tailnet policy, VM setting,
  guest service, credential, Keychain item, or unrelated host service changed.
- No privileged helper has been embedded or registered. The repository contains
  the narrow Swift interface, policy validation/generation, entitlement baseline,
  and the required XPC trust design; the actual SMAppService/XPC daemon is a
  later release gate.
- No archive or DMG was signed, submitted to Apple, notarized, or stapled. Real
  Developer ID and notary credentials were neither requested nor read.
- No claim is made that the current UTM shared-network path contains a hostile
  guest. Networked mutation remains blocked until external IPv4/IPv6, spoofing,
  state-reload, private/LAN/tailnet, and host-service negative tests pass.
- No real phone pairing, guest provisioning, CUA permission flow, restart/fault
  recovery, fresh-Mac install, update, repair, token rotation, or uninstall
  acceptance test has run through Tether Host for Mac.

The existing iOS regression suite was rerun after the Xcode project changes.
All 39 tests passed; the result bundle is
`/tmp/tether-host-for-mac-rename-ios.xcresult`. Historical VM evidence in
`hermes-sandbox-migration.md` remains separate and was not reclassified as
Tether Host for Mac acceptance in this milestone.

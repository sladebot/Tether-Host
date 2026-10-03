# Current verification status

The Apple-only remediation adds lifecycle, setup-retry, verification-expiry and
media-replacement regression coverage, plus a shared local/CI verification command:

```sh
TETHER_TEST_PYTHON="$PWD/build/test-venv/bin/python" bash scripts/verify.sh
```

Local remediation verification on 2026-10-01 passed: **59 Swift tests**, **29
guest Python tests**, **7 isolation Python tests**, guest Tailscale-status and
clipboard framing checks, and ad-hoc signed Debug/Release app builds. Every
embedded Mach-O passed hardened-runtime checks; deep strict app signature
verification passed. The startup concurrency test uses a suspended media exporter
and an incomplete fixture bundle, and never constructs a running VM. The real
ISO integration test generated and mounted temporary installer media.

Install `requirements-test.txt` in that virtual environment first. Core tests do
not boot a real VM; the media integration test mounts a temporary read-only ISO.
CI uses ad-hoc signatures and does not test Developer ID notarization.

Live clean-VM, physical-phone, permission-revocation, host-restart, and external
network-containment acceptance are outstanding. No automated unit-test result
should be represented as satisfying those release gates. See
[the acceptance matrix](acceptance-matrix.md).

---

The following is preserved historical evidence. Provider behavior, test counts,
and architecture statements below do not describe the current application.

# Tether Host for Mac verification — 2026-09-20

This began as evidence for the initial read-only milestone. The section below
records the build-5 native VM integration check; later sections preserve the
initial milestone's historical observations.

## Build 5 native VM integration check

- On the macOS 26.2 host, Apple's restore-image API loaded the supplied macOS
  27.0 IPSW and reported hardware support, but installation failed with “a
  software update is required.” The app now rejects a newer major-version IPSW
  before it creates a disk.
- The in-app download code fetched Apple's macOS 26.2 (25C56) IPSW and checked
  its pinned SHA-256 digest. The image was stored under Tether Host's application
  support directory; the user's macOS 27 IPSW was left untouched.
- A temporary signed integration harness built from the same `NativeVMManager`
  source installed macOS 26.2 into a fresh 64 GB sparse disk with a new hardware
  identity. It registered VM `CA7A81D2-490B-4012-AA37-6676330B982F` as
  `Tether Host VM` and started it successfully.
- The harness packaged the actual Tether Host app as `Tether Guest Setup.iso`,
  attached the ISO to that VM, started it again, and stopped it cleanly. The
  original UTM VMs were not modified.
- The build-5 preview DMG was built, mounted read-only, verified with `hdiutil`
  and `codesign`, and its SHA-256 checksum matched. Core tests passed 43/43.
- The macOS welcome screen, interactive setup inside the guest, Tailscale,
  Hermes, and phone connection have not been visually verified. The computer
  control service crashed while reading Tether Host's next setup screen; the
  native VM install and boot checks ran through the temporary harness.

## Historical initial milestone

## Implemented and verified

- The Xcode project has a shared macOS application target and scheme named
  `Tether Host for Mac`, with bundle identifier `app.tether.host`, macOS 14 minimum,
  hardened runtime enabled in target settings, and only the Apple virtualization
  entitlement on the host target.
- The host now builds from its own `TetherHost.xcodeproj`; the project contains
  no iOS application or test target.
- Debug and optimized Release builds succeeded for Apple silicon with code
  signing disabled for local verification. The Release build produced
  `/tmp/tether-host-native-release/Build/Products/Release/Tether Host for Mac.app`.
- The production architecture retains fail-closed inventory for Tether-owned
  native VM bundles. The current preview prefers UTM when a compatible copy is
  installed and blocks the Built-in option until native image/lifecycle support
  exists. UTM queries use fixed `utmctl list` and exact UUID selection.
- The installed UTM version is 4.7.5. A live read-only `utmctl list` returned:
  - running `Hermes Sandbox`: `738EECC5-6357-43D9-BE03-298E0B3DE206`
  - stopped `Hermes Sandbox`: `DBAD34AA-6E6F-41BB-A23D-2C57DC8B3334`
  - stopped `Home Assistant`: `C5E18D72-DC93-4F11-BCF4-B98FD479AB7E`
- Exact status lookup for the running Hermes UUID returned `started`. This is
  current lifecycle evidence, not containment evidence. The app displays the
  duplicate name and refuses to infer identity from the name alone.
- The current standalone core suite passes 43/43 tests. Coverage includes native VM
  bundle creation, exact manifest/directory identity enforcement, setup journal
  recovery, exact identity and duplicates, endpoint rejection, secret redaction,
  two-phase token rotation, signed manifest verification, component digests,
  idempotent receipts, deterministic dual-stack firewall plans, insecure Serve
  rejection, health evidence freshness/source, pairing metadata without a
  reusable bearer token, scoped repair/uninstall behavior, guest-root-only
  dependency detection, and read-only guest setup ISO creation.
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

The existing iOS regression suite was rerun after the repositories were split.
All 39 tests passed; the result bundle is
`/tmp/tether-ios-split.xcresult`. Historical VM evidence in
`hermes-sandbox-migration.md` remains separate and was not reclassified as
Tether Host for Mac acceptance in this milestone.

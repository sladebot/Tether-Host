# Tether Host verification status

## Verified in this change

- The Swift package builds and its active unit tests pass when run with a writable test temporary directory.
- The macOS application builds with the `Tether Host for Mac` scheme and code signing disabled for compile verification.
- Production app code contains only the Apple Virtualization inventory and lifecycle path.
- VM inventory and bundle lookup use the application-owned Apple Virtualization store and exact manifest UUIDs.
- Guest dependency checks remain guest-scoped; host installations cannot satisfy them.
- The preview build script verifies nested signatures, required guest resources, the generated DMG, and its SHA-256 checksum.

## Security properties covered by tests

- Exact VM identity selection and duplicate-name handling.
- Setup journal interruption recovery and diagnostic redaction.
- Tailnet HTTPS endpoint validation and public/insecure origin rejection.
- Hermes authentication failure checks and required capability discovery.
- Guest-only dependency scanning.
- Read-only guest setup disk generation.
- Deterministic firewall policy generation and fail-closed validation.
- Keychain token rotation and secret redaction.

## Remaining acceptance work

- Complete a clean macOS guest installation on a supported Apple silicon Mac.
- Complete real Tailscale, Hermes, model login, Accessibility, and Screen Recording setup inside that guest.
- Verify a real model response and computer-use capture.
- Connect a physical iPhone on the same tailnet and pass Tether Flow’s **Test Connection**.
- Complete Developer ID signing, notarization, Gatekeeper, update, repair, and uninstall testing before a production release.

Build and unit tests establish code-level confidence; they do not establish the full physical-device acceptance result.

# Mac Studio installation test — 2026-09-20

## Installed artifact

- App: `/Applications/Tether Host for Mac.app`
- DMG: `build/Tether-Host-for-Mac-v<version>-build-<number>-preview.dmg`
- Rebuild: `./scripts/build-preview.sh`
- Signing: local ad-hoc Debug build, not Developer ID signed or notarized.

## Latest guided preview validation

The stale installed preview and all repository build caches were removed. The
current app was rebuilt, installed at `/Applications/Tether Host for Mac.app`,
and launched on this Mac Studio. Its first screen identifies UTM as the available
preview provider and the built-in Apple VM as the production target. Read-only
`utmctl list` found both `Hermes Sandbox` registrations stopped; the setup flow
therefore requires explicit UUID selection and does not enable guest transfer
until the selected VM reports `started`.

The current versioned DMG is
`Tether-Host-for-Mac-v1.0.0-build-3-preview.dmg`. Its SHA-256 is
`09c2f8294bd7ec569a57b6d77a568fc46cdf1565d198c7f1d2ab5bfec28ff77e`.
`hdiutil verify` passes. The outer app passes strict deep signature verification.
The nested guest ISO was mounted read-only, its app passed strict verification,
and a normal `ditto` copy out of the ISO retained its executable bit and valid
signature. No Python bytecode cache is present in the packaged guest resources.

The first preview built with CODE_SIGNING_ALLOWED=NO failed strict signature
verification because its resource seal was invalid. Rebuilt with explicit ad-hoc
signing, repackaged the DMG, and installed the app from that corrected DMG.
`codesign --verify --deep --strict` on the installed app and `hdiutil verify`
on the DMG both pass. This does not certify Gatekeeper behavior on another Mac.

## Passed on this host

- Launch the installed app from Applications; UTM 4.7.5 is recognized and Continue
  reaches guest preparation and connection verification.
- Import an owner-only connection receipt for the existing running Hermes VM.
  The installed Swift app verifies HTTPS, authentication rejection for missing
  and wrong tokens, authenticated capabilities, and model discovery.
- Quit/relaunch: the endpoint and masked token restore through preferences and
  Keychain. Past verification is not restored; a fresh verification succeeds.
- An independent host-side guest verification checks the private HTTPS endpoint
  and completes a real durable model run with the expected exact test marker.
- Read-only checks inside the existing guest: VirtualMac2,1; Hermes listens on
  127.0.0.1:8642; Tailscale Serve forwards private HTTPS to that loopback service
  with no Funnel configuration. CUA doctor reports Accessibility and Screen
  Recording granted and AX trusted. Direct ScreenCaptureKit capture was skipped
  by doctor and was not exercised in this test.
- 43 Swift core tests, 13 Python guest setup/readiness tests, and 7 isolation
  tests pass; shell syntax and git diff whitespace checks pass.

The API token was not printed in logs or exposed in the UI. A private temporary
receipt was used for import and removed afterward. The requested connection is
retained in the installed app's Keychain so the user can copy it into Tether iOS.
No existing guest configuration or service was changed during these checks.

## Not yet validated

- The paired iPhone remained disconnected; no physical iOS Test Connection or
  phone-to-VM interaction was completed in this test.
- A fresh guest installation, guest restart/recovery, and actual desktop capture
  through the phone remain untested. Existing-backend tests do not prove that
  the bundled installer can provision a clean VM end to end.
- Automatic native VM creation and automatic ISO attachment are unimplemented.
  The app now creates a read-only guest setup ISO for manual attachment in UTM.
- Public release signing/notarization and external isolation checks remain open.

Automatic approval review rejected uploading/executing the installer on the
existing Hermes VM because it could change working files, credentials,
dependencies, or services. That command did not execute. Subsequent guest checks
were read-only; a disposable VM is needed for the fresh-install test.

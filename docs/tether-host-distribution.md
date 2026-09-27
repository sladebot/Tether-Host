# Tether Host for Mac distribution

This repository contains a release pipeline scaffold. It has not produced a
signed or notarized artifact, and no release is ready to distribute until the
checks below pass on a clean machine.

The production contract is one DMG containing one application. It creates, stores, and runs an app-owned macOS guest with Apple.s `Virtualization.framework`; no third-party virtualization app is required.

The development preview contains the app plus a guest setup ISO. It accepts a local IPSW or downloads the supported Apple image, then creates the VM directly. It has not passed a clean-VM, real-phone end-to-end test. The preview is ad-hoc signed and is not notarized.

## Release identity and one-time setup

The app, every nested framework/tool, and the privileged network helper must be
signed with a **Developer ID Application** certificate belonging to one Apple
Developer team. A DMG is also signed with that identity. A **Developer ID
Installer** certificate is only needed if distribution later changes to a signed
`.pkg`; it is not used for the current drag-to-Applications DMG.

Create a notarytool credential in the login Keychain outside this repository.
Either Apple ID credentials with an app-specific password or an App Store
Connect API key can be stored by `notarytool store-credentials`. Do not put the
password, private key, issuer ID, or key ID in a script, `.env` file, build log,
or CI command line. Give the resulting Keychain item a non-secret profile name.

Release scripts read these values:

```sh
export TETHER_DEVELOPMENT_TEAM='ABCDEFGHIJ'
export TETHER_SIGNING_IDENTITY='Developer ID Application: Example Company (ABCDEFGHIJ)'
export TETHER_NOTARY_KEYCHAIN_PROFILE='tether-notary'
```

The exact signing identity must already be available in the current Keychain
search list. The notary profile contains the credential; scripts pass only its
name. CI should use an ephemeral Keychain and secret store with equivalent
access controls.

## Xcode release configuration

Before executing the pipeline, the Xcode project must have a shared scheme
named `Tether Host for Mac`, a Release configuration, and these settings on every code
target:

- macOS deployment target and bundle identifiers fixed for the release;
- hardened runtime enabled;
- automatic timestamping enabled for Developer ID signatures;
- target-specific entitlement files from `Config/`;
- the network helper and its launchd property list embedded at their final paths
  before the containing app is signed;
- no test-only signing flags, `get-task-allow`, unsigned executable memory, or
  disabled library validation in Release.

The helper's designated requirement and the app's XPC peer validation must pin
the same Team ID and the intended bundle identifiers. A helper embedded in an
app is not trusted merely because it came from the same DMG. The helper must be
signed independently, then included in the app's nested-code seal. The embedded
`SMAppService` launch daemon property list, executable path, Mach service, and
helper identifier must match. Any post-signing change to the helper or launchd
property list invalidates the outer app signature.

`SMAppService` registration does not remove authorization. macOS controls the
registration and may require an administrator to approve the background item.
The app must treat a pending or rejected registration as a blocked setup stage,
not as installed network isolation. Updates must preserve the helper identity
and perform a controlled unregister/register transition when required.

## Pipeline

All generated output uses fixed paths under `build/release`, which is ignored by
Git. Mutating scripts default to a dry run, refuse to overwrite an existing
archive/export/DMG, and require the literal `--execute` argument. Delete or move
old output deliberately before starting a new release.

Run the stages independently while bringing up a release configuration:

```sh
scripts/release/validate-environment.sh
scripts/release/archive.sh --execute
scripts/release/export.sh --execute
scripts/release/verify-signatures.sh
scripts/release/create-dmg.sh --execute
scripts/release/sign-dmg.sh --execute
scripts/release/notarize.sh --execute
scripts/release/staple.sh --execute
```

After the stages are proven independently, the orchestrator runs the same
sequence:

```sh
scripts/release/release.sh --execute
```

The exact outputs are:

| Output | Path |
| --- | --- |
| Xcode archive | `build/release/TetherHostForMac.xcarchive` |
| Exported app | `build/release/export/Tether Host for Mac.app` |
| Signed, submitted, stapled disk image | `build/release/Tether Host for Mac.dmg` |

`validate-environment.sh --notary` makes a read-only notary history request to
confirm the named profile before a full run. `verify-signatures.sh` verifies the
outer app plus each embedded Mach-O, the expected Team ID, and hardened runtime.
Notarization is performed only after the DMG signature verifies. Stapling runs
only after `notarytool --wait` reports acceptance. No script prints the contents
of a credential.

For a rejected submission, use the submission ID shown by notarytool to fetch
Apple's log manually with the same Keychain profile. The log may reveal internal
filenames and signing metadata, so inspect it before sharing. Fix the source or
build settings, create new output from the archive stage, and submit that new
DMG. Never staple a rejected or superseded submission.

## Fresh-Mac release gate

Test the final DMG on a supported Mac that has never run Tether Host for Mac and does not
have the developer certificate installed. Download it through the intended
delivery channel so it has the normal `com.apple.quarantine` attribute. Preserve
the submitted DMG bytes; the download must have the same SHA-256 used by the
release record.

1. Disconnect the test Mac from the internet and confirm `xcrun stapler
   validate 'Tether Host for Mac.dmg'` and Gatekeeper assessment succeed. This exercises the
   stapled ticket rather than a live notary lookup.
2. Open the DMG, drag the app to `/Applications`, and launch it through Finder.
   Confirm there is no unidentified-developer or damaged-app warning.
3. Confirm the app remains unprivileged before helper registration and displays
   isolation as uninstalled/unknown.
4. Exercise the helper approval, Tailscale authentication/system-extension
   consent, and guest Accessibility and Screen Recording prompts. Deny each once
   and verify setup remains safely blocked and resumable.
5. Complete setup, restart the Mac, and verify helper identity, VM identity,
   sharing-disabled state, authenticated tailnet HTTPS, raw-port denial, and all
   host/private/tailnet negative-isolation probes with fresh evidence.
6. Verify update, repair, token rotation, app removal while keeping the VM, and a
   separately confirmed full uninstall. Confirm unrelated VMs, PF rules,
   services, Keychain items, and tailnet policy are unchanged.

Unavoidable user approvals are part of the supported flow: administrator/background
item approval for the privileged helper; Tailscale VPN or network-extension
approval and Tailscale login; Accessibility and Screen Recording inside the
guest for CUA; and provider login where required. These dialogs must name the
expected component and explain their scope. The app cannot preapprove them on an
ordinary consumer Mac. MDM policy is a separate managed deployment design and
must not be used to imply that the consumer flow is silent.

Record Xcode/macOS versions, commit, certificate expiration, Team ID, archive and
DMG SHA-256, notary submission ID/status, verification output, and fresh-Mac test
results in the release record. Do not record tokens, credential values, request
headers, private paths, or the notary credential itself.

## Remaining release work

The application target, shared scheme, Release build settings, bundle identifier,
and application entitlement baseline are present. The privileged helper target,
embedding phase, launch daemon property list, and XPC code-signing checks remain
to be implemented and reviewed. The pipeline must then be exercised with real
Developer ID and notary credentials, followed by the fresh-Mac gate. Until that
happens, the repository has no signed/notarized Tether Host for Mac release.

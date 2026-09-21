# Mac Studio installation test — 2026-09-21

## Current preview

- App: `/Applications/Tether Host for Mac.app`, version 1.0.0, build 8.
- DMG: `build/Tether-Host-for-Mac-v1.0.0-build-8-preview.dmg`.
- SHA-256: `1af639f76b2582e38b71323fd8c6199cc055a7bfeec20f6609c4b770566becb7`.
- Rebuild: `./scripts/build-preview.sh`.
- Signing: local ad-hoc Debug build, not Developer ID signed or notarized.

The DMG checksum and `hdiutil verify` passed. The app inside the DMG and the
copy installed in Applications passed strict deep code-signature verification.
The old preview DMGs and temporary Tether Host app copies were removed. No older
Tether Host process remained when build 8 was launched.

## Tested on this Mac Studio

The host runs macOS 26.2. Tether Host downloaded and verified a compatible
macOS 26.2 IPSW. Its native Apple Virtualization path created a fresh
`Tether Host VM`, installed macOS, generated and attached the guest setup ISO,
and booted the VM. The older macOS 27 IPSW was rejected on this host before
creating a VM.

The built-in VM configuration includes a Virtio network device with an Apple
NAT attachment for outbound access through the host. This configuration was
validated and the VM booted. A guest-side HTTPS request has not yet been run;
the macOS account screens must finish first.

Build 6 launched from Applications and opened the VM display inside Tether
Host. The VM display stayed open, and the Apple Virtualization process held
the test VM disk. Previously, several older app copies were running at once,
and a second copy tried to start the same VM. Build 6 checks for another open
Tether Host copy before installation or boot and reports the conflict instead
of briefly opening then closing its VM display.

The setup guide now asks the user to complete Apple's macOS account screens in
the VM. **Return to Setup Guide** is available before setup is finished;
**Desktop is ready — Continue** records the user's confirmation and closes the
display without stopping the VM. **Show VM** returns to the guest. A fresh VM
has no guest helper yet, so desktop readiness is confirmed by the user.

The app builds successfully, 43 Swift package tests pass, and `git diff
--check` passes. The computer-use service repeatedly closed its native pipe
when clicking the return control, so that UI action could not be verified by
automation. Tether Host itself remained running and the VM disk stayed open.

Build 7 adds **Create New VM** to the Virtual Machines page. This button was
visible in the installed app even when UTM was the previously selected provider.
It routes to the built-in macOS creation guide; the guide explicitly labels the
IPSW choice and creation action. The computer-use service crashed while reading
that guide after clicking the button, but the Tether Host process remained live.

Build 8 places a second **Create New VM** action directly above the existing-VM
checks on the UTM Setup Assistant screen shown in user testing. It changes to
the built-in Apple VM creation guide. The compatible macOS IPSW already stored
by Tether Host is offered for reuse rather than presented as a fresh download.
The installed app is build 8 and remains running. The computer-use service again
closed its native pipe while reading this particular guide after navigation;
this did not terminate Tether Host.

## Still to test with the user

Finish Apple's account creation inside this fresh VM, confirm the desktop in
Tether Host, and run the bundled guest setup there. Verify Tailscale and Hermes
inside the VM, then complete a real Tether iPhone connection and interaction.
Those user and guest steps are not claimed as completed by the host-side boot
and packaging checks. UTM remains the backup for existing VMs.

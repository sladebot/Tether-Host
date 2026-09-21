# Mac Studio installation test — 2026-09-21

## Current preview

- App: `/Applications/Tether Host for Mac.app`, version 1.0.0, build 11
  remains open with a VM running.
- DMG: `build/Tether-Host-for-Mac-v1.0.0-build-12-preview.dmg`.
- SHA-256: see the matching `.sha256` file beside the DMG.
- Rebuild: `./scripts/build-preview.sh`.
- Signing: local ad-hoc Debug build, not Developer ID signed or notarized.

The build 11 DMG checksum and `hdiutil verify` passed. The app inside the DMG
passed strict deep code-signature verification. Its nested guest ISO mounted
read-only with an executable setup command and supporting files, without a
second copy of the host app.

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

The app builds successfully. The computer-use service repeatedly closed its native pipe
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
The installed app was build 8 during this test. The computer-use service again
closed its native pipe while reading this particular guide after navigation;
this did not terminate Tether Host.

Build 9 adds **Show in Finder** for exact local VM bundles on the Virtual
Machines page and beside matching VM rows in Setup Assistant. It resolves the
VM UUID from the native manifest or UTM `config.plist`; duplicate VM names are
not used as a path. One local UTM bundle matched a registration by UUID. A
second registration had no discoverable exact local bundle, so its Finder action
is unavailable. Build 9 also refreshes the small guest-only ISO at each native
VM boot. The guest helper checks HTTPS from inside the VM before trying to
install Tailscale or Hermes. The network check still needs to run after Apple's
guest account setup is finished.

Build 10 labels the built-in and UTM inventories separately and lets the user
switch the Virtual Machines page between them. A VM created by Tether Host is
persisted under `~/Library/Application Support/Tether Host for Mac/Virtual Machines/`
and is not registered with UTM. The build script stamps the packaged app bundle
with the build time for Finder; Tether Host updates its own VM folder date on
successful boot and stop. Finder's date for an existing VM folder was reconciled
to the newest VM file timestamp. The guest installation and phone connection
still need the user steps below.

Build 11 found two saved built-in Tether Host VMs on this Mac. Their manifests
had the same display name, which made the inventory ambiguous. Existing
same-name native VMs now show a short UUID suffix, and newly created native VMs
receive a unique display name at creation. Exact UUID selection remains in
place. The UTM inventory is separate and cannot display these native VM
bundles as UTM registrations. The installed build 11 UI showed both saved VMs
with distinct names and exact UUIDs in the Tether Host inventory.

Build 12 adds a permanent **Delete…** action to each stopped VM row when its
exact local bundle can be resolved by UUID. The confirmation names the VM,
shows its full UUID, and requires typing its last eight characters. Built-in
VM deletion removes the bundle and disk image directly; UTM deletion invokes
UTM's UUID-specific command, then removes an exact UUID-matched local bundle
if UTM left it behind. No real user VM was deleted during automated testing.
Build 12 compiled, its DMG verified, and all 48 core tests passed. The running
build 11 VM was left intact, so build 12 has not yet replaced the copy in
Applications or received a live UI smoke test on this Mac.

## Still to test with the user

Finish Apple's account creation inside this fresh VM, confirm the desktop in
Tether Host, and run the bundled guest setup there. Verify Tailscale and Hermes
inside the VM, then complete a real Tether iPhone connection and interaction.
Those user and guest steps are not claimed as completed by the host-side boot
and packaging checks. UTM remains the backup for existing VMs.

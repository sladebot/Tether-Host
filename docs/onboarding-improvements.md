# Focused onboarding

## Build 55: storage location and smaller virtual disks

The Configure your VM step includes a storage folder picker, including mounted
external drives, and a Use this Mac reset. New disk capacities start at 24 GB with
8 GB stepper increments and direct entry; below 64 GB, setup explains that macOS
installation and updates may require more capacity. The recommended default remains
128 GB. This does not shrink or relocate existing VMs.

Native and UTM bundles honor the selected final storage location. A persisted
registry uses folder bookmarks and volume identity to find them after relaunch;
missing native storage remains visible as unavailable, and exact lookup never
falls back to a different local copy of a registered external VM. The picker
rejects unwritable locations, storage inside an existing VM, and volumes without
sparse-file support. Downloads remain in the local cache (25 GB free-space check),
while installation checks the target volume separately.

Validation: native build, signature and DMG integrity checks, 65 core tests, and
onboarding smoke checks passed. Registry tests covered relaunch, missing storage,
and rejection of a local UTM duplicate when registered external storage is missing.
The isolated UI verified folder selection, restoration after relaunch, reset to
this Mac, and 24 GB accepted with an experimental warning. Full macOS installation
on a 24 GB disk and physical drive disconnect during a running VM remain untested.
Build 55 was installed on disk without stopping the running VM.

## Build 54: a dedicated configuration step

Creation is now an explicit two-step flow: Choose macOS, then Configure your VM.
Continue requires an inspected image; the configuration step shows that image
alongside editable RAM, CPU, and disk values and a final Create action. Back keeps
resource choices. The first onboarding page links into this flow instead of
showing a second copy of the resource controls.

Validation: native build, DMG verification, and onboarding smoke checks passed.
The isolated UI fixture verified Continue into configuration, direct numeric input,
rejection of 32 GB disk capacity, and preservation of 256 GB after Back/Continue.
External storage selection is not part of this build.

## Build 53: visible VM settings and creation alongside a running VM

Memory, CPU, and disk settings are always visible in setup and creation, with a
clear Virtual machine settings heading. There is no disclosure control to expand.

Create another VM is visible in Prepare VM and the VM toolbar menu, and remains
available while a VM runs. Creation uses its own installer VM instead of replacing
the active VM reference. If a VM is still running when installation finishes, the
new VM is saved without booting and the inventory opens with the current VM selection
preserved. Opening setup is separate from the existing cross-process ownership check.

Validation: native build, DMG verification, and onboarding smoke checks passed.
An isolated running-state fixture verified the enabled creation entry point, visible
resource controls without expansion, successful memory adjustment, and enabled
final creation with an image selected. The fixture did not create or run a VM; a full
concurrent macOS installation remains untested. Installation of build 53 preserved
the live process.

## Build 52: VM resource settings

New users can expand VM settings in the first setup step to adjust memory,
CPU cores, and disk capacity. A compact summary stays visible when collapsed,
and Use recommended settings restores host-aware defaults. The same settings
carry into the creation dialog, whose content scrolls to keep its action buttons
visible on smaller windows. CPU and memory are bounded by host and image limits;
disk capacity ranges from 64 to 1024 GB and grows as storage is used.

New VM manifests store these choices, and later launches and UTM exports use them.
Legacy manifests remain readable and retain their previous startup defaults.
This controls new VMs only; it does not resize or modify existing VMs.

Validation: native build, DMG integrity/signature checks, 63 core tests, and
isolated onboarding state checks passed. The production-view fixture verified
resource changes, transfer into the creation dialog, reset to recommended settings,
and final alignment. No VM was installed or restarted during validation. Build 52
was installed on disk while preserving the running VM process.

## Build 51: complete setup gating and version-aware downloads

Starting a VM alone no longer collapses setup. Automatic collapse requires the
current VM desktop, private network, and assistant connection to be ready, plus
confirmed phone setup. The sidebar toggle remains available, and a manual reopen
survives subsequent verification updates. Native full screen remains explicit.

The Mac design review tightened the VM toolbar and moved clipboard tools into its
More menu. Narrow setup panes now show four readable steps in a two-column grid.
Download macOS remains visible alongside manual IPSW selection and cached-image reuse.
A simple macOS version picker appears in the first setup stage and creation dialog.
It defaults to an available host-matching version and lets users choose older
macOS releases (14 or newer), without offering an image newer than their host.
The choice carries into the download; manual IPSW selection remains available.
Apple-hosted binaries, published checksums when available, native compatibility, and
exact image version/build are checked; cached images are verified before reuse.

An isolated production-view fixture verified incomplete-live-checks visibility,
auto-collapse after all checks complete, and manual reopen surviving verification
changes. It did not start or stop a real VM. Version policy and URL-origin tests cover
14/15/26/27; full guest installations on each host version remain untested.

Validation: final native build, DMG integrity/signature checks, 60 core tests, and
isolated app-model onboarding checks passed. A production-view fixture loaded the
actual catalog, displayed macOS 26.2 as Recommended on this host, offered older
14/15 releases, and retained a selected 15.6.1 when opening the creation dialog.
No large restore image was downloaded or VM created during these checks.

## Build 50: VM workspace after setup

After phone setup is confirmed, the running built-in VM fills the window. A compact
toolbar toggles setup and exposes connection details, VMs, Health, and Diagnostics.
The reopened pane is capped at 400 points. Opening the VM from the completion
screen closes the pane; manually reopening it persists through periodic refresh.
Stopping the VM restores the setup/recovery surface. Routine footer messages are
hidden while the pane is collapsed; errors and pending shutdown remain visible.

Validated in an isolated layout fixture (no actual VM started): automatic collapse,
manual reopen across refresh, Open VM collapse, and connection details navigation.
The fixture uses the production workspace with synthetic model/VM status and a
clearly labeled placeholder display. Actual guest/fullscreen interaction is not
claimed by this layout check. Native app build and signature verification passed.

## Build 49

The setup workspace now emphasizes the current task, with compact progress navigation,
contextual primary actions, and advanced VM/connection options in disclosures.
The VM monitor is optional and no longer occupies space on connection or management
screens by default. Health and diagnostics are secondary tools.

Changes include direct VM creation from inventory, readable offline setup pages,
an explicit user-confirmed iPhone completion screen, and a return path to that screen.
Historical phone confirmation is separate from current backend verification. Changing
the VM, endpoint, or credential invalidates the confirmation. UTM preferences survive
the provider-default migration; live desktop/network attestations are rechecked on launch.

## Validation

- macOS Debug app build, ad-hoc signed: passed.
- Core suite: 56 tests passed, including three phone-confirmation cases.
- `bash scripts/test-onboarding-state.sh`: passed using real AppViewModel with isolated
  preferences and synthetic inventory. Covers migration, stale readiness, saved URL
  hydration, offline confirmation gating, direct creation, navigation preservation,
  and credential/endpoint/provider invalidation. It never starts a VM or writes credentials.
- `git diff --check`: passed.
- Separate preview identity: visually inspected setup, offline phone, VM inventory,
  direct creation/cancel, and Health. Used existing VM inventory read-only; did not
  create, start, stop, or delete a VM. Followup copy changes clarified the other-copy
  blocker and removed premature phone controls.
- Final app signature checked with `codesign --verify --deep --strict`.

The existing installed app owns a running VM. Installation replaces the on-disk app
while preserving that running session; the new UI becomes active after a safe quit
and relaunch. No forced shutdown or live-session handoff is performed.

Remaining acceptance: full fresh VM installation, UTM lifecycle, guest permissions,
real iPhone pairing, full-screen VM interaction, and VoiceOver. The durable setup
journal and compatible-image discovery are not changed in this UI increment.

To rerun app-model checks, first build the macOS Debug app and set
`TETHER_TEST_BUILD_DIR` to its DerivedData directory, then run the script above.

## Ubuntu creation and storage (in validation)

The creation sheet now starts with a native macOS / Ubuntu picker. macOS keeps
its host-aware version selection. Ubuntu offers the official ARM64 24.04 LTS
cloud image, checks its published SHA-256, and prepares a sparse 24 GiB disk by
default. Memory, CPU, disk capacity, and internal/external storage remain visible
on the configuration step. Ubuntu currently uses the built-in VM provider.

Ubuntu has its own EFI state and generic Apple Virtualization configuration.
Legacy manifests decode as macOS; the OS field is persisted for new Linux VMs.
The local app includes qemu-img and relocated libraries, so a user's first install
does not depend on Homebrew. The build machine needs QEMU; dependency licenses,
formulae, and install receipts are retained beside the bundled converter.

First boot installs a minimal Xfce desktop and the Linux guest installer. A
per-VM console password is stored with owner-only permissions and must be changed
at first login. Guest setup guides Tailscale and model sign-in, starts Hermes on
loopback, verifies desktop access and the private API, and exposes a verified
receipt only over the host/guest socket. Desktop login refreshes the user service
environment after reboot.

Ubuntu downloads show transferred bytes, speed, and estimated time remaining.
“Show downloaded image in Finder” lets the user manually remove the cached image
after creation. VM disks do not depend on that cache. The created bundle retains
the source checksum for provenance.

Validation is ongoing: build 61 and all 71 core tests pass. The isolated real-VM
harness checks first boot, cloud-init, networking, guest service startup, disk
allocation, and reboot persistence. Tailscale/model sign-in and a real model
response must still be completed in the guest before the workflow is verified.

### Build 61 external storage verification

Folder selection now persists before validation and exposes any validation error
beside the selected path. Both guest creation paths stage and publish the VM in
that folder; an unavailable drive blocks creation rather than falling back to
internal storage. Non-sparse volumes use a full-disk allocation budget, and free
space checks fall back to ordinary capacity when Important Usage reports zero.

On 2026-09-23, the installed build 61 UI retained
`/Volumes/Sandisk-2TB/TETHER-VM` through a quit/relaunch, displayed the exFAT
allocation warning, and enabled Create VM. A separate small write/truncate test
and bookmark resolution succeeded on that volume. An 8 MiB bundle probe also
verified bundled QEMU conversion, raw disk resize, mode changes, generic machine
identity, EFI variable storage, and NoCloud seed creation on exFAT; its temporary
files were removed. Full external VM creation has
not yet been verified. The existing macOS VM remained stopped and unchanged.

### Build 62 Ubuntu runtime verification

The fresh isolated 24 GiB Ubuntu test passed first boot/cloud-init, HTTPS,
guest setup service startup, saved-file persistence after reboot, and HTTPS and
service health after reboot. The stopped VM used 2,696,167,424 bytes physically.
Evidence: `/private/tmp/tether-ubuntu-e2e-run5/report.json` and its serial log.
The guest now persists its MAC address and uses explicit DHCP network config.
When the NAT DNS forwarder refuses queries, a guest-only boot helper tries
existing DNS first and applies transient public DNS only if needed; it preserves
an active Tailscale DNS configuration. No host network settings are modified.

The installed build 62 created VM `BEA3EA4F-78AF-40DD-99B5-E2484B201EE3` through
the UI in `/Volumes/Sandisk-2TB/TETHER-VM`, with 4 CPUs, 8 GiB RAM, and a 24 GiB
disk. The manifest, disk, and external registry entry were verified. Its exFAT
disk allocates the full 25,769,803,776 bytes, as the creation UI explains.
External first-boot desktop provisioning and user sign-in remain in progress.
Full Tailscale, model, computer-use, and host-connection verification is pending.

### Graphical login acceptance correction (build 63)

The build 62 runtime test did not cover the graphical login screen. Actual UI
inspection found LightDM could not start because the minimal package list omitted
`lightdm-gtk-greeter`. Build 63 includes that package explicitly. Repairing the
isolated VM produced an active LightDM, Xorg process, and X0 socket. Fresh tests
now also require the greeter process on first boot and after reboot.

The unconfigured external VM created during this test was shut down normally and
removed after preserving diagnostics, reclaiming its full 24 GiB. Its registry
entry alone was removed. The original macOS VM was untouched. Build 63 is installed;
external VM recreation and user sign-in wait for the Mac to be unlocked.

Fresh build 63 verification passed on 2026-09-23: cloud-init, HTTPS, guest
handoff service, LightDM, X0 display socket, and a live GTK greeter process on
first boot and after reboot; the saved-file persistence check also passed. The
VM shut down cleanly. Its 24 GiB disk used 2,696,425,472 bytes physically.
Evidence: `/private/tmp/tether-ubuntu-e2e-run6/report.json` and its serial log.
No user Tailscale/model credentials were used. The full core suite's two existing
complete-file-protection write tests must be rerun after host unlock; the other
69 tests passed while locked (all 71 passed before locking on build 62).

After host unlock, all 71 core tests passed on build 63. Actual UI creation again
used the saved external path and created VM
`7286049E-D450-42A6-A33A-98D8C4C59CA1` in `/Volumes/Sandisk-2TB/TETHER-VM`.
Its manifest records 4 CPUs, 8 GiB RAM, and a 24 GiB disk; first-boot provisioning
is running. This replaces only the earlier unconfigured external test VM.

Actual build 63 external VM `7286049E-D450-42A6-A33A-98D8C4C59CA1` reached
the graphical LightDM login screen. Finder selected its `ubuntu-credentials.txt`
for the user. The user must complete the first-login password change and guest
Tailscale/model sign-ins before final host/guest verification can proceed.

### Ubuntu clipboard work (build 64, runtime validation in progress)

The VM toolbar exposes a labeled Clipboard menu for both guest operating systems.
Ubuntu instructions use Ctrl-V (Ctrl-Shift-V in Terminal). The Linux helper
requires explicit guest opt-in through Tether Text Clipboard, a live tether Xfce
session, and bounded UTF-8 text of at most 64 KiB. Verified connection handoff
remains independent. A bundled read-only TETHERUBUNTU tools disk provides an
explicit updater for existing VMs on their next boot, without recreating them.
Build 64 compiles, its DMG verifies, and all 71 core tests pass.

Automated GUI login attempts were inconclusive: a harmless visible input probe
showed that the computer-use keyboard injection dropped uppercase/control
modifiers when forwarded to VZVirtualMachineView. This is not evidence that the
saved password is invalid or that LightDM cannot handle password expiry. The
password-expiry policy remains unchanged, and the user was asked to log in with
their physical keyboard and complete the required password change themselves.

### Current login blocker and reset handoff (2026-09-23)

Installed build 65 is running external Ubuntu VM
`7286049E-D450-42A6-A33A-98D8C4C59CA1`. A fresh UI inspection still shows the
LightDM login screen, not an authenticated desktop. The user reports that the
saved initial password fails and requests a reset for manual setup. The choice
between erasing Ubuntu for a manual installation and preserving its disk with
login recovery is pending; no reset has been performed. The original macOS VM
must remain untouched.

The existing Ubuntu creation path converts the verified cloud image and attaches
mandatory `seed.iso`; it does not boot an interactive Ubuntu installer. Recreating
that same path would reproduce the generated-account onboarding instead of
satisfying a manual-install request. A manual path needs a verified ARM64 installer,
a blank target disk, installer boot media selection/ejection, and guest tools
installation after the user creates their own account. The current guest helper
assumes the `tether` account, so arbitrary user names also require compatibility
work before claiming manual-install support.

The build 65 source received a follow-up keyboard event correction: AppKit's
`charactersIgnoringModifiers` retains Shift, and typing now stops when the VM
view loses first-responder status between keystrokes. Xcode compilation passed
(`/private/tmp/tether-keyboard-review-build.log`). These follow-up changes are not
yet installed or included in the existing build 65 DMG. Uppercase/punctuation
runtime behavior remains unverified. A Sol review also flagged the single weak
registered display when two VM display surfaces exist; resolve active-view
selection before claiming robust multi-window typing.

Completion remains blocked on actual user login/setup, Tailscale and model
sign-in, Hermes/CUA operation, host connection, and authenticated persistence
verification. Boot/greeter/service test success does not prove these requirements.

### VM lifecycle controls and installer detection (build 67)

Build 67 is installed and its VM library was inspected in the actual app: each
built-in VM exposes Start or Shut Down, with Force Off in More and a confirmation
bound to that VM's UUID. Running display has a Power menu. UTM power remains in
UTM. The library observes lifecycle changes immediately and displays action
errors. Startup reserves the manager before its first await, preventing duplicate
starts; shutdown and force-off reject a mismatched target UUID.

Real isolated VM testing passed: overlapping boot rejected, another VM boot
rejected, wrong-VM shutdown/force-off ignored, and correct-VM clean shutdown
completed. Evidence: `/private/tmp/tether-lifecycle67.log`. All 75 core tests pass
(`/private/tmp/tether-tests67.log`), including four raw-disk verifier tests.

Automatic Ubuntu installer detachment runs only on a stopped VM, after clean
shutdown or before boot. It verifies a supported unencrypted GPT/ext4 installation
with matching root UUID, Ubuntu bootloader and kernel/initrd, and local account.
Uncertain/unsupported layouts keep their installer, with manual ejection available.
Force-off and error stops suppress automatic ejection until a later clean shutdown.
The ISO is renamed, not deleted; guest tools remain attached. See
`ubuntu-installer-auto-eject.md` for detector criteria and limits.

The current external Ubuntu disk did not pass completion detection, so its
installer remains attached. Actual completed manual-install auto-ejection and
user-authenticated Tether end-to-end setup remain unverified. No original macOS
VM was started, stopped, reset, or deleted during this work.

### Force-off completion and disk-first boot (build 68)

A host-initiated VZ stop did not reliably send the guest-shutdown delegate,
leaving build 67 UI stuck On. Build 68 explicitly releases the matching VM's
state after `stop()` completes. The isolated lifecycle test now includes a real
host force-off and asserts the manager clears the running VM and busy state;
`HOST_FORCE_OFF_STATE_OK` and `LIFECYCLE_E2E_OK` passed in
`/private/tmp/tether-lifecycle68.log`. Manual Ubuntu storage lists the writable
disk before installer USB media. Build 68 is installed and signature-verified;
its verified DMG replaces the older local build 67 DMG (moved to Trash).

At the user's explicit request, external VM 7286049E's installer was manually
detached after the user forced it off and the app released the disk. The ISO is
preserved as `installer.ejected.iso`. A disk-only boot returned to Off; read-only
inspection found an empty EFI partition and no kernel/initrd, fstab, or normal
user account. This is incomplete installation evidence, not a detector false
negative. The disk was not erased again. The user's answer about the installer
completion screen is pending; do not claim this Ubuntu VM is ready or bootable.

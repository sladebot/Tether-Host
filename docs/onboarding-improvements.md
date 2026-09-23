# Focused onboarding

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

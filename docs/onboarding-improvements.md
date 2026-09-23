# Focused onboarding — build 49

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

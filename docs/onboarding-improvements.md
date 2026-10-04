## Current workspace integration (build 94)

The native sidebar and embedded VM controls remain the current workflow. VM creation
now offers macOS and Debian in one two-step sheet. Debian download verification,
account provisioning, Linux guest resources, and bundled converter/tools media were
restored from codex/seamless-onboarding. UTM runtime remains retired.

Validation: 79 Swift tests, 103 guest Python tests, Debug app build and signature
verification passed. Installed build 93 was opened and both creation screens were
visually checked. An existing Debian VM was subsequently booted to Xfce, and Tether Host verified
Tailscale and Hermes. Fresh guest and physical-phone acceptance need user testing.

The historical onboarding plan below describes the earlier panel design; it is not
a claim that all its controls exist in the current sidebar workspace.

# Focused onboarding
# Native macOS onboarding

The workspace uses a native sidebar and toolbar. The VM display fills the available detail area; setup and recovery pages remain accessible while the VM is stopped.

Creation separates image selection from resource and storage configuration. macOS downloads use compatible version selection; new VMs may use external storage. Existing VMs retain their saved configuration.

Tailscale confirmation is user reported. Hermes requires a fresh connection check. Phone confirmation is bound to the selected VM and endpoint and never substitutes for a live connection check.

Apple Virtualization is the only runtime. Legacy provider metadata is ignored without deleting user VM files.

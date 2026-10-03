# Native macOS onboarding

The workspace uses a native sidebar and toolbar. The VM display fills the available detail area; setup and recovery pages remain accessible while the VM is stopped.

Creation separates image selection from resource and storage configuration. macOS downloads use compatible version selection; new VMs may use external storage. Existing VMs retain their saved configuration.

Tailscale confirmation is user reported. Hermes requires a fresh connection check. Phone confirmation is bound to the selected VM and endpoint and never substitutes for a live connection check.

Apple Virtualization is the only runtime. Legacy provider metadata is ignored without deleting user VM files.

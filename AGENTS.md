# Tether Host: macOS and Linux guest tooling

## Scope and product direction

These instructions apply to host onboarding, VM lifecycle, guest installers, mounted tools media, and DMG delivery. Keep the experience simple, native-looking, and usable without terminal commands. Honor explicit user instructions over these defaults.

The user-facing entry point is **Tether Guest Installer** on both guest operating systems. Users launch one app/executable and complete setup inside its window. Scripts may remain implementation details and diagnostic fallbacks; they must not be the normal onboarding instructions.

Use Sol model subagents when delegating work for this project, as requested by the user. Give agents separate files or bounded responsibilities and review their combined result.

## Learn from the existing macOS implementation

Read these sources before changing the guest setup flow:

- `scripts/guest/TetherGuestInstaller.swift`: native guide, ordered steps, descriptions, primary actions, persisted receipts, and an embedded interactive terminal.
- `scripts/guest/terminal.html` and `scripts/guest/vendor/xterm/`: embedded console used for interactive tools.
- `TetherHost/Resources/GuestSetup/Set up Tether Guest.command`: stage execution, guest identity checks, dependency setup, and verification.
- `scripts/guest/build-guest-installer.sh`: packages the guide with its backend resources.
- `scripts/guest/build-linux-tools.sh` and `TetherHost/Resources/LinuxGuestSetup/`: current Ubuntu tools media and backend.

Reuse the macOS workflow and separation between presentation and execution. Do not copy its platform-specific commands into Linux. An embedded console is useful for tools that require a TTY; users should not have to launch Terminal or assemble commands themselves.

## Shared UX requirements

1. Show the current step, its purpose, what happens next, and whether user input is needed.
2. Use explicit states: Not started, Running, Waiting for you, Complete, Failed, and Cancelled. A started process is not a completed step.
3. Show actual download bytes, transfer rate, and estimated time when available. Otherwise use an indeterminate indicator and concrete activity text; never invent percentages or an ETA.
4. Keep routine output behind a Details disclosure. Show useful failure summaries, the relevant error, and a Retry action. Interactive authentication stays visible in an embedded console or opens the official sign-in page.
5. Let users resume completed work. Revalidate prerequisites and receipts against current state; preserve existing accounts, model credentials, and Hermes data.
6. Keep credentials out of command arguments, diagnostic exports, durable UI logs, and host telemetry. The installer must not ask users to paste secrets into chat. User account/password creation and provider sign-in remain interactive.
7. Support keyboard navigation, readable scaling, accessible labels, and a clear primary action. Keep implementation details out of the main flow.

## Implementation plan

### 1. Define a common stage contract

Keep OS-specific execution behind the same conceptual stages:

- Prepare guest tools and check networking.
- Connect Tailscale.
- Install Hermes.
- Configure model access and start the gateway.
- Enable computer use and verify core clipboard support.
- Verify the private connection to Tether Host.

Give each backend stage a stable identifier, prerequisite checks, a repeatable action, and a verification result. Use structured progress events separately from arbitrary command output. Exit status plus verification determines success; parsing a reassuring log line is insufficient. Prevent overlapping executions and invalidate downstream verification after changes.

### 2. Refactor the Ubuntu backend

Split `LinuxGuestSetup/setup.sh` into individually runnable stages while preserving its existing full-run entry point for diagnostics. Keep interactive tools on a real PTY. Install a usable `hermes` command in the guest user's PATH and verify it in a fresh shell; finding a private virtualenv binary alone does not resolve “command not found.”

Provide a narrow privileged bootstrap for package installation and service setup. Validate the invoking account using trusted sudo/polkit identity and the account database. Keep the GUI and Hermes runtime unprivileged. Handle authentication cancellation explicitly. Preserve the existing VM-only, account-ownership, DNS, and pinned-download checks.

### 3. Build the Linux installer guide

Implement a native GTK guide with an embedded VTE console for interactive commands, matching the macOS stages and status behavior. Bootstrap output must be visible before VTE or other optional dependencies are installed. Run blocking work asynchronously; the UI must remain responsive.

Add retry, resume, cancellation, process-exit handling, and an explicit return from browser sign-in. Cancellation must not kill unrelated guest processes or interrupt a package database transaction blindly. Explain when a current package operation must finish before stopping.

Do not assume GTK Python bindings, VTE, polkit, FUSE, or desktop executable-launch behavior are available. Validate the chosen runtime and launcher on a clean supported Ubuntu Desktop image before committing to packaging. Prefer a single ARM64 executable/AppImage containing the guide and backend resources. If external runtime dependencies prevent a true one-file launch, resolve them in packaging or show a graphical bootstrap; do not label a shell script as a standalone binary.

### 4. Package and expose the installer

Put one clearly named launchable installer on `TETHERUBUNTU`, with version information and only necessary supporting documentation. Keep the macOS `.app` on its guest-tools disk. Test opening from read-only mounted media in the stock desktop file manager, including executable permissions, no-exec mounts, and any desktop trust prompts. No manual chmod, sudo command, or terminal launch should be required by the normal flow.

Install a persistent application-launcher entry so users can reopen the guide without the tools disk. Embed backend resources from the same build. Display the installer version and record it in diagnostics. Update host onboarding copy to point to the graphical entry point.

### 5. Preserve reliable networking and VM lifecycle

- Check DNS and repository/HTTPS access before downloads. Distinguish missing connectivity, broken DNS, and repository/package failures.
- Preserve working DHCP DNS and active VPN/Tailscale split DNS. Scope recovery to the guest; do not silently change the physical host's network settings.
- Ubuntu live installation must retain recovery across DHCP renewals and installer network reconfiguration. A one-time `resolvectl` override is insufficient. Maintain the versioned manual DNS seed, NetworkManager recovery, and reconnection checks.
- macOS guest setup occurs after Apple's restore process. Do not claim guest DNS repair covers host IPSW downloads or `VZMacOSInstaller` networking.
- Keep power controls per VM. Never stop, reset, or replace another VM as part of setup.
- Treat Ubuntu OS installation media and Tether guest-tools media separately. Automatically detach OS installation media only after reliable completion checks, preserve the image for manual cleanup, and keep guest tools available for onboarding.
- Fix and regression-test the known completion-detector false negative: a successfully installed Ubuntu VM reached the Jarvis login screen but retained `installer.iso`. Do not weaken checks to disk size, VM boot, or existence of a single file.
- Host status must reflect installed OS/guest setup readiness rather than claiming “installer starting” solely because an ISO remains attached.

### 6. Validate and deliver

Test the guide on a clean Ubuntu VM and the macOS reference flow, not only mocked commands. Cover fresh launch, missing dependencies, working/broken DNS, network reconnection, cancelled authentication, failed download, retry, restart/resume, existing Hermes data, and a fresh-shell `hermes` command.

Verify actual guest service health, authenticated host connectivity, computer-use capability, optional clipboard transfers, and persistence across guest restart. Hand off sign-in and new passwords to the user, then continue verification. Report untested steps explicitly; DNS readiness or a compiled app is not full end-to-end completion.

Build and verify the DMG, confirm its app and guest payload versions, and report the exact file path. When installation is requested, install and reopen that build after safely stopping the relevant VM; confirm the running app's version. Merely producing a new DMG does not update `/Applications` or an already running VM. Repeated failures previously occurred because build 68 remained installed after build 69 was packaged.

Keep user disks intact during upgrades. For an authorized fresh reset, preserve a recoverable backup unless the user explicitly requests permanent deletion. Move superseded DMGs to Trash when cleanup is requested. Never describe backed-up data as deleted.

## Current implementation status

Build 70 implements the Ubuntu GTK/VTE guide, staged backend, and single ARM64 ELF launcher with embedded resources. The tools disk now presents that executable instead of loose scripts. Unit tests, packaging, and signature checks pass. Validate graphical launch, polkit, interactive stages, and authenticated end-to-end connection in the actual Ubuntu guest before claiming the full workflow is verified. The macOS guide remains the reference implementation.

Build 71 lesson: test the guest guide at the actual short VM viewport, including approximately 1024×494 usable pixels. Put primary actions in a fixed footer outside scrolling step/detail panes; size the window to the monitor work area. Each stage needs an explicit action and a clear prerequisite message. Do not treat a successful launch as evidence that its controls are reachable.

Clipboard is a core setup requirement (user correction after build 71). Enable the guest clipboard bridge during normal guest-tool preparation, before Tailscale/model sign-in. Show its readiness and retry controls. Support the default Ubuntu desktop session without asking users to switch to X11 or find a separate hidden launcher. Preserve explicit per-transfer host actions; do not continuously synchronize or persist clipboard contents. Verify Mac-to-VM and VM-to-Mac text, embedded-terminal copy shortcuts, and persistence after a guest restart.

Administrator debugging requirement: normal VM configuration must not include a host directory share. A future debug share must be off by default and require explicit administrator authorization, expose only a dedicated log directory, redact credentials, and detach when disabled. Outbound DNS/internet access is separate from host filesystem access. Keep installer logs inside the guest unless an explicitly authorized debug share is present.

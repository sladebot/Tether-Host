# Guest setup and manual iOS connection handoff

## Implemented

Tether Host runs on the physical Mac. Its read-only guest setup ISO contains a
small command and supporting files; the full Tether Host app does not need to
be installed inside the VM. The user opens the VM display in Tether Host and
double-clicks `Set up Tether Guest.command` on the mounted disk. The command
checks `VirtualMac` before making guest changes.

The physical-host flow checks that an exact designated VM exists and runs. The
helper checks Internet access, Tailscale, and Hermes from inside the guest.
Host-installed software never satisfies those guest checks.

The guest command opens in Terminal so model login, package installation,
Tailscale extension/login, and privacy approvals are user-visible. Before any
installation it checks HTTPS to the Tailscale package server from the VM;
built-in VMs route this traffic through Apple's host NAT attachment.
The script repeats the VM/non-root checks independently of the UI and locks out
concurrent attempts. It preserves unmanaged Hermes installations by refusing to
overwrite them, and supports rerunning its own setup.

The installer checks Tailscale first, installs it when missing, and guides the
guest user through VPN/system-extension approval and tailnet login when needed.
It then checks a fixed Hermes install-script SHA-256 and installs the pinned
Hermes revision only when Hermes is absent. A working existing guest installation
is preserved and configured. It configures API_SERVER_HOST to
127.0.0.1, enables the API and computer_use toolset, preserves/reuses a random
API token, and installs the guest gateway as a login LaunchAgent. It downloads
Tailscale's current stable package and checks its Developer ID publisher, then
checks the installed app signature. It waits for user sign-in and guest CUA
permissions and refuses conflicting existing Serve routes or public Funnel.

Guest verification checks loopback and tailnet authentication, required durable
run capabilities, and a real bounded test-model run. Its persisted admission key
lets retries observe the same run rather than create duplicates. A connection
receipt is produced only after verification. Failed re-runs invalidate the old
success receipt. No credentials appear in routine progress messages, command
arguments, or test logs. The verified token is displayed only during the
explicit connection handoff in the guest Terminal. The guest .env and
connection receipt are private user-owned files.

The guest helper displays the verified URL/token for entry in Tether iOS. The
host app can import a privately transferred guest receipt or accept an existing
URL/token. It verifies TLS, missing/wrong-token rejection, durable capabilities
and model discovery, then
stores the secret in Keychain. Tokens remain masked until Reveal, and a copied
token is cleared after 45 seconds unless the clipboard has changed. Changing the
URL clears the token and invalidates verification. Restoration from Keychain does
not restore a past verification success. Copying URL/token into an existing
Tether iOS connection screen is the requested handoff; no new iOS receiver is needed.

## Manual user boundaries and remaining work

- Finish macOS account setup in the built-in VM's embedded display. Tether Host
  creates and boots that VM and refreshes/attaches the guest ISO. UTM remains a
  manual backup and needs manual VM creation and ISO attachment.
- Complete model login, Tailscale sign-in/system-extension consent, and guest
  Accessibility/Screen Recording approvals. OS approvals cannot be silently granted.
- Install/connect Tailscale on the iPhone, enter URL/token as a Hermes API Server
  connection, and run Test Connection. The desktop check is not phone-side evidence.
- Full guest reboot still requires FileVault unlock/login. External VM isolation
  and public-release signing/notarization remain separate release requirements.
- Hermes transitive installers/dependencies and the stable Tailscale package are
  not all pinned by digest; this is a development installer, not the previously
  planned fully signed component-manifest distribution.
- A fresh-guest installation and real-phone end-to-end run have not been executed.
  Unit tests and builds do not establish end-to-end installation success.

## Validation

- 45 Swift core tests, including guest-root-only dependency scanning, transfer-disk
  export, and network verification rejection cases.
- 13 guest Python tests covering idempotent config/token, private writes, Serve
  conflicts, tailnet identity, required API capabilities, and readiness auditing.
- 7 isolation Python tests.
- Shell syntax check and fail-closed refusal when VM identity cannot be established.
- Xcode macOS build and bundled-resource inspection.
- Native UI verified: provider continuation, secure token field, HTTP URL rejection,
  and automatic token clearing when the URL changes.

## Files and artifact

- `TetherHost/Resources/GuestSetup/Set up Tether Guest.command`
- `TetherHost/Resources/GuestSetup/guest_setup.py`
- `TetherHost/Resources/GuestSetup/components.json`
- `TetherHost/Services/ConnectionVerifier.swift`
- `TetherHost/Views/SetupAssistantView.swift`
- `build/Tether-Host-for-Mac-v<version>-build-<number>-preview.dmg`

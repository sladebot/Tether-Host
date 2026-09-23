# Guest readiness and setup

Run these tools **inside the macOS VM**, in the selected non-admin interactive account.
They do not establish host firewall or tailnet isolation. Follow the isolation gate in
`docs/hermes-vm-backend-checklist.md` before provider sign-in or agent execution.

## Inventory before setup

```sh
python3 audit_readiness.py --confirm-guest --expected-user YOUR_RUNTIME_USER
```

The JSON report records identity, executable paths/version, config-file permissions,
API port listeners including process/user ownership, mounts, and CUA app presence.
It does not open environment/config files or saved credentials. Exit 2 means the
username mismatched or this is an administrator; exit 0 is only an identity check,
**not a readiness or security pass**. The guest flag is an operator attestation;
the script cannot reliably distinguish a Mac VM from its physical host.

Inspect listener records for both IPv4 and IPv6: only loopback addresses are permitted.
Missing visibility from `lsof`, missing commands, or an empty result are unknowns,
not successful checks. Review mounts for host shares. Shared clipboard and CUA
screen permissions require independent console checks; file existence proves neither.

## After host and tailnet isolation passes

1. Create/select a dedicated standard guest account. Keep provisioning/admin
   credentials out of the runtime. Run the inventory there and verify config ownership.
2. Inspect that account's installed `hermes gateway --help`, `hermes model --help`,
   and `hermes computer-use --help`. Record the guest source revision when available.
   The host and guest may have different versions; this repository cannot establish
   guest feature support without guest evidence.
3. Use `hermes model` for a fresh OpenAI ChatGPT/Codex subscription sign-in.
   Complete sign-in interactively, never paste codes or credentials into evidence.
   No paid API fallback. Determine actual model options after sign-in.
4. Configure the guest's protected environment with `API_SERVER_ENABLED=true`,
   `API_SERVER_HOST=127.0.0.1`, `API_SERVER_PORT=8642`, and a fresh guest-specific
   `API_SERVER_KEY`. Start the gateway using this installed version's documented
   lifecycle under the standard account; confirm listener and process ownership.
5. Configure guest Tailscale Serve for private HTTPS to `127.0.0.1:8642`, verify
   the exact DNS name from its status, and verify guest Funnel is disabled.
6. Enable computer use for the API-server platform. In that same interactive
   account, grant Accessibility and Screen & System Audio Recording, then choose
   **Allow** when macOS asks CuaDriver to bypass the private window picker. Verify
   the signed app owns the grants and require a real full-desktop PNG capture;
   app presence and read-only doctor output alone are insufficient. Test a
   disposable TextEdit interaction after the full isolation gate.
7. Probe the already-running API (no model or run requests are issued):

   ```sh
   python3 audit_readiness.py --confirm-guest --expected-user YOUR_RUNTIME_USER --api --authenticated
   ```

   Enter the guest API token only at the hidden terminal prompt. The tool sends it
   only to fixed IPv4 loopback, disables proxies and redirects, bounds reads/timeouts,
   and emits only capability booleans. Verify anonymous and wrong-key discovery both
   return 401, authenticated discovery returns 200 with `ready: true`, and health is
   successful. A false readiness result blocks new durable run admission. These checks
   verify advertised capabilities, not execution or persistence across restart.
8. Complete phone HTTPS authentication, chat/build/edit, close/reopen, approval,
   stop, restart, negative isolation, and clean-snapshot acceptance in the backend
   checklist. Keep the existing Studio profile until all acceptance checks pass.

## Source and endpoint evidence still required

Host process executable paths locate a checkout at
`/Users/jarvis/.hermes/hermes-agent` under another host account. Reading its source
files was denied by filesystem permissions even with an escalated read; no guest
filesystem session was available. Therefore no installed source evidence supports
a final outbound service allowlist. Before enforcement,
inspect **guest source code only** for the subscription authorization, token refresh,
model discovery and responses endpoints; record exact source paths/commit. Do not
read OAuth credential caches. Do not assume `api.openai.com` alone is sufficient for
subscription traffic or open all HTTPS as an undocumented fallback. Tailscale's
control/relay needs must be handled by the network isolation implementation as well.

The capability parser follows `Tether/Services/HermesAPIClient.swift`:
`features.run_submission/run_status/run_events_sse/run_stop`, and
`features.runs_idempotency.supported/durable/retention_seconds`.

## Local tests

```sh
python3 -m unittest discover -s scripts/guest -p 'test_*.py' -v
```

## Installed guest PF defense-in-depth layer

The following checked-in files mirror the root-owned configuration currently
installed in the Hermes Sandbox guest:

- `app.tether.vm-egress.pf` -> `/etc/pf.anchors/app.tether.vm-egress`
- `tether-vm-firewall` -> `/usr/local/sbin/tether-vm-firewall`
- `app.tether.vm-egress.plist` -> `/Library/LaunchDaemons/app.tether.vm-egress.plist`

The post-login availability helper is:

- `app.tether.keep-awake.plist` -> `~/Library/LaunchAgents/app.tether.keep-awake.plist`

It runs `/usr/bin/caffeinate -di` as the guest user, preventing idle system and
display sleep. `RunAtLoad` and `KeepAlive` make the assertion
return after login or an unexpected process exit. It cannot run before FileVault
unlock because user LaunchAgents do not exist in that boot phase.

They preserve tailnet DNS, permit the exact Studio tailnet IPv4/IPv6 destination
on TCP 8446 for the authenticated oMLX route, and preserve SYN-ACK replies for
inbound SSH/HTTPS. They then block other guest-initiated connections to tailnet,
RFC1918, link-local, ULA, and the currently observed Studio LAN IPv6 prefix. The loader requires Apple's
`com.apple/*` root anchor, validates syntax before loading, obtains its own PF
enable token, and removes only its child anchor/token when stopped.

These files are an evidence-backed snapshot, not a portable one-command
installer. Studio tailnet addresses and the LAN IPv6 prefix are environment-specific
and must be remeasured after re-enrollment or network changes. Guest administrator access can disable this layer, public
addresses (including any public Studio relay/Funnel) are not blocked, and the
LaunchDaemon has not yet passed a full pre-FileVault-unlock test.
External tailnet/host enforcement plus a non-admin Hermes runtime are still
required before calling the VM fully isolated.

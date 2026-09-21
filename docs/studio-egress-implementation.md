# Concrete approved-service egress implementation

Date: 2026-09-13. Independent read-only implementation research. No settings changed.

## Recommended minimal build for the existing macOS VM

Use **two enforcement layers plus an application policy proxy**:

```text
PHYSICAL STUDIO
  HOST macOS
    PF: guest physical traffic default-denied
      exceptions: application policy proxy, restricted DNS,
                  exact Tailscale transport destinations/bootstrap
    Dedicated unprivileged policy-proxy account
      HTTP(S) policy proxy on guest-only bridge address:3128
      no host files, administrative APIs, generic TCP relay or proxy UI
      exact approved service/method/path policy; TLS termination/validation
    Restricted resolver on guest-only bridge address:53
      approved Tailscale bootstrap names only; no arbitrary recursive DNS

  UTM GUEST macOS
    Root-owned PF and trusted Tailscale system daemon
      verified daemon UID may use the transport exceptions
      Hermes may NOT use these exceptions directly
    Non-admin GUI session: Hermes + CUA
      application egress only to policy proxy
      no generic proxy supplied by the trusted Tailscale daemon
      no Tailscale operator/admin API authority
    Guest Tailscale Serve -> guest loopback authenticated Hermes API

IPHONE
  Tether -> guest's own tailnet HTTPS endpoint (stateful replies allowed)
```

This deliberately permits access to **two narrow Studio infrastructure services**, the policy proxy and restricted resolver. It does not permit access to the Studio's personal apps, old Hermes, files, shell or desktop. Explain that exception to the user before installation; “no packets whatsoever to Studio” is not the same claim.

This is implementable without changing the UTM backend, adding another Gmail account, or moving Tether's ingress to a Studio proxy. It is a **non-admin agent containment design**, not proof against guest-root/kernel compromise. Guest PF protects the trusted transport exception; a root-compromised guest can disable that protection. Host PF still provides a useful independent limit, but cannot identify the originating guest Unix user.

## Why not simply allow a list of HTTPS hostnames?

1. Generic CONNECT tunnels expose arbitrary byte streams. A CONNECT destination, TLS SNI, and inner HTTP Host/:authority can disagree. A proxy which approves only the first field has not approved the actual application destination.
2. Studio Funnel resolves to public relay addresses. A private-IP block is not sufficient. [Funnel architecture](https://tailscale.com/docs/features/tailscale-funnel)
3. DERP is intentionally an encrypted packet relay. Public DERP access granted to every guest application is an opaque tunneling capability, even if the relay hostnames are allowlisted. The Tailscale documentation itself describes HTTPS reachability as enough to build a DERP tunnel. [Connection types](https://tailscale.com/docs/reference/connection-types)
4. Arbitrary recursive DNS is also an unintended outbound channel. A trusted system resolver can send a non-admin application's queries under its own UID. Do not expose unrestricted UDP/TCP 53 just because its socket appears privileged.

Therefore separate **application policy** from **trusted Tailscale transport**, and do not offer Tailscale relay endpoints on the application proxy.

## Exact components and installation work

### A. Policy proxy: use a mature TLS/HTTP engine

Candidate: pinned `mitmdump` in regular explicit-proxy mode, with a small, tested policy addon. `uv` and OpenSSL are present locally; `mitmdump`, Squid and Tinyproxy are not currently installed. A new package installation and dedicated runtime account are required. Avoid installing into the user's general Python environment. [Regular proxy mode](https://docs.mitmproxy.org/stable/concepts/modes/#regular-proxy)

Proposed listener is `192.168.64.1:3128`, not `0.0.0.0`; check the port is free before using it. The service must run under a dedicated unprivileged Studio account with a private configuration directory and no access to the user's home data. Host PF admits only the intended guest to that listener. This is not a general Studio remote-control or API proxy.

Security requirements for the addon/configuration:

- Default deny before opening an upstream connection. Use lazy connection establishment, reject unauthorized CONNECT targets early, and disable upstream certificate sniffing if it could dial before policy approval.
- TLS-intercept the approved application destinations; do not use a passthrough/ignore-hosts exception for them. Install only this dedicated CA's public certificate in the guest; private key stays in the proxy account's private host directory. Never install the CA globally on the Studio.
- Validate CONNECT authority, TLS SNI, HTTP Host/:authority and parsed URL agree after strict canonicalization. Reject IP literals, userinfo, ambiguous ports, malformed/multiple authority headers and unapproved names.
- Permit HTTPS/443 only, exact approved hostnames, methods and paths. Prefer the actual subscription API/auth endpoints over broad `*.openai.com`, `*.chatgpt.com`, GitHub/CDN wildcards. Provider endpoint inventory must come from the installed Hermes client, not this document's guess.
- Resolve upstreams in the trusted proxy. Reject loopback, private, link-local, multicast, tailnet, host-local and otherwise disallowed results in either family. Dial only the vetted resolution; do not validate one lookup then let another lookup choose the address. TLS hostname/certificate validation must remain enabled.
- Disable raw TCP, UDP/QUIC, arbitrary WebSocket/HTTP Upgrade and extended CONNECT. If the selected provider truly requires WebSockets, implement a separate narrowly verified endpoint exception; do not re-enable all upgrades.
- A redirect to another domain does not implicitly expand the policy; the next request must pass the same checks. Reject the Studio Funnel hostname even when public DNS returns public addresses.
- Log only coarse allow/deny outcomes and canonical service name; no request headers, query strings, bodies, tokens or TLS secret logs. No mitmweb/admin listener, onboarding web application, or generic CONNECT API.
- Stream successful provider responses so long-running SSE does not buffer forever. Apply bounded headers, connections, timeouts and resource limits without truncating legitimate streams.

Relevant documented options include `rawtcp=false`, `ssl_insecure=false`, and `connection_strategy=lazy`; defaults are not a safe containment policy. Settings alone do not implement the addon checks above. [Mitmproxy options](https://docs.mitmproxy.org/stable/concepts/options/)

Because TLS terminates here, the trusted proxy processes subscription credentials in memory. This is an explicit trust boundary, not end-to-end guest-to-provider TLS. Keeping traffic out of logs is mandatory. If the user does not accept host-side TLS termination, a fixed-upstream provider adapter is an alternative, but its client integration must be built rather than silently disabling TLS inspection.

### B. Host PF: default deny instead of a growing private-address blocklist

Build a separate child anchor, preserve Apple dynamic rules, and verify it is evaluated before conflicting quick-pass rules. Its intended scope is guest physical traffic only:

1. Minimum verified DHCP/address-resolution bootstrap required for the adapter.
2. Guest -> policy proxy `192.168.64.1:3128`.
3. Guest -> restricted resolver on bridge:53, only if the installed trusted Tailscale client needs it.
4. Guest -> a root-managed table of exact Tailscale control/DERP IPs, TCP/443. Deny direct UDP initially, accepting relayed phone connections and extra latency. Do not allow arbitrary Internet TCP/443 or `*:3478` for convenience.
5. Block all other guest physical IP traffic in both families, including direct public Studio/Funnel destinations. Do not introduce an IPv6 pass fallback.

The transport list is a bounded availability dependency: if an approved endpoint moves, connection failure is preferable to automatically broadening access. Fetch/validate the official DERP map from a trusted host process, reject malformed/nonpublic addresses, and require controlled updates. Tailscale documents the DERP map and changing endpoint inventory. [DERP servers](https://tailscale.com/docs/reference/derp-servers)

This still needs the guest layer below: raw access to an allowlisted DERP IP must not be available to Hermes itself. Host PF cannot enforce `user hermes` on a forwarded guest packet: local `man pf.conf` states forwarded socket identity is unknown. Never write a host UID rule and claim it identifies a guest process.

### C. Guest PF: separate trusted transport from untrusted workloads

Root-owned policy, root-owned startup, and root-only modification authority:

- Default deny outbound physical-interface traffic for all ordinary guest accounts.
- Permit Hermes/application UID only to the host application proxy. Environment proxy variables are client configuration, not security enforcement; attempts to bypass them must be denied.
- Permit transport sockets only for the verified effective UID of the trusted Tailscale process, and only to the host-approved transport table. Do not assume the macOS system extension's UID; measure it and test packet ownership. If ownership is unknown or generic helper ownership defeats the distinction, this implementation gate fails.
- Permit the required resolver/bootstrap process only to the restricted resolver. Reject arbitrary DNS queries there, including arbitrary subdomains and nonessential query types; no global recursive-DNS exception.
- Handle tailnet API ingress/replies and guest loopback explicitly. Do not mistake an allow for new outbound tailnet connections for the stateful replies needed by Serve.
- Confirm Hermes cannot change Tailscale preferences, log out/re-enroll the node, configure an exit node or enable outbound SOCKS/HTTP proxies. Inspect LocalAPI permissions from the actual non-admin session. Upstream source distinguishes Unix socket/operator permissions and macOS token-authenticated clients; platform behavior must be tested, not assumed. [Tailscale LocalAPI server source](https://github.com/tailscale/tailscale/blob/main/ipn/ipnserver/server.go)

If the installed GUI/system-extension client cannot provide that locked administrative boundary, change only the guest to a root-managed standalone daemon with locked state/socket/operator access after explicit approval. Do not run a second competing Tailscale implementation beside the current extension.

### D. Tailnet policy remains necessary

Guest node has a service tag managed outside the VM, no broad initiation grant, and only designated phone HTTPS ingress. Preserve existing Studio routes and unrelated peers. A public DERP path carrying valid tailnet traffic does not override a correctly enforced tailnet policy, but a generic relay channel for custom application traffic is why guest transport separation is needed as well.

## Boot and failure behavior

- Root gate must load and validate guest policy before networked Hermes/CUA execution. Stop model tasks if the policy is absent. Do not let an ordinary agent launch a parallel unrestricted runtime.
- Load/validate host policy before allowing the VM's networked execution. Proxy failure should cause connection failure; there must be no direct-Internet fallback.
- Reboot, interface renumbering, DHCP/IPv6 changes, root daemon restart, and PF reload need tests. Current source-IP/bridge probe is not proof of source-independent attachment enforcement.
- A polling watchdog which repairs policy later leaves a gap. It is not a strict fail-closed guarantee. Protect the claim accordingly until an atomic VM/network start boundary exists.

## What requires authorization/participation

Studio administrator authentication: dedicated restricted proxy/resolver account and service, protected files, privileged DNS listener if used, PF policy/startup integration. No global rules/state flush. No changes to old Hermes, Studio Serve routes, public Funnel or unrelated VM networking.

Guest administrator participation: separate non-admin GUI account, CA public-certificate trust, root-owned PF/service setup, and possibly a guest Tailscale daemon migration. The user retains administrator credentials; no password is recorded or made available to Hermes.

Cloud approval: the precise validated tailnet policy/tag diff, with regression tests. Previous rejected automation must not be bypassed.

## Stronger guest-root-resistant alternative

If guest-root compromise is in scope, do not call the design above sufficient. Move the trusted tailnet/relay client outside the untrusted guest or use a gateway which validates the DERP protocol's allowed peer identities while enforcing all egress externally. A generic TLS proxy cannot inspect the encrypted WireGuard payload's ultimate application request.

Apple exposes `VZFileHandleNetworkDeviceAttachment` for a custom VM networking implementation, so Apple Virtualization is not inherently limited to NAT. However, the installed UTM UI does not document its QEMU isolated-host-network facility for this macOS backend. Adopting a custom runner/network backend is real engineering/migration, not an available checkbox. [Apple API](https://developer.apple.com/documentation/virtualization/vzfilehandlenetworkdeviceattachment), [UTM isolated Host Networks](https://docs.getutm.app/preferences/macos/#host-networks)

The minimum workable boundary for this iteration should therefore be stated explicitly: **Hermes/CUA is untrusted but non-admin; guest system services/root, host enforcement, and the approved external services remain trusted.** This is useful protection and consistent with a separate non-admin runtime, but not a proof against operating-system vulnerabilities or public services acting as application-layer relays.

## Tests to implement now

1. Offline proxy tests: allowed request; IP literal; CONNECT/SNI/Host mismatch; disallowed method/path; redirect; raw TCP/Upgrade; private/mixed DNS; resolution rebinding; unavailable proxy. Verify forbidden cases never open an upstream socket.
2. Guest non-admin tests: allowed provider request works; direct public HTTPS, DERP HTTPS, arbitrary DNS, Studio LAN/bridge/tailnet IPv4/IPv6 and Funnel URL fail; no local API write authority. Repeat from a subprocess ignoring proxy variables.
3. Trusted Tailscale daemon remains online through the restricted transport path; phone reaches guest HTTPS and streams replies. No unsolicited guest tailnet initiation succeeds.
4. Proxy stop and policy/address/lifecycle faults fail closed under the chosen non-admin threat model; unrelated Studio/phone services still work.

No component described here is installed or verified by this document.

# Studio protection — independent implementation review

Date: 2026-09-13. Scope: read-only review; no host, VM, cloud, or app settings changed. This is not an installed policy.

## Decision

Keep the selected direct phone → guest Tailscale HTTPS architecture and the existing tailnet. Preserve the Studio's old Hermes and other routes. Defer oMLX. The transport choice does not itself isolate the guest.

**Practical containment is achievable, but the present evidence does not establish a fail-closed production boundary.** The next step should be a scoped IPv4/IPv6 enforcement prototype and lifecycle tests, not simply promoting the successful probe to a permanent launch daemon. Keep Hermes execution and model sign-in stopped until the protection gates pass.

There are two distinct security claims:

1. Prevent a non-admin Hermes runtime from directly reaching host resources through known local/tailnet paths. This is the practical target of host filtering, tailnet policy, and disabled integration.
2. Prevent any guest workload, including one with guest root or an arbitrary public relay, from interacting with any publicly exposed Studio service. That is a materially stronger claim. With unrestricted Internet and the existing public Studio Funnel preserved, private-address block rules cannot prove it. It needs externally enforced restricted egress or an explicitly accepted public-service exposure limitation.

Do not silently substitute claim 1 for claim 2.

## Evidence inspected

- `docs/vm-network-enforcement-plan.md`, `docs/hermes-sandbox-migration.md`, tailnet audit/draft, and both PF probe files.
- Current read-only `ifconfig bridge100` still shows host IPv4 192.168.64.1, ULA IPv6, link-local IPv6, one member vmenet0, and learned guest MAC 76:c3:f5:03:9c:44. Bridge reports `ipfilter disabled`; the recorded successful PF test nevertheless proves one actual IPv4 path can be filtered. Neither observation proves all bridge paths are covered.
- Recorded synchronized test proves the source-IP/bridge100 rule blocked a new guest IPv4 TCP connection to 1.1.1.1:443 and recovery followed removal. Recorded vmenet0 counter was zero. A ruleset entry alone is not proof the hook sees packets.
- The reviewed tailnet draft excludes current guest addresses from broad grants. It does not identify a newly enrolled guest by role automatically.
- Public Funnel DNS resolves to relay addresses rather than the protected node's own address. The receiving node terminates the relayed TLS request. Blocking the Studio's own private/public interface addresses therefore does not cover its Funnel URL. [Official Funnel documentation](https://tailscale.com/docs/features/tailscale-funnel)

## Concrete implementation sequence

### 1. Establish guest privilege and sharing boundaries

- Run Hermes and CUA in a separate non-admin guest login session. Do not merely launch Hermes as a second user while CUA controls the provisioning administrator's desktop.
- Leave no provisioning password, host token, host browser session, Tailscale administrative credential, or reusable privileged helper available to that session.
- Keep host directory sharing, clipboard integration, and host desktop-control integrations disabled. Guest CUA permissions do not authorize host automation.
- Guest root-owned controls can be useful additional protection, but must not replace externally enforced controls when the threat model includes guest privilege escalation.

### 2. Verify the host filtering scope before installing it

- Test IPv6 separately: guest global/ULA/link-local addresses and the host's bridge, LAN, and tailnet addresses. An IPv6 timeout alone is inconclusive unless a positive baseline or a controlled listener and counters establish the path.
- Test a source-independent guest-ingress rule if the interface hook supports it. Current evidence supports bridge100 plus a guest source address, not vmenet0 as an independently proven attachment boundary.
- Do not use an entire shared bridge as a guest-only boundary without proving exclusive ownership. Another VM can later join it. Do not rely on a cached MAC-to-port entry as permanent ownership proof.
- If source-IP scoping is retained for a non-admin threat model, explicitly document that guest-root source spoofing/address changes are not covered. Monitor exact VM adapter and address identity, and suspend execution on mismatch. An asynchronous monitor is not an instantaneous fail-closed boundary.
- Reject production deployment if no exclusive attachment or trustworthy lifecycle mechanism can enforce the selected threat model. UTM documents isolated Host Networks as QEMU-only; the current macOS guest uses Apple Virtualization. A second firewall VM alone does not create an isolated path. [UTM Host Networks](https://docs.getutm.app/preferences/macos/#host-networks)

### 3. Install only a scoped host policy after the probe gates

- Use a dedicated child anchor reached before conflicting quick-pass rules. Preserve Apple's dynamic internet-sharing rules and unrelated state. Never reload global pf.conf or flush global state as a shortcut.
- Deny guest-initiated IP traffic to host interface addresses and relevant local destination ranges, including host link-local/ULA and global IPv6 addresses. Treat multicast/local discovery separately. Allow only the minimum network bootstrap traffic required; a blanket same-subnet pass would reopen host services.
- Cover host address changes. Dynamic PF interface-address syntax, if used, needs testing for the installed macOS version and actual interface set; it is not a tested fix yet.
- Existing established states may survive a new block. Test a pre-existing controlled connection as well as fresh connections. Remove only precisely identified guest test states if needed and approved; never other devices' states.
- Root-own enforcement files and launch configuration. Validate at boot and VM start before the guest is allowed networked execution. A launch daemon that restores missing rules after a delay is recovery, not strict fail-closed behavior. Test OS network-service/PF reload and VM restart rather than assuming persistence.

### 4. Restrict the Tailscale path separately

- Use an admin-owned sandbox tag without giving Hermes authority to enroll nodes, assign tags, or change cloud policy. Tagging replaces the node's user identity; inspect consequent SSH, Funnel capability, and key-expiry effects. [Official tags documentation](https://tailscale.com/docs/features/tags)
- Grants are allow rules under deny-by-default behavior. Existing wildcard access must be narrowed; adding a restrictive rule beside the wildcard cannot subtract permission. [Official grants documentation](https://tailscale.com/docs/features/access-control/grants)
- Preserve unrelated user/shared/ingress access explicitly. Do not save the obsolete member-only draft. The current address-exclusion draft is a limited migration candidate, not a role-based solution across re-enrollment.
- Allow the designated phone to initiate only guest HTTPS. Verify response traffic works without granting the guest broad initiation privileges. Check both phone address families and both guest families.
- No guest subnet routes, exit-node route, Funnel, or host inference exception in this phase. Do not change unrelated devices' independent routes.
- Prior cloud-save rejection remains a real approval constraint; do not work around it through a different API or tool. Fresh validated diff and required approval are prerequisites to a new save.

### 5. Resolve the public-service gap explicitly

- Ordinary unrestricted TCP/443 egress permits public relays, proxies, and the Studio's Funnel. DNS blocking and a snapshot of relay IPs are not a robust no-access guarantee.
- A strict solution needs a trusted default-deny egress gateway/proxy with a verified path that cannot be bypassed. Provider-specific HTTPS, DNS, Tailscale control/relay, and necessary maintenance flows require separately validated allowances. CONNECT-by-hostname alone is not proof of destination identity when the tunnel can reach shared infrastructure.
- This will restrict arbitrary browser/computer-use Internet access. If unrestricted browsing is desired, protecting publicly exposed host applications instead depends on their application authentication and hardening, and the result must not be described as network unreachability.
- Do not disable the existing Studio Funnel without explicit user authorization. No host-proxy addition or separate tailnet is necessary merely for Tether ingress.

## Acceptance matrix

| Gate | Evidence required |
|---|---|
| Direct phone → guest API | Authenticated response over guest HTTPS; anonymous and invalid token requests rejected |
| Guest → host shared-network IPv4/IPv6 | Controlled baseline then denied fresh connections, relevant rule counters, no alternate host-address route |
| Guest → Studio tailnet IPv4/IPv6 | Effective policy validation plus observed denial; phone → Studio routes still pass |
| Public Studio Funnel | Explicitly blocked through public DNS/relay path, or clearly accepted narrower protection model |
| Guest restart/address change | No usable unfiltered interval under the claimed threat model; identity mismatch prevents networked execution |
| PF/network reload | Enforcement persists or guest networking stops before a gap; merely restoring it later is insufficient for fail-closed wording |
| Existing sessions | Controlled established-session result documented; unrelated sessions preserved |
| Other VM/devices | Their normal routes remain unaffected; no shared-bridge collateral block |
| Guest-only CUA | Non-admin guest GUI session; no host mounts/clipboard/host-control endpoints |

## Immediate useful next action

Run a temporary, explicit IPv6 counterpart to the successful IPv4 probe and a controlled host-address probe while Hermes remains stopped. At the same time, validate a role-safe tailnet policy diff without saving it. These yield actionable evidence without installing an unproven permanent security boundary.

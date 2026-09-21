# VM network enforcement: verified basis and remaining gates

Status: diagnostic phase passed for one IPv4 flow; permanent isolation NOT installed.

## Selected approach — user approved

User approved **approved-service-only internet egress** after being told it limits general browser/computer-use internet access. The outstanding policy-choice blocker is resolved. Implement and verify this restriction outside the agent-controlled runtime; do not substitute unrestricted Internet plus host application authentication. This approval does not prove a suitable topology exists or authorize unrelated host service changes. Required administrator authentication and action-time security approvals still apply.

Direct Tether → guest Tailscale HTTPS → guest Hermes API, using the existing tailnet. Keep the Studio's original Hermes/API routes unchanged during migration. Do not create a separate identity/tailnet or Studio API proxy. Protect the Studio from VM-initiated access with outside-guest enforcement and guest privilege/sharing separation. A successful request from Tether to Studio is not a failure condition; unwanted Hermes-to-Studio access is. Earlier separate-tailnet/gateway discussion below is alternatives research, not the chosen implementation. oMLX remains deferred.

## Simpler alternative evaluated

On the user's request for a better approach, checked official UTM and Tailscale documentation. A dedicated sandbox tailnet with the Hermes node shared into the personal account is a cleaner candidate for tailnet separation: sharing quarantines the shared node by default so it can receive connections but cannot initiate connections into the recipient tailnet. This avoids rewriting the personal tailnet's broad grants solely to carve out this VM. The sandbox identity must remain separate, and its administrative browser session must stay outside the agent guest. Sharing is user-scoped, not inherently phone-only; port/client restrictions and bearer authentication still need validation. LAN and public-endpoint containment remain separate requirements. No new account, share or device migration has been performed.

A dedicated firewall/gateway would be a stronger structural LAN boundary only if the guest has no alternate path to the host or uplink. UTM documentation currently limits its isolated custom Host Networks to the QEMU backend; this existing macOS guest uses Apple Virtualization. Therefore do not add a second gateway VM and claim it isolates this macOS guest without validating a supported private network attachment or choosing a different network topology.

Sources checked: https://tailscale.com/docs/features/sharing (quarantine, user scope, access policies); https://docs.getutm.app/preferences/macos/#host-networks (QEMU-only isolated host networks).

## Observed, not assumed

- Guest HTTPS to 1.1.1.1 succeeded before the temporary PF block, timed out in 5 seconds inside its active window, and succeeded after the probe exited.
- The existing bridge100 hook can therefore block that guest IPv4 flow. vmenet0 has not demonstrated matching traffic in the supplied counters.
- Guest TCP to Studio Tailscale IP port 443 succeeded. TLS then failed; this is proof of network reachability, not authenticated API access.
- IPv6 is active in the guest. An IPv4-only firewall is insufficient.
- Studio's existing public Funnel forwards HTTPS to port 5678. Public access can bypass private-address restrictions and must be considered separately.
- Studio administrator authentication is unavailable to agent shell commands. The user only needs to authenticate host changes; guest-side tests can be operated by the agent without clipboard sharing.

## Required design

1. Enforce guest LAN/host restrictions outside the agent-controlled guest. Preserve Apple's dynamic PF anchors and other VM traffic. Do not reload the main ruleset or flush global states.
2. Cover IPv4, IPv6, host addresses, local subnets and same-bridge peers. Explicitly scope interface ownership; the current IP/MAC alone is not a security boundary against an administrator-capable guest. Interface reuse, DHCP changes, VM restart and PF reload must not silently remove enforcement.
3. Restrict the guest's Tailscale identity separately: no new connections to unrelated peers; only the designated phone may initiate Hermes HTTPS. Preserve non-VM grants and existing host routes. Validate the policy and regression tests before any approved save; the current IP-exclusion draft is not deployment-ready and cannot safely handle VM re-enrollment automatically.
4. Run Hermes under a non-admin guest identity, with no reusable provisioning credentials, host mounts or clipboard bridge. Guest CUA must not expose privileged host controls.
5. For strict protection including public endpoints, use externally enforced destination-limited egress. A private-address deny list plus unrestricted Internet cannot guarantee no access to publicly exposed Studio services or third-party relays. A trusted gateway/proxy is required if this stronger boundary is the user's requirement; do not represent the current shared network as that gateway.

## Acceptance gates before model credentials and migration

- Positive: required provider HTTPS and phone-to-Hermes authenticated HTTPS work.
- Negative: anonymous API requests, guest-to-Studio/LAN/other-tailnet connections, unintended IPv6 paths, and public-Studio-service access are denied by the appropriate control.
- Preserve other devices' existing routes and permissions; do not turn off their Funnel/SSH as a shortcut.
- Verify fresh connections, relevant existing connections, guest reboot/address changes and enforcement restart behavior. Do not kill other devices' states to achieve a test result.
- Review VM admin separation and test guest-only computer use.
- Then configure the user-approved subscription provider, test durable jobs, and migrate Tether using a separate saved connection.

Reference: UTM shared networking places the VM on a host-managed network; it is not by itself a containment policy: https://docs.getutm.app/settings-apple/devices/network/
Reference: Tailscale grants are the tailnet access-control layer: https://tailscale.com/docs/features/access-control/grants

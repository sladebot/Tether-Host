# Offline PF implementation tools

These tools implement evidence collection and deterministic **prototype** rule generation only. They never load rules, enable PF, flush state, change cloud policy, or establish a production isolation boundary.

Run the read-only host audit:

```sh
python3 scripts/isolation/audit_pf.py
```

It collects root and recursive child-anchor rules (including NAT), PF status, interfaces, and application-firewall status. Exit 2 means some evidence could not be collected. PF reads generally require administrator authentication; the collector does not request passwords or invoke sudo. An administrator may run it in their own terminal after reviewing the source. Missing permissions mean **unknown**, not inactive. The output contains local network addresses; review before sharing.

## Generate a candidate

Supply JSON with exactly these fields:

- `interface`: the measured packet hook, for example `bridge100`.
- `guest_addresses`: explicit observed IPv4 and IPv6 literals, including all relevant guest link-local addresses. Both families are mandatory; completeness must be tested live.
- `proxy`: `null`, or `{ "address": "<measured bridge address>", "port": 3128 }` after the approved TLS policy proxy is implemented.
- `resolver`: `null`, or `{ "address": "<measured bridge address>", "port": 53 }` after the restricted resolver is implemented.
- `transport_addresses`: exact verified public Tailscale control/DERP IP literals. Empty is valid and denies transport. Do not copy arbitrary public addresses or guess provider endpoints.

```sh
python3 scripts/isolation/pf_policy.py /absolute/path/to/measured-inventory.json
python3 -B -m unittest discover -s scripts/isolation -p 'test_*.py' -v
```

Rules are emitted to stdout for review, with deterministic address order. They permit only specified infrastructure and exact TCP/443 transport addresses, followed by a deny for each supplied guest source. No broad HTTPS, bootstrap, IPv6, or DNS fallback is generated. No deployment script is provided.

## Required before deployment

Source-address matching does not cover source spoofing, new addresses, an unobserved hook, shared-bridge ownership changes, or existing states. The current successful IPv4 probe does not resolve any of these. Verify attachment ownership, IPv6 paths, early child-anchor evaluation, controlled existing/fresh sessions, and a startup/reload boundary with no unfiltered interval. A polling repair loop cannot establish this last property. A syntax-accepted rule is not proof packets traverse it.

The host transport allowance also permits any guest process to reach those IPs. The selected design therefore requires separately tested guest PF ownership rules for the trusted Tailscale daemon, a non-admin GUI runtime, locked Tailscale administration, a mature TLS/HTTP proxy enforcing approved provider methods/paths and vetted DNS dialing, a restricted resolver, and validated tailnet grants. The exact provider endpoint inventory is still required. Do not sign in the model or launch networked Hermes based on these candidate files.

The generator has no automatic production-ready state. Full approved-service containment still requires live topology, lifecycle, and negative-test evidence.

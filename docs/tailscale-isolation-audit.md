# Tailscale isolation audit — 2026-09-13

## Status

Read-only audit complete for the console inventory and Studio-visible route metadata. No live policy, tags, routes, sharing, or firewall settings changed in this audit. The browser still has the obsolete member-only draft; DO NOT save it. The VM is not isolated. The new `tailscale-hermes-vm-only.DRAFT.json` is a candidate, not Tailscale-server-validated or applied.

## Observations

- Console has eight machines, all currently user-owned/untagged, including Hermes VM. Two direct tailnet users (owner and another member); the second user's MacBook is not simply a shared external user.
- Studio peer metadata includes Tailscale-managed Funnel ingress nodes with `tag:ingress` and `ShareeNode=true`. Do not treat these as user-owned devices or replace access blindly with member-only rules.
- No exit-node options or primary routes were reported for the inventoried peers. This is metadata, not proof that every possible external shared path has been exercised.
- Studio Serve: 443 → localhost:5678 with Funnel enabled; 8443 → localhost:3000; 8444 → localhost:8787; 8445 → localhost:8642. Preserve all four.
- Original policy's operative sections: wildcard source/destination all-protocol grant; member-to-self SSH check; member Funnel capability. Backup is `tailscale-before-hermes-isolation.json` (operational JSON, not original comments).
- Local Homebrew CLI 1.94.2 warns it differs from installed server 1.98.9. Read-only status and Serve queries succeeded with sandbox escalation. Do not upgrade or restart services as part of this audit.

## Narrow candidate

Replace only wildcard grant matching with an address set containing every IPv4/IPv6 address EXCEPT the VM's observed two addresses. The set uses four documented address ranges, avoiding the previously rejected `/0` and `add *` IP-set syntax. Preserve SSH and nodeAttrs contents unchanged. Add phone's observed IPv4 AND IPv6 → VM's observed IPv4 AND IPv6 TCP 443.

This is mathematically narrower than changing global access to member-only: for any source and destination neither of which is the VM, the original all-protocol network grant remains. Covers other members, shared/ingress nodes, tagged devices and subnet/exit destinations at the network-policy level; does not claim end-to-end availability or alter independent sharing restrictions.

## Required gates before use

1. Validate syntax and policy tests using Tailscale without conflating browser draft persistence with save success. Do not bypass prior automation safety rejection via API/CLI or another tool. Obtain action-time approval before a new cloud-policy save.
2. Confirm VM and phone addresses still match. VM deletion/re-enrollment or address changes require updating this IP-bound policy BEFORE allowing Hermes to run; this is not fail-closed across re-enrollment. Tag alone does not repair this dependency.
3. Assign only VM the admin-owned sandbox tag so it no longer inherits member SSH/Funnel capabilities. Tagging may change key-expiry behavior; inspect before/after. Do not issue agent-accessible tag-owner/auth/API credentials.
4. Positive checks from phone to guest HTTPS with bearer auth and to existing Studio private routes; preserve existing public Funnel behavior. Negative tests from VM to Studio, all peers, both IP families, SSH/dashboard/raw API ports. Test connection continuation and stateful return traffic.
5. Independently block guest access to Studio/LAN and host public services, including IPv6. Tailscale ACLs do not filter the VM's ordinary NAT internet/LAN traffic. Studio has a public Funnel endpoint; simply blocking RFC1918 addresses will NOT prevent reaching that public endpoint. No complete containment claim until this path is addressed.
6. Keep Hermes stopped and subscription authentication deferred until containment and non-admin runtime are ready.

## Source

Tailscale documents IP address ranges and IP-set use in grant sources/destinations: https://tailscale.com/docs/features/tailnet-policy-file/ip-sets

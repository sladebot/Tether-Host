# Hermes VM migration: team implementation plan

## Current execution order (supersedes isolation-first order below)

User now requests functionality first, isolation later. Active goal: configure and verify guest Hermes with OpenAI subscription authentication, loopback bearer-protected API, guest tailnet HTTPS, separate Tether phone profile, and live chat/build/edit/recovery/approval/stop/guest-CUA acceptance. Defer firewall, tailnet restrictions and non-admin hardening. Existing host services and rules remain in place; oMLX remains deferred. Historical isolation prerequisites below are not blockers for this functionality phase.

## Objective and scope

Complete direct Tether → existing tailnet → guest HTTPS → non-admin Hermes,
using guest-local OpenAI subscription authentication. Protect Studio resources,
restrict guest internet access to approved services, and preserve existing Studio
services and other devices. oMLX remains deferred.

This plan supersedes the stale numbered remaining-gates section in
`hermes-sandbox-migration.md`; the latest scope paragraph there still applies.
The user requested implementation with a team. Three agents worked on network
tooling, guest readiness, and Tether integration. Deployment remains incomplete.

## Ordered implementation and acceptance

| Phase | Concrete work | Acceptance | Current status |
| --- | --- | --- | --- |
| 1. Inventory | Collect recursive live PF status/rules/anchors, exact VM interfaces/addresses, guest runtime identity and installed provider source endpoints | Administrator-readable evidence and verified guest command output | Audit tools built; live PF requires password; guest keyboard input unreliable |
| 2. Enforcement components | Implement application policy proxy and restricted resolver from verified provider inventory; validate guest transport ownership; generate exact destination PF candidates | Forbidden requests never open upstream sockets; both IP families covered; no generic HTTPS/relay bypass for Hermes | PF candidate generator implemented; proxy/resolver and guest transport separation pending |
| 3. Deployment | Install reviewed host/guest restrictions and validated narrow tailnet policy; establish non-admin guest runtime | Negative Studio/LAN/tailnet/public-Funnel tests, allowed phone ingress, reboot/reload/address-change tests, unrelated connectivity preserved | Pending; no permanent enforcement deployed |
| 4. Backend | Fresh subscription sign-in; guest-specific API key; loopback listener and private guest Serve; non-admin CUA | Advertised durable API capabilities, valid HTTPS, denied anonymous/wrong key, actual guest capture/control | Readiness checker built; live setup pending isolation |
| 5. Phone acceptance | Separate VM profile; chat/build/edit; disconnect and app-close recovery; approvals/stop; gateway restart | No duplicated runs or artifacts; truthful interrupted-run recovery; existing profile preserved | Migration observer race fixed and regression-tested; live E2E pending |
| 6. Handoff | Clean powered-off snapshot and recovery instructions | Reproducible startup/unlock and documented limitations | Pending |

## Implemented this pass

- `scripts/isolation/audit_pf.py`: read-only host evidence collector, including
  recursive anchors. Permission errors remain unknown, never reported as disabled.
- `scripts/isolation/pf_policy.py`: deterministic offline candidate generator,
  exact IP destinations, IPv4/IPv6 default denies, strict input validation.
  This source-address prototype does not establish spoofing/address-change,
  existing-state, attachment, or startup protection. Do not deploy it as complete isolation.
- `scripts/guest/audit_readiness.py`: guest identity/config metadata/listener
  inventory and optional bounded loopback API discovery with filtered output.
  It does not read saved credentials; exit zero only verifies expected non-admin identity.
- `Tether/App/AppModel.swift`: freeze the conversation ID before network awaits;
  ignore cancelled submission/status responses and errors to prevent stale
  observers from modifying the newly selected connection/conversation.

## Verification

- Network tooling: 7 unit tests passed; agent also validated a generated candidate
  using macOS PF syntax-only mode, without loading it.
- Guest tooling: 8 unit tests passed.
- Tether: rebuilt suite passed 35 tests, zero failures/skips, result bundle
  `/tmp/tether-team-migration-patched-tests-20260914.xcresult`.
- `git diff --check` passed. Existing unrelated edits were preserved.
- The Swift tests do not directly simulate the specific UI cancellation race;
  the fix was reviewed and compile/regression-tested.

## Current access evidence and next operator action

Host `sudo -n /sbin/pfctl -s info` still reports a password is required.
UTM now returns the Hermes Sandbox window and screenshot, so earlier complete
window-access failure is no longer current. Guest input still misinterprets
characters/modifier keys; attempted diagnostic commands did not produce reliable
execution evidence. Do not infer guest state from those attempts. Clipboard
sharing was not enabled. Host source under the separate jarvis account was
unreadable; required subscription endpoint inventory is still unverified.

In the Studio Terminal, the user can collect the missing live PF evidence with
standard built-in tools (all commands read-only):

```sh
sudo /sbin/pfctl -s info
sudo /sbin/pfctl -a '*' -vvsr
sudo /sbin/pfctl -a '*' -vvsn
sudo /sbin/pfctl -a '*' -s Anchors
```

These commands require local administrator authentication; no password should be
sent in chat. Subsequent deployment also requires reliable guest command access.
An administrator evidence dump alone does not make the unfinished proxy/resolver,
tailnet restrictions, or lifecycle enforcement ready for installation.

# Studio desktop-control window-access investigation

## Findings

Desktop automation is failing before it returns either an accessibility tree or a screenshot. UTM is running and visible in the remote desktop, but CUA's `getApp` returns `cgWindowNotFound` (-10005). Finder and the visibly open System Settings application fail similarly. Application inventory succeeds. This establishes a cross-application window-attachment failure, not a failed VM or a missing UTM process.

The exact internal cause remains unproven. The strongest current explanation is a GUI-session/window-selection incompatibility in the computer-use helper. Effective capture authorization remains a competing explanation because enabled switches do not expose the helper's internal authorization decision. No specific permission-denied response was found in the narrowly inspected helper logs.

This is not evidence that Jump Desktop is faulty or that the operator logged into the wrong account. Nor does the error prove that UTM is closed. Repeated requests to restart UTM or unlock the same remote desktop were not justified by a discriminating test.

## Local evidence

Observed September 13, 2026, on Studio:

| Check | Result | Interpretation |
| --- | --- | --- |
| CUA application inventory | Lists UTM, Finder, System Settings and other running apps | Tool transport and application discovery operate |
| UTM window attachment | Repeated `cgWindowNotFound` | No screenshot or accessibility tree returned |
| Finder window attachment | Same error | Not specific to UTM |
| Open System Settings attachment | Same error | Not explained merely by Finder having no open window |
| Login-window attachment | `timeoutReached` | Does not establish that CUA can see the physical login screen |
| Process ownership | UTM, ChatGPT and helper run as souranil | Old host jarvis account is not the execution user |
| Task application permissions | UTM and Finder explicitly allowed | Not a missing task allowlist entry |
| Screen-recording screenshot | ChatGPT and Codex Computer Use enabled | Simple disabled-switch explanation excluded |
| Accessibility screenshot | Helper enabled; main ChatGPT initially disabled | Initial permission discrepancy existed |
| After enabling main Accessibility | UTM still fails | That discrepancy alone did not explain failure |
| Tool runtime reset | No improvement | Not just stale JavaScript bindings |
| Full application restart | Fresh main/helper processes; no improvement | Not simply the original helper remaining alive |
| Direct TCC database inspection | macOS authorization denied | Effective database state was not established; no bypass attempted |

Latest recorded app version was 26.908.40834, helper build 1000968. A restart was verified by fresh main PID 14691 and helper PID 15170, started at approximately 22:21 PDT. These identifiers are diagnostic history, not targets for future process termination.

The console metadata contains several host sessions. The root/login session is marked on-console, while souranil is not. A locked flag appears on the separate old host jarvis session. The VM's guest account, also named jarvis, is unrelated to this host session record. A global grep for a locked flag incorrectly attributed that other session's flag to souranil; it must not be used again as proof that souranil is locked.

## Research and applicability

Apple documents that Core Graphics window enumeration is scoped to the current user session, can return no matching windows, and can fail outside a GUI security session. This supports investigating session attachment, but it does not prove which API or filter the proprietary helper uses for this particular error.[1]

OpenAI's computer-use documentation describes a separate, explicitly enabled locked-use authorization mechanism. It is not a general remote-unlock capability and is restricted to eligible trusted turns. Accordingly, ordinary process liveness and remote desktop visibility cannot alone prove that the computer-use capture path is usable.[2] The local SecurityAgentPlugins directory listing showed no entries during this investigation; this does not by itself identify the cause for a remotely visible desktop.

Firsthand reports in OpenAI's issue tracker describe the same error with running, inventoried applications in both unlocked and locked environments. Issue 30797 reports failure on an unlocked desktop; issue 26743 describes a locked-use attachment failure; issue 24086 reports a Mac mini/Studio Display case.[3–5] These reports corroborate the failure class, not an exact root cause or a confirmed fix for the currently installed newer build. Treat their older versions and distinct environments as important limitations.

A Jump Desktop support article discusses screen-recording permissions, but concerns Catalina and was updated in 2020.[6] It cannot establish that modern Jump Desktop is responsible here. Passwordless-login or alternate remote-access configuration changes are not justified by this evidence.

## Discriminating next tests

1. Test an ordinary visible application from a fresh local Codex task in the same souranil desktop. Success there would narrow the failure to this task/connected-device path; failure would implicate the installation/session more broadly. Do not start a duplicate VM setup task.
2. If available, perform a single comparison with souranil physically active at Studio's console, without logging out, disabling security, or changing the VM. A success only there would support the console/session hypothesis. The earlier general instruction to repeatedly unlock remotely is not an equivalent test.
3. If both fail, provide a sanitized reproduction to OpenAI support: exact app/helper versions, enabled permission screenshots, successful inventory followed by failed UTM/System Settings attachment, and fresh-helper restart evidence. No tokens, private browser URLs, raw launch arguments, or credentials are needed.

These tests require either another product session or physical interaction that the failing CUA connection cannot perform. No repair is claimed. No firewall, account, clipboard, VM, login mechanism or permission database was modified by this investigation. Do not kill WindowServer, reset all privacy permissions, delete helper installations, or enable broad remote access as speculative remedies.

## Sources

1. Apple Developer Documentation, [CGWindowListCopyWindowInfo](https://developer.apple.com/documentation/coregraphics/cgwindowlistcopywindowinfo(_:_:)), retrieved September 13, 2026.
2. OpenAI, [Computer Use](https://learn.chatgpt.com/docs/computer-use), including Locked use and Safety guidance, retrieved September 13, 2026.
3. OpenAI issue tracker, firsthand report [Computer Use get_app_state for Chrome returns cgWindowNotFound while Chrome is running, #30797](https://github.com/openai/codex/issues/30797), July 1, 2026.
4. OpenAI issue tracker, firsthand report [Locked Computer Use stays on loginwindow, #26743](https://github.com/openai/codex/issues/26743), June 6, 2026.
5. OpenAI issue tracker, firsthand report [Locked Computer Use fails on Mac mini M4 + Studio Display, #24086](https://github.com/openai/codex/issues/24086), retrieved September 13, 2026.
6. Jump Desktop Support, [Mac: Upgrading to Catalina and Fluid Remote Desktop Protocol](https://support.jumpdesktop.com/hc/en-us/articles/360034961971-Mac-Upgrading-to-Catalina-and-Fluid-Remote-Desktop-Protocol), updated March 18, 2020; historical context only.

Local evidence also includes the two supplied permission screenshots and this task's read-only diagnostic outputs. Screenshots contain private desktop context and are not reproduced in a public report.

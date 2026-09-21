# Tether → Hermes VM integration review

Reviewed 2026-09-13 against the existing dirty worktree. Scope: direct HTTPS to a Hermes VM on the existing tailnet; Studio isolation takes priority and oMLX access is deferred. No real Hermes requests, credentials, phone installs, or shared GUI operations were used for this review.

## Cutover and credential handling

Use the VM's Tailscale Serve HTTPS hostname and a credential issued for that VM. The app accepts a bare Tailscale hostname and adds HTTPS; it rejects URL user/password, query strings and fragments. Normalization removes trailing slashes and a terminal `/v1` suffix. Keychain API credentials include the normalized base URL and use device-only accessibility after first unlock.

Confirmed bug: the editor initially populated the old credential, then allowed changing the server address and testing with that credential. The model subsequently removed the old Keychain entry but saved the supplied credential against the new address. Origin-bound storage alone did not prevent this disclosure.

Patched `ConnectionEditorView.swift`: track the credential's normalized URL, clear it on address/route changes that change that URL, clear on protocol changes, and guard Test and Apply against a stale origin before any request. Equivalent normalized addresses preserve the entered credential. The editor explains that changing an existing server/protocol creates a separate connection, preserving the original conversations and builds. Root agent owns that corresponding model behavior.

Queued work originally bound only to a connection UUID. Mutating that connection's URL would retarget unsubmitted work and poll old run IDs on the new VM. Root implemented new-UUID connection creation for changed origin/protocol instead of retargeting existing profiles, and detaches the chat observer before switching. Old work remains on the old profile. Environment bootstrap is deliberately ignored when saved connections already exist, so setting a new `TETHER_API_URL` alone does not perform a cutover.

## Async execution and recovery

Chat checkpoints the input, history, idempotency key and assistant message ID before submission. Mini-app builds similarly persist a job before returning success to the form. Both submit to `/v1/runs`, retain returned run IDs, and reconcile terminal status. Closing the app detaches observation rather than calling the server's stop endpoint. Mini-app saves use deterministic IDs to prevent duplicate imports; repeated identical saves preserve rollback HTML. Run persistence across a Hermes VM/server restart still depends on the installed server's behavior; the app treats an explicit `interrupted` status as terminal.

Remaining review findings:

- Fixed during follow-up: HTTP 404/409/410 no longer loop indefinitely. Chat shows a terminal error without replacement submission; mini-app checkpoints are preserved in a paused state. Check saved build reuses the saved identity; Discard saved build requires confirmation and removes only the local checkpoint. Creation/edit/rollback stay disabled until that saved job is resolved or discarded.
- Only the selected conversation's pending chat is resumed locally. A submitted server run continues, but a queued request with no run ID in another conversation is not submitted until that conversation is selected. This distinction should be visible in chat history.
- Mini-app-only submission does not acquire the chat background grace task. If the app is closed before server acceptance, the saved queue resumes on return; execution is not guaranteed to begin while iOS suspends the app. Current form copy correctly qualifies continuation as occurring once accepted by Hermes.
- Dashboard legacy streaming is not equivalent to durable API runs. Keep VM setup on API Server transport.
- Fixed during review: chat pending model choice was looked up from current conversation at submission time; it is now frozen in the queued record. Legacy records without this field decode with a nil choice (server default).
- Tests currently do not exercise real SwiftUI editing, lifecycle race conditions, HTTP redirects, or expired server run retention. Origin changes and delayed acknowledgments need additional focused regression coverage.

## App-specific chat and mentions

Mini apps have an Edit chat with on-disk history, a Preview tab, and a rollback menu. Update requests include the current HTML and preserve the existing app ID; successful update receipts are deduplicated using the job ID. A general-chat mention selected from suggestions sends the current HTML as reference data and instructs Hermes to discuss changes, leaving actual application to Edit chat.

Limitations: edit history is displayed locally but not included in subsequent edit prompts (only the latest request/current HTML is sent). A manually typed `@title` without selecting a suggestion does not attach an app. Mention attachment selection is transient UI state and is not recorded as structured metadata in the saved user message; queued server input does retain the included HTML. Mention query detection splits on spaces, not all whitespace. These are product follow-ups, not VM networking prerequisites.

## Verification

Created a fresh, isolated simulator `Tether VM Review Tests` (`14EEE4C5-024C-4960-B8E4-E072BE493C08`) with no saved app connections or credentials. Explicitly removed `TETHER_API_URL`, `TETHER_API_TOKEN`, `TETHER_SMOKE_PROMPT`, and `TETHER_SMOKE_MINI_APP` from test command environment. Scheme contains no bootstrap variables.

- `xcodebuild -project Tether.xcodeproj -scheme Tether -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build-for-testing -quiet`: passed.
- Isolated `test-without-building -parallel-testing-enabled NO`: 27 passed, zero failed/skipped; `/tmp/tether-vm-review-tests.xcresult`.
- Rebuilt and ran `test -parallel-testing-enabled NO` after the credential clearing/guard patch: exit 0; `/tmp/tether-vm-review-patched-tests.xcresult`. Subsequent explanatory text and root model changes require root's final combined test pass.
- Final combined build/test after editor copy, root identity/model changes and three added regression tests: **30 passed, zero failed/skipped**, confirmed from `xcresulttool get test-results summary`; `/tmp/tether-vm-review-combined-tests.xcresult`. Added tests verify equivalent URLs retain identity, host/port/scheme/protocol changes get a fresh identity without mutating the original, and frozen model choices roundtrip while legacy pending JSON remains readable. `git diff --check` passed.

Existing tests cover request authentication/model routing/idempotency headers, steering conflict handling, approval decoding, persisted mini-app identity/update target, deterministic update/rollback, URL validation/normalization, token data encoding and HTML isolation. They do not constitute a live VM end-to-end test. No host isolation claim is made from these app tests; network enforcement is reviewed separately.

## Durable readiness follow-up

New submissions require advertised run submission/status/events/stop and idempotency `supported=true`, `durable=true`, with positive retention. Missing capability endpoint, missing/false guarantees, invalid JSON and malformed capability types surface an unsupported durable-run contract rather than readiness or infinite reconnects. Already-accepted run IDs remain recoverable without gating on a new capability response. Authentication errors remain distinguishable from unavailable persistence.

Recovery controls fit horizontally when space allows and stack for larger text. This was compile-tested; no GUI/accessibility runtime inspection was performed in this review.

Final follow-up combined suite: **35 passed, zero failures/skips**, confirmed with `xcresulttool`; `/tmp/tether-durable-malformed-tests.xcresult`. Five added tests cover unsupported capability matrices (including missing/false feature flags and durable idempotency/retention), capability 404 versus 401/403, malformed JSON/types, terminal versus transient failure classification, and paused checkpoint persistence including legacy decode. Bootstrap and live smoke environment variables remained explicitly unset. `git diff --check` passed.

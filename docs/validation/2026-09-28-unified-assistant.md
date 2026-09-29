# Unified conversational recording — 2026-09-28

Updated 2026-09-29.

## Validation status

Build **40** is installed at `/Applications/Focus Studio.app`. The delivered demo is `.artifacts/finlyze-demo/Finlyze-Product-Demo-1080p.mp4`: **29.6 seconds, H.264, 1920×1080 at 30 fps**, 7,215,545 bytes, with whole-file FFmpeg decode exit 0. The question and complete answer were visually verified as readable.

The complete fresh recording→Chinese input→Send→answer→save→cut→zoom→export workflow ran in **build 39**, from one ordinary chat request and one Start click, without operator actions during recording or editing. Build 39 exported successfully but then showed the old turn-budget error instead of a final reply. **Build 40** corrected that budget and repeatable-preview behavior, then passed a separate real in-app request on the same edited project: preview, adjust the reading zoom, repeat the exact same preview, export the final file and return a normal reply. No fresh recording was repeated for build 40. The source movie and source JSON remained byte-identical to their pre-edit baselines after both workflows.

### Build 39 — complete fresh recording and 29.6-second edit

The ordinary-language request asked for a new Finlyze AI Assistant conversation, the 25-character Unicode question “请用一句话介绍 Finlyze 的 AI 助手功能”, one Send, the complete answer with reading time, then a 25–30-second edited copy with approximately three-second focus zooms and a 1080p/30 fps export. One Start click was the only task review; recording, editing and export then proceeded without operator page actions or additional approvals. Capture stopped and saved normally, opened the editor and continued editing in the same request.

| Evidence | Result |
| --- | --- |
| Recording | `9671A534-6313-44CC-A703-BF178E9A6F2F` |
| Source project | `DC13C7DF-E964-4148-9832-52066007917B`, 59.183333 s |
| Recorded input | 71 pointer events; three clicks at 8.421872, 21.564696 and 34.503080 s; 25-character text entry completed at 27.935865 s |
| Persisted typing | Seven typing markers in the original and seven retimed markers in the edited project; the trace and mirrored typing metadata agree |
| Source zooms | Four automatic zooms, including the typed-input segment |
| Edited project | `BC58955A-9F90-4948-8159-004C70C32850`, 29.6 s; 29.583333 s omitted |
| Retained source ranges | `[7.2, 11]`, `[20, 24]`, `[26.5, 30.5]`, `[33.2, 51]` |
| Source-to-output mapping | `7.2–11 → 0–3.8`, `20–24 → 3.8–7.8`, `26.5–30.5 → 7.8–11.8`, `33.2–51 → 11.8–29.6` |
| Four focus zooms | 0.5–3.5, 4.5–7.5, 8.3–11.3 and 12.4–15.4 s; each 3 s at 1.5×, edited by its stable ID |
| Answer-reading zoom | `4E8DFDEF-0229-41CA-B09B-E56BD6F5F621`, 21.1–29.6 s, initially 1.5× at `(0.46, 0.34)`; `zoomFollowsCursor: 0` holds the answer framing |
| Build 39 export | `.artifacts/finlyze-demo/Finlyze-InApp-39-1080p.mp4`: 29.600000 s, H.264, 1920×1080, 30 fps, 7,153,940 bytes; complete decode exit 0 |
| Workflow evidence | `.artifacts/finlyze-demo/inapp-39-workflow/workflow.json`, including timing map, typing metadata, zoom IDs, source hashes and paths to the conversation and pacing analysis |

The four focus segments cover entry, the new conversation, text input and Send; the final reading segment retains the complete answer. Source and edited frames around cuts and results were inspected. The export succeeded on tool step 40, but the old conversation budget then prevented its final message and displayed an error. One identical preview request was also deduplicated; subsequent previews at different timestamps verified the cut boundaries and answer. Those are build 39 UI/workflow defects, not a failed or missing export.

### Build 40 — refreshed preview, reading adjustment and final delivery

A separate ordinary request on the installed build 40 automatically connected Codex and used the existing edited project. It requested a preview at exactly 25 seconds and 1920 pixels wide, adjusted only the final reading zoom from 1.5× to 1.45×, requested the same project/time/width preview again, and exported a new file. The assistant completed that sequence and returned a normal final reply with no error. The original and the build 39 export were retained.

| Evidence | Result |
| --- | --- |
| First rendered frame | `frame-20260929-011832.png`, 25 s, 1920×1080, 285,520 bytes |
| Same-parameter frame after edit | `frame-20260929-011856.png`, 25 s, 1920×1080, 291,771 bytes; a new render with a different SHA256 |
| Visual check | The wider 1.45× reading frame includes the question and complete answer clearly |
| Final export | `.artifacts/finlyze-demo/Finlyze-Product-Demo-1080p.mp4` |
| File verification | H.264, 1920×1080, 30 fps, 29.600000 s, 7,215,545 bytes; whole-file FFmpeg decode exit 0 |
| Final export SHA256 | `4d23ee8ba9ed6dd16d9c680c1db0d33298293387e05a0f207177cbf45b5ee2f6` |
| Workflow evidence | `.artifacts/finlyze-demo/inapp-40-workflow/workflow.json`, with the exact request, both frame receipts, final reply and export metadata |

The source `raw.mp4` retained SHA256 `5300aa6a4d4fd276868c2090c7f756d053870a118ec9ad07c9985887db413901`; source `project.json` retained `729f9cd3aedf0d4be18016d5a1ae87b9a3e8917b10cdc00ca4b49a757f9c638d`. Both match the saved baseline after build 39 and build 40 operations. Full-file decoding and selected rendered-frame review passed; complete human playback inspection of every animation is not claimed.

Build 40 raises the base conversation budget from 24 to 48 steps and allows `capture_frame` and `analyze_demo_pacing` to obtain fresh results when repeated. Mutating actions remain deduplicated. Regression evidence includes an actual repeated same-time render with changed decoded pixels after a zoom edit, reanalysis after changed chapters, duplicate `add_zoom` causing only one write, a 29-step edit/preview/export flow reaching its final reply, and refusal of a 49th request in the 48-step bounded case. Full app/core regressions passed in build 39; the complete assistant suite and native package/installation checks passed in build 40, as listed below.

### Build 38 — one ordinary request through recording, editing and export

The request asked the assistant to open Finlyze, enter the AI Assistant, type “请用一句话介绍 Finlyze 的 AI 助手功能”, click Send once, preserve the complete answer for reading, then save an original and edited copy, adjust click zooms and export 1080p/30 fps. After the one task-card Start click, the app completed all of those operations without operator intervention. The selected browser was brought forward for capture; the saved project opened in the editor and the same conversational task continued into post-production.

| Evidence | Result |
| --- | --- |
| Recording | `0C14B72A-E336-436E-9863-3709D0FB56D1` |
| Source project | `3E2BFDBB-C68E-4BE9-A5EB-D6CF4D7B860E`, 62.65 s, three clicks and three generated zooms |
| Performed action receipts | Open AI Assistant at 8.725987 s; focus field at 20.017543 s; 25-character text entry completed at 26.543145 s; Send at 33.440083 s |
| Persisted click times | 8.678042, 19.965968 and 33.389981 s; these precede the receipt completion times above |
| Saved state | Normal task stop, `state: finished`, `open_in_editor: true`; no watchdog failure |
| Edited project | `28AAEFB4-BE51-4A5A-840E-7558FD2AEB57`, 50.45 s |
| Retained source ranges | `[0, 1.8]`, `[7.4, 12]`, `[18.6, 62.65]`; 12.2 s removed across two cuts |
| Source-to-output mapping | `0–1.8 → 0–1.8`, `7.4–12 → 1.8–6.4`, `18.6–62.65 → 6.4–50.45` |
| First stable-ID zoom | `CEB78C99-9172-4C6B-855A-85AF037EFECC`: approximately 2.978–5.978 s, 1.75× |
| Second stable-ID zoom | `CF873B8E-7BDF-4D56-B32A-782F4B4A7A71`: approximately 7.666–10.666 s, 1.75× |
| Third stable-ID zoom | `9CA19C4C-7EFE-49C6-969B-691183E2E400`: approximately 21.09–24.09 s; after a rendered preview, reframed to `(0.60, 0.40)` at 1.20× |
| Preview evidence | Source frames around the cut candidates and completed answer; edited frames at 21.7, 22, 42.3 and 50.4 s, including answer readability and the ending |
| Export | `.artifacts/finlyze-demo/Finlyze-InApp-38-1080p.mp4` |
| File verification | H.264, 1920×1080, 30 fps, no audio, 50.466667 s, 8,094,330 bytes; whole-file FFmpeg decode exit 0 |
| Workflow and conversation | `.artifacts/finlyze-demo/inapp-38-workflow/workflow.json`, with `conversation.json`, `assistant-turns.jsonl` and `source-baseline.json` in the same directory |

All three existing zoom IDs were updated through the normal conversational tool path. The third segment received a further framing adjustment after the assistant inspected its preview. The actual final movie includes entry into AI Assistant, Chinese text entry, one Send and the real completed answer in a single take. Frame review and complete media decoding passed; a complete human playback review of every frame is not claimed. The file duration differs from the editable timeline by one frame-rounding fraction.

Both the source movie and source project metadata matched their pre-edit SHA256 baselines after the workflow: `raw.mp4` was `bdd49777c73c544cde0ab412250b5acbcc834c679a4207d65cf0e9554de8b1ad`, and `project.json` was `3944a03250e636632e5e386e09f78172aa252cb4a96d3ee43f958b55042e5a87`. This is specific live evidence for this take and does not replace the differently scoped build 30 result below.

The edit was conservative: it removed 12.2 seconds, leaving a 50.45-second walkthrough. The successful typing receipt and visible text establish real input, but build 38's empty `typingActivity` is not treated as persisted typing metadata. A second five-second wait was skipped as a duplicate; the task nevertheless observed the completed answer, retained reading footage, saved and exported. Those gaps led to the build 39 typing/wait corrections and the shorter successful recording/edit above.

## Implementation

The assistant now has one conversation, one connection coordinator and one recording-task owner. The former Automatic Demo and Chat & Edit tabs are removed. Website preparation leads to `run_demo_task`, a review of the exact window, goal, capabilities, duration and interaction limit. Waiting for this review never starts capture; review expires after two minutes. Raw legacy chat starts also enter this owner, with finite defaults. External MCP and the manual recorder retain their independent lifecycle.

After review the session sends a single-window readiness screenshot to Codex before starting capture. Once ready, it starts the selected window and immediately supplies a fresh live observation. Pointer and optional text actions are bound to the live recording, fresh image and selected window. Task completion, failure and cancellation stop/save only the owned recording. A watchdog can invalidate a hung model turn and save independently; an older cancelled turn cannot affect a new task. Default recording time is 120 seconds, maximum 300, with at most 12 interactions and a 45-second first-action/idle deadline.

The host supplies screenshot, pointer and text tools to a Codex app-server conversation. Connecting that service does not automatically inherit the desktop Codex application's Computer Use plugin. The actual host tool execution and recorded interaction trace are the evidence of capability.

`perform_recording_text` accepts user-requested non-sensitive single-line demo text in an observed, focused editable Chrome/Safari webpage field. It neither pastes via the clipboard nor presses Enter. A separate observed submit click must be part of the user's demo goal. Password fields and browser chrome are rejected. Text uses the same observation identity, interaction budget and idempotent receipt model as pointer actions. Both in-app and MCP callers use the same native implementation. Build 39 persists automated typing timing in both the execution trace and project typing metadata, preserving those markers through cuts.

Native post-production is available through `analyze_demo_pacing`, `create_demo_cut` and `update_zoom`. Analysis proposes source-time keep ranges from input evidence and warns that a still pointer does not imply an empty screen. Source audio or missing input evidence retains the full take by default. Cuts materialize a separate editable project, copy its assets and remap cursor, clicks, typing, zooms and chapters together. The receipt includes original/new project IDs and a source-to-output timing map. A single zoom can be adjusted by stable ID. The installed `focus-demo-editing` Skill connects those steps to rendered previews, export and a workflow report. Adjacent keep ranges are merged so an interval with no removed footage does not split zooms or reset the cursor. Cut projects also preserve the effective visibility of source zooms, including automatic zooms hidden by the source project setting. A per-project `zoomFollowsCursor` setting can hold a reading zoom on its selected content while keeping the recorded pointer visible.

For live operation, the Codex conversation retains its thread and sends only new transcript entries plus refreshed app state; replacing or truncating history rebases the thread. Interactive decisions use the model's advertised low reasoning effort. Successful tracked input is followed automatically by a fresh frame, avoiding a separate model turn solely to request that image. Per-thread configuration disables unrelated Codex tools so page actions execute through Focus Studio's tracked host tools. Build 38 reads the effective MCP server names through `config/read` and disables those inherited servers only for this assistant thread; it does not rewrite the user's global configuration or disconnect their external Codex tools. Cancellation generation checks isolate late setup/turn completions from a subsequent task. The transcript also follows new messages and changing review/progress panels while respecting a user who has scrolled up.

The starting-page check asks whether a visible safe first step is available, rather than requiring the later conversation and answer to already be visible. A usage counter showing zero does not establish a blocked quota; an explicit blocking message does. Each later action still requires its own fresh observation.

Automated input distinguishes verified cursor overlays from windows that actually cover the target. A Codex cursor overlay requires its running signed helper identity, narrow layer/shape bounds and an AX hit on the exact selected window. The system cursor exception additionally requires Apple-signed `com.apple.WindowServer` running code and the small `cursorWindow` layer. Other windows, including system dialogs and other WindowServer layers, remain blockers.

The existing manual pointer files `Capture/EventMonitor.swift` and `FocusStudioCore/CursorMotion.swift` are unchanged from HEAD. No new physical manual-recording test is claimed.

## Failure reproduced from the user's saved conversation

The earlier launcher test did not cover the conversational path. The saved chat started recording `0A4869EE-6DEB-4279-82FB-BAB22ECD2B6B` without a duration, captured observation `1B66FC46-EF77-4950-B727-CA1C3743A078`, and waited for an individual pointer confirmation. The eventual action was rejected because its image was stale. The ordinary chat loop returned to the user while capture remained live. A ready Codex connection did not imply a running computer-operation loop.

## Earlier live checks and diagnosis

### Build 27 conversational live check

The existing user conversation was preserved. A natural-language request asked to open Finlyze AI Assistant, type a non-sensitive product-introduction question, send it and save within 180 seconds. No pointer coordinates or tool names were supplied by the test operator. The task review was held for over 70 seconds; MCP reported recording idle throughout. One Start triggered successful visual readiness, recording of the exact prepared Chrome window and two model-chosen clicks. The native text guard then rejected the focused textarea; the take stopped and saved automatically at 66.852 seconds with two automatic zooms, without any repeated approval. This validates the original failure cleanup, but is **not** a successful end-to-end question/answer demo. Project `AB6653E9-AF59-444E-A86D-49D4CB5DEE17`, recording `50A6115F-2DF4-48B5-8D02-9DD14EBEBC45`.

The video editor appeared automatically after that stop. Pressing Space changed Play to Pause and advanced the timecode; pressing Space again paused at 5.546 seconds. This was checked on the real installed app in addition to the keyboard regression suite.

### Build 28 focus diagnosis

A bounded MCP diagnostic take returned `text_input_ready: false` with `text_input_reason: browser_not_frontmost`. A subsequent tracked click was rejected as covered, and the duration limit saved the take. There were two Chrome windows with the same Finlyze title and similar bounds; app activation alone did not select the captured Window Server ID. This was an activation/identity failure, not evidence that the page lacked an editable field. Diagnostic projects `A0DED3A0-7D10-4217-91B4-95C1E72442CD` and `255ECA44-FE09-4476-9F55-9C2DF8B83FBC` contain no successful text action.

Build 29 binds the prepared frontmost Window Server ID to its verified AX focused-window reference, yields activation before raising that exact window, and verifies its identity before capture and each automated pointer operation. Ambiguous window matches fail before input. The text field guards remain in place.


### Build 30 conversational recording — still failing safely

A new ordinary-chat Finlyze recording started as `452F7D51-48E8-437F-A097-1EE161C423F8`. The first requested click was refused because the selected window was considered occluded. No input was dispatched: the saved project has zero clicks and zero interaction-trace events. The session stopped and saved automatically after 29.53 seconds as project `577BB4B8-0B06-4B56-B5F6-980A241F98AD`.

This confirms finite failure cleanup rather than an indefinitely running blank take. It does **not** confirm working window activation, browser input, virtual-cursor following, or a completed product demonstration. This build 30 result alone does not establish whether the subsequent recording changes work; later external and in-app checks are separated below.

### Build 30 ordinary-chat editing — verified on existing footage

The installed assistant received a natural-language request to shorten an existing Finlyze navigation demo, preserve useful reading time, make its click zooms approximately three seconds, and export 1080p. It analyzed pacing, captured frames around proposed cuts, retained more result time than the first automatic proposal, created a separate project, previewed the shortened timeline and exported it.

| Evidence | Result |
| --- | --- |
| Preserved source project | `C7838E9A-A1D8-41C7-91ED-095C979D4D26`, 40.946667 s |
| New edited project | `8FA0F89B-6612-4907-92DA-5CB8406541E3`, 24.146667 s |
| Selected source ranges | `[0, 4]`, `[16.6, 25]`, `[29.2, 40.946667]` |
| Removed duration | 16.8 s, across two cuts |
| Resulting camera segments | 5.6–8.6 s and 14–17 s, each 3 s at 1.75× |
| Export | `.artifacts/finlyze-demo/Finlyze-Navigation-Edited-1080p.mp4` |
| Media verification | H.264, 1920×1080, 30 fps, 24.166667 s; whole-file FFmpeg decode completed with exit 0 |
| Workflow receipt | `.artifacts/finlyze-demo/demo-workflow/workflow.json` |

The movie duration differs from the editable timeline by about 0.02 seconds due to frame rounding. The workflow receipt retains the analysis, selected ranges, timing map, resulting zoom IDs, source/edited preview receipts and actual verification results. Source previews were captured at 4, 16.6, 22.3, 29.2 and 25 seconds; edited previews at 7, 15.5 and 12.5 seconds. Full-file decoding confirms readable media; it is not a claim that every animation was manually watched at playback speed.

The original raw movie's SHA256 was unchanged and the original project remains available. Its `project.json` was not byte-identical after the app opened/normalized the project, so this live test does not claim unchanged source metadata bytes. The isolated store regression below verifies that the cut operation itself preserves them.

A remaining build 30 limitation was exposed: the model-facing `get_project` transcript omitted structured zoom IDs. The assistant therefore removed/re-added the two zooms rather than using `update_zoom`. The output demonstrates successful pacing and camera adjustment, but does not verify stable-ID editing in the natural-language path. Structured-result forwarding was corrected in the subsequent build and is covered by regression tests. The later external MCP test below exercises an actual stable-ID update; an in-app natural-language stable-ID edit is not inferred from that external call.

This edited artifact comes from the earlier navigation take. It does **not** prove that a fresh Finlyze AI Assistant question/answer recording succeeded, or that the complete new recording→editing chain has passed in one run.

### Build 31 external MCP recording — real text entry and Send/answer across two takes

The MCP recording `B42FEF65-D3AF-4E39-B114-D9EDB996A3F8` successfully opened the AI Assistant, focused its input and entered a 25-character Chinese product question through `perform_recording_text`. Its bounded 120-second take ended before the next test operation. The question remained filled in the webpage.

A subsequent take saved as project `35D28DC7-B788-4F48-B6CF-14B4C1AF068C` recorded the tracked Send click and Finlyze's real completed answer. Its duration is 123.981667 seconds; its execution trace contains one click at source time 26.669115 seconds. It has no typing-activity entries because the question was entered in the preceding take. These results establish that the external native MCP pointer/text tools can operate the target, while keeping the timing scope of each recording explicit.

### Build 31/32 question-and-answer edit and export

The subsequent Send/answer project was trimmed to the retained source interval `[22, 46]`, producing the new editable project `F03A4AC9-4A86-4E23-8E3C-2535D7E35844`. The original remains available. The 24-second edit starts with the already-entered question, shows Send and retains the completed answer. It is not presented as a continuous recording of opening the page and typing the question.

| Evidence | Result |
| --- | --- |
| Source → edited duration | 123.981667 → 24 s; 99.981667 s omitted |
| Source-to-output mapping | Source 22–46 s → output 0–24 s |
| Existing click zoom | ID `4B9DDA79-DB33-4A75-B9A1-161F5BEE2670` retained by `update_zoom`; 3.5–6.5 s, 1.35×, ease-in 0.45 s / ease-out 0.6 s |
| Answer-reading zoom | 11–22 s, 1.4×, aimed at the answer |
| Build 32 camera setting | `zoomFollowsCursor: 0` on this edited project; rendered preview verified the answer framing rather than following the old Send-button position |
| Rendered checks | Edited time 4.67 s for the click and 15 s for answer readability |
| Export | `.artifacts/finlyze-demo/Finlyze-AI-Assistant-Edited-1080p.mp4` |
| File verification | 24.000 s, H.264, 1920×1080, 30 fps, no audio, 4,249,314 bytes; full FFmpeg decode exit 0 |
| Workflow receipt | `.artifacts/finlyze-demo/ai-question-workflow/workflow.json` |

The MCP transcript in `.artifacts/finlyze-demo/mcp-transcript.jsonl` contains the text/action, cut, same-ID zoom update, camera-setting, rendered-frame and export receipts. The native tool's successful same-ID update is distinguished from build 30's remove/re-add fallback. Frame review and whole-file decoding were performed; neither is described as a complete manual playback review of every animation.

### Build 31/32 in-app watchdog and partial progress

The separate ordinary-chat build 31 recording reached the 45-second first-action watchdog without dispatching an action. It was safely saved as `FF8545A3-E41D-4556-ABB6-499428215357`, duration 45.156667 seconds, with zero interaction-trace events. Thus external MCP success did not establish that the app's own autonomous model loop was ready in time.

Build 32 moved recording-model preparation before capture so startup work does not consume the recorded first-action deadline. Its live ordinary-chat check then completed a real first click at approximately 9.45 seconds (stored click timestamp 9.396333 seconds) and obtained a later frame at approximately 18 seconds. The next decision stalled. The 45-second idle watchdog stopped and saved the 54.51-second take as project `48A4B22D-3E11-433A-9978-F69B8597D9E6`. This was progress from zero input, but that requested demonstration did not complete.

### Build 33/34 conversation transport and readiness

Build 33 reduces repeated model startup/context work with incremental conversation turns, live low-effort decisions and an automatic fresh frame after input. It also isolates cancelled or superseded setup/turn completions and constrains the model to the host's tracked operations. The hosted transcript regression exercises a real native scroll view with long history, expanded tool receipts, window resizing and changing review/live panels; it is a UI regression, not a claim that live webpage scrolling was tested.

The installed build 33 failed its initial chat before capture because its app-server rejected an optional parameter: `thread/start.environments requires experimentalApi`. Build 34 removes that nonessential parameter while retaining the stable per-thread configuration. The build 34 live request connected Codex automatically when the prompt was sent, without requiring a separate Connect click. After Start, visual readiness succeeded in 8.09 seconds. The first action completed at 8.71 seconds, with observed model requests taking approximately 5–8 seconds. The next pointer action was interrupted by a real system alert. Diagnostics identified the covering process as CoreServicesUIAgent (PID 75940), and UI inspection confirmed the dialog “应用程序‘Focus Studio’已不能再打开。” Two duplicate alerts were dismissed. The guard prevented the covered click and the 22.83-second take was saved as project `082CEB99-8B57-406F-95A4-19D0DA836412`. This attempt failed because of a visible system window, not a model-idle timeout. The alert's suspected relationship to repeated installation/relaunch is not established as its cause. That build 34 attempt did not complete; the later successful build 38 run is documented separately above.

### Build 35/36 cursor overlay correction

Build 35 successfully entered the 25-character Chinese text, but its approach to Send was stopped when the native WindowServer cursor plane was treated as an occluding window. Build 36 added the narrow system-cursor exception described above, alongside verification of the Codex helper's cursor overlay. The exception checks running code identity, the cursor layer and small bounds, and the exact AX recording target together; it does not trust a process name or cursor-shaped window alone. Unknown overlays, real dialogs and non-cursor WindowServer surfaces still block input. App and runner regressions exercise those distinctions, including the reproduced 28×40 native cursor plane. The original manual pointer algorithms remain unchanged.

### Build 37 readiness and inherited MCP startup diagnosis

Build 37 corrected readiness interpretation so the visible AI Assistant navigation entry was sufficient to start, without treating an ambiguous zero counter as exhausted quota. The live readiness check passed, but recording `13572303-F8F2-4941-A0DA-98B81D91AFD4` made no actions and hit the 45-second idle watchdog. It saved a 45.190-second source project `6209EC1B-1F9B-4A2B-A7AE-650818F2F181` and returned to the editor. A second attempt timed out during the 45-second preflight and did not start another recording.

Transport diagnostics then showed inherited manually configured MCP services starting in the assistant's own thread. In the observed cold turn, the user message arrived only after approximately 20 seconds and an ordinary chat response took approximately 60 seconds; the next turn on that thread took 10.9 seconds. These timings identify inherited startup work as a concrete latency contributor, rather than establishing a universal model response time.

Build 38 reads the effective server names and disables them through a nested configuration override only in the Focus Studio assistant thread. A real probe in `.artifacts/assistant-mcp38/probe.log` found four effective server entries, verified all four as disabled for that thread with zero tools, and saw no MCP startup notices. Global settings and external Codex connections were preserved. Focus Studio still executes its own native screenshot, action, editing and export tools. The complete build 38 run above is the live behavior check after this change.

## Automated verification

### Build 32 automated and package checks

| Check | Evidence |
| --- | --- |
| Debug build | `.artifacts/integrated-build32.log` |
| Native release build and package verification | `.artifacts/integrated-package32.log`; arm64, macOS 15+, 30 MCP tools, 1,089 matching localized keys |
| App/store/integration regression | `.artifacts/integrated-app32.log` |
| Recording runner | `.artifacts/integrated-runner32.log` |
| Core permission/startup/geometry | `.artifacts/integrated-core32.log` |
| MCP protocol/catalog | `.artifacts/integrated-mcp32.log` |
| Assistant and preparation/watchdog behavior | `.artifacts/assistant-warmup-tests32.log` |
| Codex connection/preparation | `.artifacts/codex-preparation-tests32.log` |
| Canonical installation | `.artifacts/integrated-install32.log`; installed Info.plist confirms 1.12.0 / 32 |

All listed checks pass. The installation log's `Installed: 1.12.0 (31)` line describes the previous destination during preflight; the source was 32 and the installation completed with verification. These local checks do not claim an updated universal package, notarization, Intel hardware testing or a new physical manual-recording test.

### Build 33/34 automated and package checks

| Check | Evidence |
| --- | --- |
| Build 33 debug and native release package | `.artifacts/integrated-build33.log`, `.artifacts/integrated-package33.log` |
| Build 33 app/store/native transcript regression | `.artifacts/integrated-app33.log` |
| Build 33 core permission/startup/geometry | `.artifacts/integrated-core33.log` |
| Build 33 MCP protocol/catalog | `.artifacts/integrated-mcp33.log` |
| Build 33 assistant, workflow and timeline editing | `.artifacts/integrated-assistant33.log` |
| Build 33 Codex context and cancellation isolation | `.artifacts/integrated-codex33.log` |
| Build 34 debug and native release package | `.artifacts/integrated-build34.log`, `.artifacts/integrated-package34.log` |
| Build 34 Codex connection/transport | `.artifacts/integrated-codex34.log` |
| Build 34 canonical installation | `.artifacts/integrated-install34.log`; installed Info.plist confirms 1.12.0 / 34 |

All listed checks pass. The native build 34 package verifies arm64, macOS 15+, 30 MCP tools, 1,090 matching localized keys, 12 audio assets and 12 backgrounds. These are historical build 33/34 results. Later checks are listed separately below. Automated checks alone do not establish live recording and do not claim universal distribution, notarization, Intel hardware testing or physical manual-recording retesting.

Timeline regression cases verify that adjacent source intervals collapse to one range, keep one continuous cursor/zoom segment and yield consistent tool timing-map/cut-count receipts. A real small gap remains a cut. Zoom visibility cases cover globally hidden automatic zooms, visible manual zooms and individually disabled segments. Provider tests cover incremental same-thread turns, refreshed state, edited-history rebasing, low live effort, cancelled preparation and late-completion isolation. Assistant tests cover bounded lifecycle behavior and post-input observations.

### Build 36–38 automated and package checks

| Check | Evidence |
| --- | --- |
| Build 36 debug, native package and installation | `.artifacts/integrated-build36.log`, `.artifacts/integrated-package36.log`, `.artifacts/integrated-install36.log` |
| Build 36 full app/store/overlay regressions | `.artifacts/integrated-app36.log` |
| Build 36 recording runner and cursor-plane cases | `.artifacts/integrated-runner36.log` |
| Build 37 debug, native package and installation | `.artifacts/integrated-build37.log`, `.artifacts/integrated-package37.log`, `.artifacts/integrated-install37.log` |
| Build 37 assistant/readiness regressions | `.artifacts/integrated-assistant37.log` |
| Build 38 debug, native package and installation | `.artifacts/integrated-build38.log`, `.artifacts/integrated-package38.log`, `.artifacts/integrated-install38.log` |
| Build 38 Codex configuration/connection regressions | `.artifacts/integrated-codex38.log` |
| Build 38 actual thread MCP isolation probe | `.artifacts/assistant-mcp38/probe.log` |

All listed checks pass. The build 38 package verifies arm64, macOS 15+, 30 MCP tools, 1,090 matching localized keys, 12 audio assets and 12 backgrounds. The dependency lockfile was restored to HEAD before the successful build 37 release and has no pin changes. This is a local development installation; the Universal 2 distribution candidates remain build 19 and no new notarization or Intel hardware test is claimed.

### Build 39/40 final automated and package checks

| Check | Evidence |
| --- | --- |
| Build 39 debug, native package and installation | `.artifacts/integrated-build39.log`, `.artifacts/integrated-package39.log`, `.artifacts/integrated-install39.log` |
| Build 39 full app and core regressions | `.artifacts/integrated-app39.log`, `.artifacts/integrated-core39.log` |
| Build 39 assistant and persisted typing/wait behavior | `.artifacts/integrated-assistant39.log` |
| Build 40 debug, native package and canonical installation | `.artifacts/integrated-build40.log`, `.artifacts/integrated-package40.log`, `.artifacts/integrated-install40.log`; installed CFBundleVersion 40 verified |
| Build 40 complete assistant suite | `.artifacts/integrated-assistant40.log`; repeated real rendering/reanalysis, mutation deduplication, extended edit/export/final reply and bounded step limit |

All listed checks pass. The final package is a local arm64 development installation; no new Universal 2 release, notarization, Intel hardware test or physical manual-recording test is implied. The original `EventMonitor.swift` and `CursorMotion.swift` remain unchanged. Build 39 supplies the complete fresh recording evidence; build 40 supplies the final preview/edit/export/reply evidence on that same project.

### Real store and model regression

The serialized app suite in `.artifacts/integrated-final-app30.log` passed, including `DemoEditingRegression`, and the same regression also passes in `.artifacts/integrated-app32.log`, `.artifacts/integrated-app33.log` and `.artifacts/integrated-app36.log`, with the final app suite passing again in `.artifacts/integrated-app39.log`. Its temporary-library fixture creates a real six-second H.264 movie, retains `[0, 1]` and `[3, 5]`, and decodes the resulting three-second movie. Assertions verify:

- a new project ID, saved edit provenance and exact source movie/JSON SHA256 preservation by the store operation;
- retained click identities, removed events, remapped typing/zoom/chapter times and an explicit cursor discontinuity at the cut;
- copied background, music and custom sound dependencies, including loading the derived project and reading its media after relocating the fixture's source directory;
- no partially published project after invalid ranges, a pre-cancelled operation, or a missing asset encountered after video materialization;
- StudioModel refusal while busy, opening the successful derived project, and updating the already-created assistant context to its new timeline.

These tests use temporary media and no real desktop input. They supplement the external MCP tests and the build 38/39 recording workflows plus build 40 final edit/export; they are not physical manual-input tests.

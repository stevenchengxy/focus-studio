---
name: focus-demo-editing
description: Record and finish a product demo with Codex and Focus Studio, or edit an existing take. Use for clipping, splitting, trimming and reordering footage; importing video and images into the native media library; removing slow AI waits; adjusting zooms, sound and transitions; then previewing and exporting while preserving the original project.
---

# Focus Studio demo workflow

Turn the user's recording goal into a finished, editable demo through Focus Studio's MCP tools. The result is
an original take, a separate edited project, a small workflow report, and the requested MP4. No Ark account or
paid image/video generation is needed.

For recording, read [the recording guide](../focus-studio-mcp/SKILL.md). For native timeline, audio and zoom parameters and
receipts, read [editing-tools.md](references/editing-tools.md). Use the currently connected tools' schemas;
if native pacing tools are missing, explain that this app build needs updating rather than pretending to cut it.

## One continuous task

A request such as “录制这个产品，剪掉 Codex 操作间的等待，把重点多展示几秒，导出 1080p” authorizes the
recording and its local post-production. Continue through these phases without asking for approval between
reversible edits. Honor the app's actual recording/connection prompts and the user's chosen scope.

1. **Capture or select the source.** If a project was supplied, use it without re-recording. Otherwise record
   the requested actions with a finite duration, fresh observations and the tracked pointer/text tools. Save
   the returned project ID. A failure to perform a requested action remains a failed demonstration even if
   it can be edited into an attractive clip; do not conceal it with cuts or zooms.
2. **Inspect and plan.** Read `get_project` and analyze pacing from the complete interaction metadata through
   the native tool. Save its result to a workspace `demo-workflow/` folder. Long gaps are candidate cuts,
   not proof that nothing useful is happening: a report, animation, generated answer, or voiceover may be
   visible or audible while the mouse is still. Inspect those moments before accepting the suggested ranges.
3. **Create the edit.** For a few reviewed large removals, `create_demo_cut` creates a new project from selected
   source-time keep ranges. For hands-on editing, read `get_timeline`, then use `split_clip`, `trim_clip`,
   `delete_clip` and `move_clip` with stable clip IDs. The first video-track edit creates a working copy; use
   the **returned project ID** and fresh clip list for every later operation. Source material stays in the
   library. Record both IDs, durations, selected ranges or clip operations, and any timing map in `workflow.json`.
   All later timestamps refer to the edited output timeline. `undo_clip_edit` and `redo_clip_edit` step through
   recent editor changes while the project remains open; their history is in memory. After Undo, a new edit
   clears Redo.
4. **Direct the camera.** Read the new project's actual zoom IDs. Adjust an individual segment's start/end,
   target, or scale with the dedicated zoom update tool. Keep the click visible, allow the result to settle,
   and leave enough reading time for the content shown. Use a wider shot when a long response extends outside
   the zoomed area. Global zoom style controls apply to the whole project and can regenerate automatic zooms;
   make global changes before individual adjustments, then inspect the resulting zoom IDs again.
5. **Finish sound and joins.** Use `set_transition` on an outgoing clip to choose a cut, fade to black or flash
   and set its duration. Use `set_clip_audio` to mute or adjust that clip's source sound; background music and
   click/zoom sounds are separate project controls. Let visual effects serve the demonstration rather than
   putting one at every cut. Preview both sides of edited joins and listen where sound matters.
   For a reusable product still or B-roll shot, call `import_global_media_asset`, then
   `add_global_media_to_project`; use the returned project-local asset ID with `insert_media_asset` at the
   requested clip index. A still defaults to 3 seconds; adjust it with `set_image_duration`. The project gets
   an independent copy and the original recording is preserved. Use `import_media_asset` for a file needed
   only in the current project. The in-app assistant's confirmed Seedance/Seedream generation saves successful
   media to the shared library; explicitly add the generated item to the project. Generation is a separate
   paid action and must follow the app's cost confirmation.
6. **Preview and revise.** Inspect rendered `capture_frame` images at the beginning, important results, and
   either side of each cut. Export a small draft when motion, sound, or readability needs checking; still
   frames do not verify animation. Check cursor continuity, click alignment, readable answers, complete
   captions, and that zooms do not jump abruptly or finish before the result appears. Adjust the cut or zoom
   if needed and verify again. Do not infer an answer's completion from typing/click metadata alone.
7. **Export and deliver.** Export the edited project at the user's requested size (1920-wide/30 fps if none
   is specified). Resolve long-running jobs with `wait_for_job`. Verify the returned file exists and, when
   local media tools are available, probe/decode it. Record checks actually performed in `workflow.json`.
   Deliver the MP4, the original/edited project IDs, and a concise account of time removed and zoom changes.

## Editing decisions

- For a silent Codex demo, preserve a brief establishing view, the approach/click, and a readable result.
  Prefer removing the middle of a long stable wait. A sequence of very short clips can feel faster yet be
  harder to understand; do not hit an arbitrary target duration by removing necessary context.
- When the footage contains narration, music already mixed into the source, or spoken answers, inspect
  audio before shortening gaps. Input metadata is not voice activity detection. Native cuts keep the
  retained source audio with its video; they cannot repair a sentence cut in half.
- A zoom that is too short needs a local duration adjustment, not a larger global hold for every click.
  After cutting, use the new timeline rather than subtracting offsets mentally. Read the timing map or compute
  it from the retained ranges as described in the tool reference.
- Preserve the useful typing sequence and the complete result. To show a long generation concisely, retain
  its beginning and finished answer after visual verification; do not remove the response itself as “idle.”
- Source recordings and custom assets remain in Focus Studio's library. Never patch `project.json` directly.
  Keep reports and exported files in the chosen workspace/output folder.
- A clip split uses **output playhead time**; trims use **source movie in/out seconds**. Read `get_timeline`
  after each structural change. Do not assume a clip's old position or a removed clip's ID still applies.

## Optional finishing

Use `set_chapters` for concise, truthful titles/captions inside Focus Studio. Use the user's existing visual
style unless they asked for redesign. Native background music and click/zoom sounds are optional, not required
for a pacing edit.

Native Focus Studio supports extra video/image clips, including simple still title cards or B-roll. For
multi-layer compositing, complex typography, crossfades or a separate marketing assembly, continue with
[product-demo-composer](../product-demo-composer/SKILL.md) after the native camera edit. Its export has cursor
and zooms baked in; retain the native project for future edits.

## Minimal workflow report

`workflow.json` is a local record written by the agent, not a tool input schema. Include:

- user goal and chosen pacing policy;
- source project ID/duration and confirmation that it was retained;
- analysis response, chosen source keep ranges or clip operations, edited project ID/duration, and timing map;
- transition presets/durations and per-clip sound changes when used;
- zoom IDs and changes on the edited timeline;
- preview/export paths, inspected times, and verified or unverified checks.

Keep browser contents and typed text out of the report unless needed for the user's demo. Do not claim
“automatically verified” from a successful tool receipt alone; distinguish rendered-frame review, playback,
and a successful export.

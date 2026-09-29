# Native pacing, clip, sound and zoom tools

These tools are exposed by Focus Studio both to its assistant and over the `focus-studio` MCP connection.
Always pass `project_id` from an actual saved project. In-app calls may infer the current project; explicit IDs
avoid changing the wrong take when several windows or projects are open. Read each connected tool's current
schema before invoking it.

## Analyze waiting intervals

Call `analyze_demo_pacing` with `project_id`. Optional `pre_roll`, `post_roll` and `minimum_gap` adjust the
context retained around recorded actions and how long a gap must be to become a candidate removal.
Current defaults are 0.8 s before each input, 1.8 s after it/at the ends, and a 3 s minimum removable gap.
Supported ranges are 0.1–10 s for `pre_roll`, 0.1–15 s for `post_roll`, and 0.5–60 s for `minimum_gap`.
Treat these as an initial proposal, not a guarantee of enough reading time; record the values actually used
in the workflow report. Increase retained result ranges after inspecting the content when needed.

The tool reads the project's complete input metadata. `get_project` summarizes the interaction trace and
samples large click/typing lists, so those displayed lists must not be treated as the complete analysis input.
The analysis result includes `keep_ranges`, `removed_ranges`, `original_duration`, `edited_duration`,
`removed_seconds`, `input_evidence_count`, `source_audio_present`, and `warnings`. It does not edit or export.
When source audio exists or usable interaction evidence is missing, the default proposal retains the whole
recording. Enabled chapters are protected. Explicit reviewed ranges can still be supplied to the cut tool.

A gap in input is not a measurement of visual or audio inactivity. Before cutting a candidate interval, inspect
source `capture_frame` images near its beginning and end, and inside it when the product is generating output
or animating. When the source contains speech, preserve it unless listening confirms the cut is appropriate.
If there is no reliable action metadata, choose ranges from observed footage; do not invent click timing.

## Make an edited project

Call `create_demo_cut` with the source `project_id` and an ordered array of source-time `keep_ranges`:

```json
{
  "project_id": "<source project UUID>",
  "title": "Product demo — edited",
  "keep_ranges": [
    {"start": 0, "end": 4.5},
    {"start": 18, "end": 25.5},
    {"start": 43, "end": 52}
  ]
}
```

Those example ranges are illustrative; use ranges justified by the actual recording. Keep them ordered,
non-overlapping, and inside its duration: 1–128 ranges, each at least 0.1 s. The tool performs hard cuts, with no time stretching or crossfades. It creates a separate project with retained
media and remapped interaction/camera/chapter timing. It preserves the original project. Capture the returned `source_project_id`, new `project_id`, `original_duration`, `edited_duration`,
`removed_seconds`, `keep_ranges`, `cut_count`, `zoom_count` and `click_count`. Wait for any returned long-running
job before editing or exporting the new project.

Use `timing_map` when the receipt provides it. Otherwise derive and save the map deterministically from the
ordered `keep_ranges`: the first output interval starts at 0; each later output interval starts at the sum of
all preceding retained durations; an included source time `t` maps to `output_start + t - source_start`.
For the example above, output starts are 0, 4.5, and 12 s, with final duration 21 s. Times in removed gaps have
no output time. Use a script/calculation for the report; for actual edits prefer the new `get_project` times.

For a zoom-only revision that must preserve the original, retaining the full `[0, duration]` range creates the
working copy. After a cut, call `get_project` on the new ID and use its new duration and zoom IDs. Do not send
original timestamps to the edited project.

If a removal looks wrong, create another cut from the original with revised ranges. Avoid a second generation
of cutting a compressed export. The original is the recovery point; no manual library file copying is needed.

## Edit the video track by clip ID

For manual-style edits or a sequence of small revisions, read `get_timeline` first. It returns the current
`project_id`, total output `duration`, immutable `source_duration`, and every clip with:

- stable `id` and zero-based `index`;
- `timeline_start` / `timeline_end` (where it plays in the edited video);
- `source_start` / `source_end` (the included range of the original source movie);
- `source_audio_volume` and `transition_after`.

The first clip operation on an original recording creates a separate working project; read the **returned
`project_id`** and use it for every later edit, preview and export. Later clip operations update that copy.
The original movie and project remain in the library. Re-read `get_timeline` after structural changes,
because output times and split-created IDs can change. Invalid operations are refused without partial edits.

| Tool | Meaning |
| --- | --- |
| `split_clip` | `clip_id` plus `at`, an absolute **output timeline** second strictly inside that clip. The first half keeps its ID; the second gets a new ID. |
| `trim_clip` | `clip_id`, `source_start`, `source_end` in **source movie** seconds. It shortens the current included span and retains the clip ID; use undo to restore trimmed footage. |
| `delete_clip` | Remove one clip by ID from the working edit; at least one clip must remain. It does not delete the source movie. |
| `move_clip` | Move one clip ID to `to_index`, a zero-based destination in the track; sound and interaction timing follow its footage. |
| `undo_clip_edit` | Reverse the latest video-track operation on the open working project. Repeated calls walk a finite in-memory history; reopening the app may clear it. |

Set a join with `set_transition` using the **outgoing** `clip_id`, `preset` and `duration`. Available presets
are `cut` (duration 0), `fadeToBlack`, and `flash` (0.1–2 seconds). An effect is centered on the boundary
and does **not** add to or overlap clip duration; both neighboring clips must have enough handle for its
length. The final clip has no outgoing join. These effects appear in preview and export. For a quiet
instructional demo, use a plain cut unless a visible change of section benefits from an effect.

`set_clip_audio` changes one clip's source sound using `clip_id` and `volume`: 0 mutes, 1 keeps original
level, 2 doubles gain. It does not change the volume of project background music, click sounds or zoom
effects. Use `set_background_music` and `set_sound_effects` for those tracks, and listen to a rendered draft
when audio cuts or level changes matter.

If a clip operation fails after another edit, read `get_timeline` again before retrying. A retry with an
obsolete project ID, clip ID or output time can target a different position. Do not patch `project.json`.

## Adjust one zoom

`update_zoom` takes `project_id`, `zoom_id`, and only the fields to change:

- `start`, `end`: seconds in the edited project's timeline;
- `x`, `y`: target in the full recorded frame, normalized 0–1 from top-left;
- `scale`: magnification, 1.1–3;
- `ease_in`, `ease_out`: transition durations in seconds, 0–5;
- `enabled`: whether this segment participates in rendering.

For example, after looking up the segment's real ID:

```json
{
  "project_id": "<edited project UUID>",
  "zoom_id": "<zoom UUID from get_project>",
  "end": 9.2
}
```

This changes that segment while keeping its ID. The result becomes a manual camera edit, so later automatic
zoom regeneration should not be used to overwrite it. The interval must stay inside the project and be at least 0.2 s; out-of-range values are rejected.
Extending `end` does not add video duration; to show a result longer, retain enough source footage in the cut.

For all-project motion, `set_zoom_style` uses camelCase keys such as `zoomEaseIn`, `zoomEaseOut`, `zoomHold` and
`zoomChainGap`. It can regenerate automatic segments. Apply it before local `update_zoom` changes if needed.
Don't use `remove_zoom` plus `add_zoom` merely to change a duration: it loses identity and risks camera overlap.

If the camera drifts toward the last mouse position while a long answer should remain readable, read
`get_project.look.zoomFollowsCursor` and save that value in the workflow report. On the edited copy, use
`update_settings` with `zoomFollowsCursor: 0` to hold each zoom's authored target. The range is 0–1 and applies
to all shots, so preview the other zooms too. Use this only when fixed framing is needed; otherwise leave the
setting unchanged. If the user requests cursor following again, restore the previously recorded value.
This changes camera framing only; the recorded cursor and click metadata stay available.

## Preview, export, report

Use `capture_frame` with the edited `project_id` and a `time` near each cut and zoom/result. Its rendered image
includes the camera, cursor, background and captions. Review the images; an empty tool error is not a preview.
For a motion draft, use `export_project` with `width: 1280`, `frame_rate: 30` and a distinct preview path.
Export the final version with the requested width/fps. Read the actual returned path and resolve `wait_for_job`
until complete. Avoid overwriting an existing output unless it belongs to this task or the user requested it.

Useful final checks include:

- edited duration equals the selected ranges, within frame rounding;
- rendered cuts preserve the next action and its result, with no cursor sweep across removed time;
- zoom entry/hold/exit remains legible at actual playback speed;
- narration and generated answers have not been cut mid-result;
- the final MP4 probes/decodes and has the requested dimensions and audio policy.

Store raw analysis/creation receipts and actual checks in `workflow.json` outside the library. A report should
name the preserved source and the editable result, not just the final flattened export.

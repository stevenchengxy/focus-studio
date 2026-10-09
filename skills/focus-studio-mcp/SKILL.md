---
name: focus-studio-mcp
description: Operate Focus Studio through its MCP tools to record a product demo, edit its video clips, zooms, transitions, captions and sound, then export an MP4. Use for Focus Studio recording, clip trimming or reordering, demo editing, BGM, subtitles and export requests. Paid AI generation is separate.
---

# focus-studio-mcp - record, edit and export with Focus Studio over MCP

Focus Studio 1.12 ships an MCP server, `Focus Studio.app/Contents/MacOS/focus-studio-mcp`. Every tool runs
inside the Focus Studio app while the person watches: editing opens the project in the editor, and every
recording shows a countdown and a control bar. Focus Studio is the only writer of its library.

## Prerequisites

* The tools are visible as `mcp__focus-studio__<tool>` in Claude Code (in Codex: the tools of the
  `focus-studio` server). If they are missing, ask the person to connect Focus Studio: Focus Studio ›
  Settings › AI tools › Connect, or in Terminal
  `claude mcp add --scope user focus-studio -- "/Applications/Focus Studio.app/Contents/MacOS/focus-studio-mcp"`
  (for Codex: `codex mcp add focus-studio -- "/Applications/Focus Studio.app/Contents/MacOS/focus-studio-mcp"`),
  then start a new session. **Copy command** under Settings › AI tools › Connect AI tools gives the command
  with this copy's helper path and the full path of the CLI Focus Studio found (such as the `codex` inside
  ChatGPT.app, which is not on PATH); use it when Focus Studio is not in /Applications.
* Listing tools does not start the app; the first call opens Focus Studio in the background. The first call
  from a new AI tool shows an approval prompt in Focus Studio: tell the person to click **Allow**. If nobody
  answers it within 2 minutes, the result is an error saying nobody answered (or, rarely, an error with
  `status: "waiting_for_approval"`): ask the person to click **Allow**, then call the same tool again (it
  waits on the same prompt and runs once allowed). If a result says the person declined, revoked access or
  turned AI tools off, stop and ask; do not retry on your own.
* Recording needs the Screen Recording permission of Focus Studio itself; `get_status` reports it
  (`permissions.screen_recording`). Automatic zooms on clicks and typing also need Accessibility and Input
  Monitoring.

## Tools

| Group | Tools |
| --- | --- |
| Status and library | `get_status`, `list_projects`, `get_project`, `rename_project`, `delete_project` |
| New projects from files | `import_video`, `create_screenshot_demo` |
| Recording | `list_recording_sources`, `start_recording`, `capture_recording_frame`, `perform_recording_action`, `perform_recording_text`, `stop_recording`, `wait_for_recording` |
| Editing (by `project_id`) | `analyze_demo_pacing`, `create_demo_cut`, `get_timeline`, `resolve_timeline_frame`, `split_clip`, `trim_clip`, `delete_clip`, `move_clip`, `set_transition`, `set_clip_audio`, `set_image_duration`, `undo_clip_edit`, `redo_clip_edit`, `update_zoom`, `add_zoom`, `remove_zoom`, `set_zoom_style`, `update_settings`, `set_chapters`, `set_background_image`, `set_background_music`, `set_sound_effects` |
| Shared media library | `list_global_media_assets`, `import_global_media_asset`, `add_global_media_to_project` |
| Current project's media | `list_media_assets`, `import_media_asset`, `insert_media_asset` |
| Output | `capture_frame`, `export_project`, `assemble_video`, `list_assets` |
| Long calls | `wait_for_job` |

Not available over MCP: `generate_image`, `generate_video` (paid), arbitrary key presses, shell commands. Tracked pointer input is available only inside the selected live recording window.

## Typical flows

### Record and finish a demo in one task

For “record this website, remove the slow waits, adjust zoom durations and export”, use
[focus-demo-editing](../focus-demo-editing/SKILL.md). It connects the recording flow below to the native
`analyze_demo_pacing` → reviewed `create_demo_cut` or `get_timeline` → clip edits → `update_zoom` → preview/export workflow. The source take is retained,
and a first video-track edit opens a separate working project. Use its returned `project_id` for later changes.
A long pause in input is only
a candidate cut; inspect generated answers, loading animations and audio before removing it.

Use `update_zoom` with an existing `zoom_id` for individual start/end/target/scale changes. Use
`set_zoom_style` for global motion, before those local edits; automatic regeneration can change segments.
If these newer tools are absent from the connected catalog, update Focus Studio before claiming to use them.

For precise clip work, call `get_timeline` first. Use `resolve_timeline_frame` with
either approximate `at_seconds` or a zero-based `frame_index` to obtain the
exact output-frame `time_seconds`, containing `clip_id` and `source_time_seconds`.
This lookup is read-only: it does not move the editor's confirmed white playhead.
Use `capture_frame` at that returned time with `exact_frame: true` to inspect
the image. This slower path reports `frame_matches_request`; if true, pass the
exact time and clip ID to `split_clip` when `can_split_here` is also true.
`split_clip.at` is an absolute **output** time;
`trim_clip.source_start` and `source_end` are positions in the immutable **source** movie. Use IDs from the
latest receipt, since a split creates another clip ID. `move_clip.to_index` starts at zero. `set_transition`
supports `cut`, `fadeToBlack` and `flash` on a clip with a following clip; `set_clip_audio.volume` controls
only that clip's source sound (0–2; 0 mutes). Preview and export render these edits. `undo_clip_edit` and
`redo_clip_edit` traverse recent editor changes while the app keeps this history in memory.

For reusable video or images, use `import_global_media_asset`, then `list_global_media_assets`.
Choose an item explicitly with `add_global_media_to_project`; this copies it into the current project's
library and returns the **project-local asset ID**. Use that ID with `insert_media_asset` and a zero-based
clip index. The first edit branches the original recording into a working project; use its returned
`project_id` for subsequent calls. A still defaults to 3 seconds and can be adjusted with
`set_image_duration`; video clips retain their sound and can be trimmed. Shared and project copies are
independent, so changing or deleting the shared source does not break an existing project. Use
`import_media_asset` when a file should go directly into this project instead of the shared library.
Confirmed Seedance/Seedream generation through the in-app assistant stores successful output in the
shared library; adding it to a project remains an explicit step.

### Codex-controlled recording with synchronized pointer and zooms

Choose a visible window and start with `interaction_mode: "codex"` and `automatic_zooms: true`.
The result includes `recording_id`. Before every pointer action, call `capture_recording_frame`
with that id and inspect the returned image. Use `perform_recording_action` with the returned
`observation_id`, a unique `action_id`, `action` (`move`, `click`, `scroll`), and normalized x/y
in the full uncropped image. For scrolling include `delta_y` (positive goes down). Coordinates
are the pointer hotspot, not an element's page coordinates. Never infer unseen controls.

To type demo text the user requested, click the observed input first, then capture a fresh frame
and call `perform_recording_text` with `recording_id`, `observation_id`, `action_id` and `text`.
It accepts one line of up to 1000 characters in an editable webpage field, refuses passwords and
browser chrome, and never presses Enter. Inspect a new image before any separately authorized
submit click. Text can trigger autosave; do not enter credentials or unrelated content.

An observation is single-use and expires after 60 seconds or window geometry changes. A
pause, stop, obscuring window or stale session refuses input. Reuse an uncertain `action_id`
only to retrieve its receipt; never blindly repeat a partially executed action with a new id.
The recorder dispatches and records the same measured pointer path, so physical mouse input
elsewhere cannot steal the camera. Inspect `get_project.interaction_trace`, clicks and zooms
when finished, then preview and export. Do not manually add zooms to make a failed test look successful.

`interaction_mode: "manual"` (the default) keeps normal system event tracking. Arbitrary
Codex browser/AX tool operations are not intercepted by this implementation; use the tracked
recording tools for synchronized automated demos. There is no universal CUA event stream.

### Record a window, edit, export into the working directory

1. `get_status` - Screen Recording granted? Note `music_tracks` (ids and titles for `set_background_music`).
2. `list_recording_sources` - pick a source id (or pass an app name, part of a window title, or `"display"`).
3. Tell the person what you are about to record and that a 3-second countdown will appear. Then
   `start_recording` with `source`, and usually `duration` (1-600 s, counted from the first frame).
   Optional per-recording settings: `browser_content_only`, `system_audio`, `microphone`, `frame_rate`
   (30 or 60), `automatic_zooms`. The call returns once the recording is live (`state: "recording"`,
   `started_at`, `auto_stop_at`). The recorder hides before the countdown and brings the selected
   window forward; a saved take returns to the editor, including timed and MCP stops.
   Sound: turn on `microphone` or `system_audio` only when the demo needs it. When the person's own
   recorder settings leave that sound off, Focus Studio asks the person before the countdown, every time:
   **Allow for this recording**; **Record without sound**, which records the screen with no sound at all,
   also none the recorder itself would record (`audio_consent.answer` is `"without_sound"` and `options`
   shows `microphone` and `system_audio` off: tell the person, and do not ask for sound again unless they
   want it); or **Cancel recording**, which returns an error saying the person did not allow sound (no answer
   within 60 seconds does too) and records nothing. A sound the person turns off in the recorder before the
   recording starts stays off, whatever you asked; `options` in the result is what is recorded. A recording
   that adds no sound starts without a prompt. Recording the microphone (allowed at the prompt, or on in the
   recorder) also needs macOS's permission: the first time, macOS asks the person before the countdown (no
   answer within 60 seconds returns an error and records nothing). If Focus Studio's microphone access is off
   (System Settings › Privacy & Security › Microphone), nothing records and the call returns an error with
   `status: "microphone_unavailable"`: tell the person, and call again with `microphone: false` to record
   without it. If the person has not answered about 200 seconds after the call, it returns
   `{status: "running", job_id}`: call `wait_for_job` for the recording's result.
4. Let the person perform the demo, or operate the recorded app with your own tools. Then
   `wait_for_recording` (`timeout_seconds` up to 240, default 120). `state: "finished"` carries the new
   `project_id`; `"cancelled"` means the person cancelled and nothing was saved. `"idle"` means the recording
   had already ended before the call (common with `duration`): `last_recording.state` says how it ended
   (`finished`, `cancelled` or `failed`) and `last_recording.project_id` holds the saved project. While it
   returns `"countdown"`, `"recording"` or `"stopping"` (still being saved), the wait timed out: call it
   again. `stop_recording` stops at once instead.
5. `get_project` with the `project_id` - duration, settings, zooms with ids, chapters, and the recorded clicks
   and typing moments. Plan zooms and chapters from these times.
6. Edit: `add_zoom` (`start`, `end`, `x`, `y`, optional `scale` 1.1-3), `remove_zoom` (`id`, `index` or
   `all: true`), `set_zoom_style`, `set_chapters` (`chapters: [{start, end, title, caption}]`, `append`),
   `update_settings` (background, padding, aspect ratio, `exportWidth`, `frameRate`, ...),
   `set_background_image`, `set_background_music` (`track`: id, title, audio file or `"none"`; `volume`),
   `set_sound_effects` (`click`, `zoom`, volumes).
7. `capture_frame` (`time` in seconds) to look at the result; it returns the rendered frame as an image.
8. `export_project` with `path: "./demo.mp4"` (relative to your working directory), optional `width`
   (1280, 1920, 2560, 3840) and `frame_rate` (24, 30, 60) for this export only. Report the absolute path it
   returns. A long export may answer `{status: "running", job_id}`: call `wait_for_job` with that `job_id`
   until it returns the export's result.

### Import a screenshot or a video

* `create_screenshot_demo` with the PNG/JPEG `path` - a 12-second demo with a gentle camera move; returns
  `project_id`. Add zooms and chapters, then export as above.
* `import_video` with an .mp4/.mov/.m4v `path` - the file is copied into the library. There are no recorded
  clicks, so add zooms with `add_zoom`.

### Find, rename, delete, join

* `list_projects` (newest first, 30 at a time; `query` searches titles, `offset` pages with `has_more`).
* `rename_project` (`title`, at most 120 characters).
* `delete_project` moves the project folder to the macOS Trash. Ask the person first unless they asked for
  that exact project to be deleted.
* `assemble_video` joins clips in order (`clips`, `transition: "cut" | "crossfade"`, `output: "1080p" | "720p"`),
  for example an intro, the exported demo and an outro. `list_assets` lists a project's assets folder (with
  `project_id`) or Focus Studio's AI Assets folder.

## Conventions

* Positions `x`, `y` run from 0 to 1, measured from the top-left corner of the recording (0.5, 0.5 is the
  centre). Times and durations are seconds within the recording.
* Editing tools, `capture_frame` and `export_project` take `project_id` (a UUID from `list_projects`,
  `stop_recording`, `wait_for_recording`, `import_video` or `create_screenshot_demo`). Focus Studio opens that
  project in its editor first (saving any other), so the person sees each change. `assemble_video` and
  `list_assets` take an optional `project_id`, which only picks that project's assets folder as the default
  location (otherwise Focus Studio's AI Assets folder), and never open the project.
* Paths are absolute or relative to your working directory; `~` is expanded. An existing file is replaced
  only with `overwrite: true`; ask before overwriting something you did not create. Exports never write the
  project's own recording and are refused inside the Focus Studio library (except the project's `ai` folder).
* `update_settings` and `set_zoom_style` use camelCase keys (`exportWidth`, `frameRate`, `zoomScale`);
  `export_project` takes `width` and `frame_rate` for one export only.
* Editing tools are refused while recording, while the app is busy or while its in-app assistant works;
  wait and try again. Calls that change what Focus Studio shows run one at a time; one whose time runs out
  while it waits for its turn returns an error with `status: "waiting_for_turn"` without running: call it
  again.
* A call still running about 200 seconds after it reached Focus Studio (a long export or assembly, a
  prompt the person has not answered yet) returns `{status: "running", job_id}` (with `activity` when it is
  waiting for the person): call `wait_for_job` until it returns the original call's result.
* Results are English text plus `structuredContent`; read the structured fields rather than parsing text.

## Etiquette

* The person is watching and in control. Say what you will record, and whether with sound, before
  `start_recording`; they see a countdown (naming you) and a control bar and may pause, resume or cancel at
  any time. If they cancel, or decline sound, ask before recording again.
* A paused recording records nothing, and paused time does not count toward `duration`: the automatic stop
  comes later by the time paused. `get_status` and `wait_for_recording` report `paused`; `stop_recording`
  still saves a paused recording.
* The control bar floats at the bottom centre of each display, just above the Dock (about 324 to 392 x 46
  points while recording; the person can expand it), and is not in the video. When you operate the recorded app
  yourself, keep its controls out of that area and stop with `stop_recording`, never by clicking the bar
  (its x discards the recording to the Trash).
* Clicks and typing sent over a browser's DevTools protocol (Playwright, Claude in Chrome), and some
  Accessibility-based automation, do not emit the system input events needed for automatic zooms.
  Keep `automatic_zooms: true`, but verify `clicks` and `zooms` with `get_project` after the take.
  Note the actual interaction times relative to `started_at` and add missing zooms with `add_zoom`.
  Explain when zooms were added from the shot log rather than automatically detected; never claim
  that enabling the setting can recover missing click metadata.
* Never read-modify-write `project.json` or anything under `~/Library/Application Support/FocusStudio`;
  use the tools.
* Do not work around the missing paid generation. The Seedream / Seedance skills in this repository
  (`ark-still-image`, `ark-video-clip`) cost money: use them only when the person asks, after a `--dry-run`
  cost estimate.

## Recording pace and editing

Use a short rehearsal when it helps identify the intended product route before capture. During a Codex-driven
take, model observation/decision time can still produce long pauses. The native pacing analyzer proposes
cuts from the real action metadata; `create_demo_cut` applies accepted keep ranges to a new project, and
`update_zoom` tunes each camera hold. Follow [focus-demo-editing](../focus-demo-editing/SKILL.md) to inspect
results, preserve meaningful visual/voice content, preview the new timeline and export. Editing cannot turn
an unsuccessful product action into a successful demonstration.

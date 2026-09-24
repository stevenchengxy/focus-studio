---
name: focus-studio-mcp
description: Operate the Focus Studio macOS app through its MCP server (tools named mcp__focus-studio__*) to record a display or window, edit the recording (zooms, chapters/captions, background, music, sound effects, export size) and export an MP4 into the working directory; also import a video or turn a screenshot into a demo, and list, search, rename or delete projects. Use whenever the user asks to record / 录制 / 录屏 a product demo, walkthrough or bug reproduction with Focus Studio, to add zooms, captions, 字幕, BGM or 配乐 to a Focus Studio project, or to export or re-export a Focus Studio demo video. Paid AI generation is not part of these tools.
---

# focus-studio-mcp - record, edit and export with Focus Studio over MCP

Focus Studio 1.5 ships an MCP server, `Focus Studio.app/Contents/MacOS/focus-studio-mcp`. Every tool runs
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

## The 24 tools

| Group | Tools |
| --- | --- |
| Status and library | `get_status`, `list_projects`, `get_project`, `rename_project`, `delete_project` |
| New projects from files | `import_video`, `create_screenshot_demo` |
| Recording | `list_recording_sources`, `start_recording`, `stop_recording`, `wait_for_recording` |
| Editing (by `project_id`) | `add_zoom`, `remove_zoom`, `set_zoom_style`, `update_settings`, `set_chapters`, `set_background_image`, `set_background_music`, `set_sound_effects` |
| Output | `capture_frame`, `export_project`, `assemble_video`, `list_assets` |
| Long calls | `wait_for_job` |

Not available over MCP: `generate_image`, `generate_video` (paid), clicks, key presses, shell commands.

## Typical flows

### Record a window, edit, export into the working directory

1. `get_status` - Screen Recording granted? Note `music_tracks` (ids and titles for `set_background_music`).
2. `list_recording_sources` - pick a source id (or pass an app name, part of a window title, or `"display"`).
3. Tell the person what you are about to record and that a 3-second countdown will appear. Then
   `start_recording` with `source`, and usually `duration` (1-600 s, counted from the first frame).
   Optional per-recording settings: `browser_content_only`, `system_audio`, `microphone`, `frame_rate`
   (30 or 60), `automatic_zooms`. The call returns once the recording is live (`state: "recording"`,
   `started_at`, `auto_stop_at`).
   Sound: turn on `microphone` or `system_audio` only when the demo needs it. When the person's own
   recorder settings leave that sound off, Focus Studio asks the person before the countdown, every time:
   **Allow for this recording**; **Record without sound**, which records the screen with no sound at all,
   also none the recorder itself would record (`audio_consent.answer` is `"without_sound"` and `options`
   shows `microphone` and `system_audio` off: tell the person, and do not ask for sound again unless they
   want it); or **Cancel recording**, which returns an error saying the person did not allow sound (no answer
   within 60 seconds does too) and records nothing. A sound the person turns off in the recorder before the
   recording starts stays off, whatever you asked; `options` in the result is what is recorded. A recording
   that adds no sound starts without a prompt. If the person has not answered about 200 seconds after the
   call, it returns `{status: "running", job_id}`: call `wait_for_job` for the recording's result.
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
  `start_recording`; they see a countdown and a control bar and may cancel at any time. If they cancel, or
  decline sound, ask before recording again.
* The control bar floats at the top centre of each display (about 590 x 72 points) and is not in the video.
  When you operate the recorded app yourself, keep its controls out of that area and stop with
  `stop_recording`, never by clicking the bar (its x deletes the recording).
* Clicks and typing sent over a browser's DevTools protocol (Playwright, Claude in Chrome) are not real input
  events and make no automatic zooms. Note when you acted and add zooms afterwards with `add_zoom`.
* Never read-modify-write `project.json` or anything under `~/Library/Application Support/FocusStudio`;
  use the tools.
* Do not work around the missing paid generation. The Seedream / Seedance skills in this repository
  (`ark-still-image`, `ark-video-clip`) cost money: use them only when the person asks, after a `--dry-run`
  cost estimate.

## Outlook: rehearse, then shoot

Recording while an AI operates step by step gives long idle stretches, jumping cursors and visible retries.
Focus Studio's planned director mode (GitHub issue #2) splits the work: the AI rehearses with its own tools
without recording, writes a shot script, and Focus Studio executes and records it. Until then, apply the same
idea by hand: explore the target app first without recording, reset it to its starting state, then record a
short take with `duration` in which you (or the person) perform only the planned steps, and fix pacing
afterwards with zooms and chapters. Re-record rather than ship a take full of mistakes.

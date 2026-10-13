# Recording and editing sound

## Native macOS editor

Screen capture can include system sound and microphone input. Those captured inputs may already be combined in the source movie; changing the source volume changes that combined track. This release does not promise separate controls for tracks that were recorded together.

In the Audio inspector, use **Record voiceover** for a new microphone take, or import a local audio file. Recording starts at the selected timeline position with the video paused. The recorder shows elapsed time and measured microphone level; Stop inserts the take, and Cancel or leaving the panel stops and discards it. Microphone permission is requested before recording. AI tools cannot silently start this microphone recorder.

Each added voiceover has a stable identifier, source in/out points, timeline start, volume, fades and enabled state. Restore the full source range after trimming. Multiple voiceovers can overlap. Video cuts and reorders remap narration, and undo restores the corresponding audio edit. Music can duck during enabled narration, defaulting to 25% of its configured volume. Preview and export build the same audio mix.

Missing narration files cause an explicit error instead of silently producing a video with missing sound. Keep original media until the project has copied it successfully.

## Codex / MCP

Inspect `get_project` before editing. Its audio report includes voiceovers and mix settings. Use stable IDs returned by that report, never infer IDs from display order.

- `edit_voiceover`: add a local audio file; update its timing, source range, volume, fades or enabled state; remove it from the edit.
- `set_audio_mix`: set recorded-audio gain, music gain/fades, and narration ducking.
- `undo_clip_edit`: undo audio edits as part of the project's editing history.

For example, ask Codex: “Add this narration at 2 seconds, use seconds 1–8 of the audio, fade in over 0.2 seconds, and lower background music to 25% during narration. Preview before exporting.” File access and export use the app's existing authorization rules.

## Browser and Windows/Linux Desktop Preview

Enable microphone input before starting screen capture, or use **Sound → Record voiceover** after recording. Input selection and voice-clarity processing are available in Recording inputs. Shared audio is optional and depends on the capture surface; Windows desktop loopback includes all system sounds, while Linux desktop system capture is unavailable in this preview.

The preview supports one added narration/music track, a waveform, source trim, timeline offset, volume, fades, removal and undo. Imported audio is limited to 25 MB / 2 minutes, with a 128 MB decoded-audio budget per edit. The source recording and added audio are mixed locally into the exported video. Keep the window open until export; this preview does not persist an editable project.

During video decoding waits, narration pauses and re-aligns when playback resumes. A decoding stall during export stops the render and releases its allowance rather than saving an out-of-sync result. The existing rendered-export recovery journal protects completed renders during a connection failure.

## Validation

- Native 8-second tone fixture compares preview PCM with exported MP4, including trim, offset, fades, source gain and ducking. Music during narration measured 25% of its configured gain in both paths.
- Browser `OfflineAudioContext` checks actual output samples, overlapping fades, seeking into narration and truncation at the video end. A real `MediaRecorder` output was decoded to verify that both source sound and narration were included.
- Browser UI: audio import, source trim, placement, fade edits, removal and undo verified.
- A permission-approved physical Mac microphone take produced decodable AAC-LC, 48 kHz mono audio with nonzero samples and no decode errors. The UI captured 10.26 seconds (10.304 seconds including AAC framing), then source-out was trimmed to 5 seconds. Preview playback and undo were verified, and the test project's audio state was restored. The recording stayed local and was not transcribed or uploaded.
- Platform CI checks Electron startup, sandboxed bridge and chooser, and builds Windows/Linux installers. Physical microphone and Windows loopback capture still need acceptance on those actual systems.

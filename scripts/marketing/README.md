# Native effect reel

The 16-second website reel uses the production `ProjectVideoRenderer` with perspective, magnifier, animated outline and lifted/blurred region effects. Aster is a fictional dashboard created for this showcase; no customer recording or third-party product asset is used.

`assets/aster-source.jpg` is a browser screenshot of `website/public/demo-source.html` at 1496×812. The source is still imagery, not a claim that a real product was automatically operated. The surrounding website labels the reel as effect samples.

On macOS 15+ with Swift and FFmpeg, run `zsh scripts/marketing/render-demo.sh`. Output is 1280×720, 30 fps, silent H.264 MP4. These developer fixtures render directly through the core compositor; they do not test the production MCP control path.

The homepage uses `focus-studio-demo-flat.mp4`, the same native export from 4.15s to the end. This removes the perspective shot and plays the magnifier, outline and lift effects consecutively, without browser-generated camera rotation. The sample dashboard remains fictional. The editing feature uses a crop of the authentic `focus-studio-editor.jpg` screenshot, not a simulated timeline. Both media sources were already included in the original public launch.

Regenerate the level reel and its opening poster after the full render:

```sh
ffmpeg -i website/public/media/focus-studio-demo.mp4 -ss 4.15 -t 11.85 -an -c:v libx264 -preset slow -crf 20 -pix_fmt yuv420p -movflags +faststart website/public/media/focus-studio-demo-flat.mp4
ffmpeg -i website/public/media/focus-studio-demo-flat.mp4 -frames:v 1 -q:v 2 website/public/media/focus-studio-demo-flat.jpg
```

## Recording the real native client

The normal recorder changes its main window to the recording page, and display
capture excludes Focus Studio's own windows. For a tutorial of the editor itself,
the developer target can capture that exact native window through the same
`FocusStudioCapture.CaptureEngine`, without opening a second client or touching
the user's project library. This is a production capture/compositor exercise,
not a substitute for a separate real MCP recording test.

Prepare the real client window at its final size, obtain its current Window
Server ID from the live source list, then use a fresh output directory:

```sh
swift build --product FocusStudioE2E
.build/debug/FocusStudioE2E --record-window-id WINDOW_ID --record-duration 90 \
  --render-recorded-cursor --output-dir "$PWD/.artifacts/tutorials/editor-take-01"
```

Wait for the JSON `state: recording` after the three-second countdown before
operating the UI. The default limit is 90 seconds (accepted range: 1–600). End a
take early from another terminal with:

```sh
touch "$PWD/.artifacts/tutorials/editor-take-01/stop-recording"
```

The output folder contains `source.mp4`, `capture-trace.json` (timestamps and
normalized cursor/click positions; never typed text), and, with the rendering
flag, `with-cursor.mp4`. The latter uses the shipping compositor at up to 1920 px
wide, 30 fps, with no border or automatic zoom. The source capture is up to
2560 px wide/high, 30 fps. Microphone and system audio are always off. Existing
output files are refused. Normal macOS recording/input permissions still apply;
the command does not approve permissions or alter TCC. Missing cursor permission
is reported in the trace, not hidden. Import the finished video with the normal
Focus Studio MCP `import_video` tool for clipping, zooms, chapters and export.

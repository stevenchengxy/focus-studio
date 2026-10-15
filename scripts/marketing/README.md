# Native effect reel

The 16-second website reel uses the production `ProjectVideoRenderer` with perspective, magnifier, animated outline and lifted/blurred region effects. Aster is a fictional dashboard created for this showcase; no customer recording or third-party product asset is used.

`assets/aster-source.jpg` is a browser screenshot of `website/public/demo-source.html` at 1496×812. The source is still imagery, not a claim that a real product was automatically operated. The surrounding website labels the reel as effect samples.

On macOS 15+ with Swift and FFmpeg, run `zsh scripts/marketing/render-demo.sh`. Output is 1280×720, 30 fps, silent H.264 MP4. These developer fixtures render directly through the core compositor; production editor, MCP and AI export entry points use account entitlements.

The homepage uses `focus-studio-demo-flat.mp4`, the same native export from 4.15s to the end. This removes the perspective shot and plays the magnifier, outline and lift effects consecutively, without browser-generated camera rotation. The sample dashboard remains fictional. The editing feature uses a crop of the authentic `focus-studio-editor.jpg` screenshot, not a simulated timeline. Both media sources were already included in the original public launch.

Regenerate the level reel and its opening poster after the full render:

```sh
ffmpeg -i website/public/media/focus-studio-demo.mp4 -ss 4.15 -t 11.85 -an -c:v libx264 -preset slow -crf 20 -pix_fmt yuv420p -movflags +faststart website/public/media/focus-studio-demo-flat.mp4
ffmpeg -i website/public/media/focus-studio-demo-flat.mp4 -frames:v 1 -q:v 2 website/public/media/focus-studio-demo-flat.jpg
```

# Native effect reel

The 16-second website reel uses the production `ProjectVideoRenderer` with perspective, magnifier, animated outline and lifted/blurred region effects. Aster is a fictional dashboard created for this showcase; no customer recording or third-party product asset is used.

`assets/aster-source.jpg` is a browser screenshot of `website/public/demo-source.html` at 1496×812. The source is still imagery, not a claim that a real product was automatically operated. The surrounding website labels the reel as effect samples.

On macOS 15+ with Swift and FFmpeg, run `zsh scripts/marketing/render-demo.sh`. Output is 1280×720, 30 fps, silent H.264 MP4. These developer fixtures render directly through the core compositor; production editor, MCP and AI export entry points use account entitlements.

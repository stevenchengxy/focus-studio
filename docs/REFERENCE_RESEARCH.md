# Product reference research

Focus Studio was implemented independently in Swift using Apple's public macOS frameworks. No Recordly source files are included in this repository.

The following products were used to validate feature scope and terminology:

- [Screen Studio](https://screen.studio/) and its official guide: recording targets, automatic/manual zooms, editable purple zoom timeline, cursor controls, background/frame styling, aspect ratios, and MP4/GIF export.
- [Recordly](https://github.com/webadderallorg/Recordly): an AGPL-3.0 open-source alternative that confirms the practical architecture of native capture plus separate cursor telemetry and a renderer-driven editor.

Recordly is AGPL-3.0 and has explicit branding/attribution conditions. For that reason, this project does not copy or vendor its implementation. Recordly was used only as an external behavioral benchmark while the local native implementation, data model, timing math, renderer, tests, and UI were authored separately.

# Focus Studio original audio library

Focus Studio ships two clearly separated groups: deterministic originals made
by `scripts/generate-audio-assets.swift`, and two author-uploaded CC0 tracks
whose provenance is recorded below and in `catalog.json`.

## Original music

| File | Style | Length | Suggested level |
| --- | --- | ---: | ---: |
| `product-demo-bed.wav` | Polished light-technology bed | 55.385 s | 16% |
| `calm-gradient-bed.wav` | Spacious ambient, narration-friendly | 53.333 s | 17% |
| `bright-launch-bed.wav` | Fast, optimistic feature launch | 30.968 s | 14% |
| `midnight-focus-bed.wav` | Dark minimal pulse for analytics/dev tools | 43.636 s | 16% |

These four WAV files contain no third-party recordings, samples, melodies, or
downloaded media.

## CC0 music

| File | Title / author | Length | Level | Source format | SHA-256 |
| --- | --- | ---: | ---: | --- | --- |
| `city-loop.mp3` | City Loop — wipics | 56.4245 s | 8% | MP3, 44.1 kHz stereo, 192 kb/s | `9349982fb8e365167bc5c89f2ac50d3b5376b9f627d506ba30a9b26c8230597e` |
| `overworld.mp3` | Overworld (BGM) — IntelligentGene / Another Page Studio | 9.840 s | 26% | MP3, 48 kHz stereo, ~224 kb/s | `d32949f8467ac463a52ca88ed250e505545bc98a46e4e472c1f994bf447a1beb` |

Both creator-uploaded work pages mark the exact recording as **CC0**, and both
download responses identify the payload as `audio/mpeg`:

- **City Loop:** [work page](https://opengameart.org/content/city-loop-0) ·
  [original MP3](https://opengameart.org/sites/default/files/city-loop_0.mp3)
- **Overworld (BGM):** [work page](https://opengameart.org/content/overworld-bgm) ·
  [original MP3](https://opengameart.org/sites/default/files/overworld.mp3)
- License: [CC0 1.0 Universal](https://creativecommons.org/publicdomain/zero/1.0/)

CC0 permits copying, modification, distribution, performance, and commercial
use without requesting permission. Attribution is not required; author names
remain in Focus Studio's catalog for provenance and courtesy. Do not imply that
the original authors endorse Focus Studio.

## Sound effects

| File | Use | Length | Suggested level |
| --- | --- | ---: | ---: |
| `ui-click.wav` | Crisp interface confirmation | 0.105 s | 28% |
| `soft-tap.wav` | Friendly, restrained selection | 0.130 s | 30% |
| `typing-key.wav` | Subtle input/typing cue | 0.075 s | 20% |
| `zoom-whoosh.wav` | Soft left-to-right zoom transition | 0.460 s | 18% |

Machine-readable titles, moods, durations, and paths are stored in
`catalog.json` and loaded by `AudioAssetCatalog`.

## Rights and provenance

The original assets were created specifically for the Focus Studio project from the
deterministic synthesis source committed in this repository. The Focus Studio
project owner may use, modify, bundle, redistribute, and commercially publish
them without attribution. Regenerate every WAV at any time with:

```sh
swift scripts/generate-audio-assets.swift Resources/Audio
```

During the September 2026 review we required the creator's work page to apply
CC0 to the exact recording before it could enter the network library. General
public-domain guidance used for that review:

- Creative Commons CC0 deed: <https://creativecommons.org/publicdomain/zero/1.0/>
- Creative Commons public-domain guidance: <https://creativecommons.org/public-domain/>
- FreePD's original site closed in 2025, so its historical catalog was not used:
  <https://freepd.com/>

Three creator-uploaded CC0 candidates were also reviewed but are not bundled:

- **Exploration Theme** by Cleyton Kauffman — suitable mood, but supplied as a
  32.5 MB archive: <https://opengameart.org/content/exploration-theme>
- **Sunset Plains** by Yoiyami — clear CC0 notice, but the source WAV alone is
  63.3 MB: <https://opengameart.org/content/sunset-plains>
- **Ambient-ish Stuff** by frosty ham — compact CC0 OGG files, but not mastered
  to the same product-demo loudness and loop standard as this library:
  <https://opengameart.org/content/ambient-ish-stuff>

The current Pixabay license was not used because it prohibits distributing
content on a standalone basis, which is relevant when a desktop editor exposes
the original asset to projects. Mixkit's music license targets finished media
uses and explicitly excludes some software/media categories. Official terms:

- Pixabay Content License: <https://pixabay.com/service/license-summary/>
- Mixkit Stock Music Free License: <https://mixkit.co/license/modal/musicFree/>

## Product-demo mix starting point

- Music: 12–18%, with a 1 second fade-in and a 1.5–2 second fade-out.
- UI click/tap: 20–30%, only on high-value selections rather than every click.
- Zoom whoosh: 14–20%, aligned roughly 80 ms before the visual move begins.
- If narration is present, duck music to 8–12% underneath speech.

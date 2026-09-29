# Product-led AI promo shot recipes

Use these recipes to coach a user toward a convincing product film. Do **not** send these paragraphs wholesale to a video model. First extract the product claim, real UI evidence, and brand palette; then output a shot plan and generation prompt for the *generated plate only*.

## Reference-backed rules

- Official examples: [Apple Intelligence — Privacy](https://www.youtube.com/watch?v=546ufMY7488), [Gemini 2.0](https://www.youtube.com/watch?v=Fs0t6SdODd8), [Gemini 3](https://www.youtube.com/watch?v=98DcoXwGX6I), [Google Vids](https://www.youtube.com/watch?v=4SCjXcBeW1E), and [Notion AI](https://www.youtube.com/watch?v=S92KX8-Hmlc). See [the timestamped research](../../../docs/AI-PROMO-REFERENCE.md).
- Observe: the films show **real interfaces and real outcomes** with graphics providing hierarchy. Infer: for Focus Studio, keep UI capture, charts, account values, typography, and logos as compositor-controlled layers. AI-generated footage is suitable for a brand-neutral environment, restrained abstract divider, or atmospheric background.
- [Gemini's visual designers](https://design.google/library/gemini-ai-visual-design) describe motion with a start, destination, and attentional purpose. [Apple's motion guidance](https://developer.apple.com/design/human-interface-guidelines/motion) advises brevity and restraint. Translate both into one dominant action per 5–8-second shot.
- Never copy Apple/Google/Notion marks, layouts, distinctive shapes, fonts, or exact color systems. Derive each project's look from that product's own assets. The linked Finlyze study is one example, not a default brand or subject.

## Coach the user before prompting

Ask for or infer from the current project: one-sentence audience outcome, 1–2 authentic product screens, the single interaction to feature, placement (opener/bridge/closer/clip enhancement), brand palette, output ratio and length. If a product claim is unknown, offer a neutral placeholder for user review. Show two or three concepts with a concrete timeline, UI source, generated plate, and compositing layers. Do not generate or charge until the chosen model and cost are confirmed.

For each candidate, return this compact structure:

```
Concept: [specific user benefit, not "futuristic AI"]
Duration/ratio: [e.g. 7 s / 16:9]
0.0–1.5: [what the viewer sees]
1.5–4.5: [one motion tied to one real product action]
4.5–7.0: [proof/result and readable hold]
Authentic layers: [screenshot/recording, title, data, cursor]
Generated layer: [background/environment/transition only]
Video model prompt: [subject + composition + action + camera + light + exact duration + exclusions]
Finish in editor: [mask/crop/zoom/title/sound/transition, all undoable]
QA: [legibility, data truth, temporal continuity, artifact check]
```

## Recipe A — Signal to decision (7 s)

Best when the recorded product contains an actual chart, insight, or comparison worth explaining. Composite the original UI above a generated quiet background; selectively highlight one real region. Do not feed the screenshot to a video model and expect it to preserve numbers.

**Generated plate prompt (adapt the brand color):**

> Seven-second 16:9 restrained editorial motion background for [the actual product category]. [A neutral surface matching the supplied brand palette], one fine line enters from the left and curves gently toward a clear rectangular negative-space region in the center-right. Static virtual camera, no perspective tunnel, no particles, no light streaks, no glass panels, no invented product graphics, no data, no interface, no text, no logos. Hold the final composition still for the last 1.2 seconds. This is only a background plate for an authentic UI composite.

**Finish in Focus Studio:** cut from the generated plate to the real dashboard; use a restrained native zoom toward one chart, then a chapter caption and a quiet sound accent as the answer appears. Keep exact data from the recording. A tracked mask or graphic callout needs a separate compositor until the editor supports overlay tracks.

## Recipe B — Editorial proof (6 s)

Best when the user wants Apple's clarity or Notion's graphic directness without copying either brand. The hero is a real screen recording on a light field, with one short claim and a single mask reveal. A video generation call may be unnecessary; editor-native colors, type, and motion usually yield higher quality and perfect text.

**Optional generated plate prompt:**

> Six-second 16:9 clean paper-like background in [the project's neutral tone], with a barely perceptible shift toward [its accent color] in one corner. No objects, no typography, no device, no interface, no shadows moving across the center. Locked camera. Leave the middle two-thirds uniformly clean for sharp UI compositing. Maintain visual stillness during the final 1.5 seconds.

**Finish in Focus Studio:** use a native chapter caption for the specific benefit, cut or fade to authentic UI, keep one cursor action and a readable result hold. Use no more than one transition. A masked UI reveal requires an external compositor.

## Recipe C — Context to screen (8 s)

Best when adding a human or spatial opening before a product demo. Generate the environment, then replace the screen with actual recorded product footage via a tracked planar composite or cut to full-screen capture. Do not request a fake interface in the generated shot.

**Generated plate prompt:**

> Eight-second 16:9 natural product-film shot of a minimal work desk in soft morning light, one unbranded laptop viewed at a three-quarter angle. The laptop display is a uniform mid-gray tracking surface with no UI, no reflections covering it and four clearly visible corners. Camera makes a slow, straight push toward the screen without orbit or shake; exposure and focus remain stable. No faces, no hands crossing the screen, no readable text, no logos. Hold the screen nearly front-on for the last 1.5 seconds.

**Finish in Focus Studio:** cut from the generated laptop plate to the real product recording full-screen; add one interaction zoom and one benefit caption. Focus Studio does not yet support perspective-tracked screen replacement, so do not claim the laptop display contains the real product. Such a composite requires a separate tracking-capable editor.

## Common failure checks

- Reject output if it contains invented UI, gibberish text, mutated hands or devices, generic blue warp tunnel, excessive bloom, twitching frames, or a result that cannot be read before the next cut.
- Rework a plate if its line/shape does not lead to the actual screen element. The animation needs a visual reason.
- For AI refinement of an existing clip, preserve the source and create an undoable derivative: trim idle time, stabilize pacing, add crop/zoom, captions, callouts, sound design, or background. Do not silently replace original screenshots with generated pixels.
- After generation, preview the entire clip in-app with scrub/playback before adding it to a project. Report the chosen model and actual resolution/duration; ask before substituting a different model.

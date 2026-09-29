# Seedance prompts for product demos

Use this reference when writing a Seedance prompt for a Focus Studio demo. For a complete shot plan, first read [focus-ai-promo](../../focus-ai-promo/SKILL.md) and its [shot recipes](../../focus-ai-promo/references/shot-recipes.md). The [timestamped reference study](../../../docs/AI-PROMO-REFERENCE.md) explains why the older glass-panel / purple-light prompt failed.

## Product first

Decide what real product action or result this shot proves. Keep authentic UI, exact text, charts, numbers, logos and cursor movement in the recording or editor layers. Ask Seedance for a background plate, environment, short transition, or visual metaphor that serves that action. A generated dashboard is usually misleading and visibly wrong.

Build one shot with: subject and spatial composition; one motion with a beginning and end; a restrained camera move; light and material tied to the product's actual palette; duration, ratio and a final readable hold. State where the authentic UI/title will be composited. Avoid the generic formula of blue-purple warp tunnel, floating glass cards, particle streams and volumetric glow unless the user has selected that exact direction.

Example for any recorded product moment (replace the bracketed details with the current project's evidence):

> Six-second 16:9 quiet editorial background plate for [the recorded product action and its audience benefit]. [A neutral surface drawn from this product's own palette] with one subtle accent tint sampled from the supplied screenshot. A fine guide line enters from the left, curves toward the clear center-right inset reserved for the real captured UI, then stops. Locked camera, gentle depth only at the edges. Leave the center sharp and still for the final 1.2 seconds. No invented interface, charts, numbers, letters, logo, glass panels, particles, bright tunnel, or rapid cuts.

Use an approved product screenshot as a first frame only when its appearance should remain in the generated pixels. Even then, inspect every frame for distorted text and values; prefer compositing the original capture over the generated plate. For a variation of an existing clip, use Focus Studio's `prepare_clip_ai_reference` to obtain its first/last frame and silent short reference video, then submit only the references needed by the selected model.

## Model and cost

Use the model the user selected in Focus Studio or named explicitly. Do not silently switch to mini for drafts. Show the exact model ID, ratio, resolution, duration, and current estimate before a paid call. Model availability and prices change; use the provider's current model list and Focus Studio's estimate instead of fixed numbers in a prompt template. If a model is unavailable, stop with the provider's actual error and let the user choose another.

After generation, preview the whole MP4 in Focus Studio, checking motion, legibility, continuity, artifacts, and actual duration. Save a usable result in the shared library; import it into a particular project or replace a clip only when requested. Preserve the original recording and support undo for timeline edits.

---
name: focus-ai-promo
description: Plan and finish product-led AI promo shots for Focus Studio demos. Use when a user asks for Apple/Gemini-like polish, a Seedance opener, visual effects, prompt coaching, or a text-directed variation of one recorded clip. Produces a shot plan and editable composition using authentic product footage plus optional AI-generated plates.
---

# Product-led AI promo shots

Make the product action or result visible before adding style. Read [shot recipes](references/shot-recipes.md) for three concrete directions and the [reference study](../../docs/AI-PROMO-REFERENCE.md) when comparing Apple, Gemini, Google Vids and Notion examples. Use their pacing principles, not their marks, layouts or footage.

For a vague brief, show two or three short treatments with the specific user benefit, timeline beats, actual UI source, generated layer, typography/caption layer, and final hold. Ask for the missing product claim or brand asset only when it changes the shot. A still keyframe is useful when composition or continuity matters; a text-only motion prompt is enough for a background plate. Keep generated UI, data, logos and precise text out of factual product scenes.

For an existing clip, read `get_timeline`, choose its stable clip ID, run `prepare_clip_ai_reference`, and inspect the frames. Use the user's text instruction to describe one specific change. If generation is needed, select the requested configured video model and pass compatible first/last frames or the silent reference video to `generate_video`; the app shows the exact model and estimate before charging. Review the output in-app. The source clip remains intact; import the generated asset into the current project and place it on the timeline only when the user asks for that edit. Native trim, zoom, titles, transitions and audio are often better than generating pixels for an authentic UI moment.

Evaluate the result for a real product claim, readable UI and text, stable motion, expected duration and aspect ratio, and a clean cut into neighboring footage. If a generated plate fails, revise the one shot and reference that caused the failure; avoid rerunning the same paid request without a change. Link the preview and state the actual model used.

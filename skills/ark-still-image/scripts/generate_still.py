#!/usr/bin/env python3
"""
generate_still.py - generate one still image with Volcengine Ark (火山方舟) Seedream.

Examples
--------
  # 16:9 hero background for a title card (≈0.25-0.3 元 per 2K image)
  python3 generate_still.py --preset hero-bg --ratio 16:9 --size 2K \
      --prompt "deep purple tech product, glass panels, soft light" --out ai-clips/hero-bg.png

  # restyle a Focus Studio screenshot into a marketing hero (reference image = local file or URL)
  python3 generate_still.py --preset restyle-screenshot --reference shot.png \
      --prompt "dark purple gradient, floating glass card" --out assets/hero.png

  # feature icon
  python3 generate_still.py --preset feature-icon --prompt "a cursor with a zoom lens" --out assets/icon-zoom.png

  # show the request and cost estimate only
  python3 generate_still.py --prompt "..." --dry-run

Outputs: the image at --out (converted with Pillow if the API returns another format), a
sidecar <out>.json and a cache entry in <out dir>/.cache (same request => no second bill).
"""
from __future__ import annotations

import argparse
import json
import math
import os
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve()


def _find_shared() -> Path:
    env = os.environ.get("FOCUS_SKILLS_SHARED")
    candidates = ([Path(env)] if env else []) + [
        HERE.parents[1] / "_shared", HERE.parents[2] / "_shared", Path.home() / ".claude" / "skills" / "_shared"]
    for c in candidates:
        if (c / "ark_client.py").is_file():
            return c
    sys.exit("error: cannot find _shared/ark_client.py - copy the `_shared` folder next to this skill "
             "folder or set FOCUS_SKILLS_SHARED=/path/to/_shared")


sys.path.insert(0, str(_find_shared()))
from ark_client import (  # noqa: E402
    ArkAPIError, ArkClient, ArkConfigError, ArkError, Cache, DEFAULT_IMAGE_MODEL, IMAGE_MODELS,
    redact_for_display, resolve_image_ref, run_image_generation,
)

EXIT_USAGE, EXIT_CONFIG, EXIT_API = 2, 3, 4

# Recommended explicit sizes per class and ratio (Seedream accepts "1K"/"2K"/"4K" or "WxH").
# Explicit pixels make the aspect ratio deterministic; the class string lets the model choose.
SIZE_TABLE = {
    "1K": {"1:1": (1024, 1024), "16:9": (1280, 720), "9:16": (720, 1280), "4:3": (1152, 864), "3:4": (864, 1152),
           "3:2": (1248, 832), "2:3": (832, 1248), "21:9": (1512, 648)},
    "2K": {"1:1": (2048, 2048), "16:9": (2560, 1440), "9:16": (1440, 2560), "4:3": (2304, 1728), "3:4": (1728, 2304),
           "3:2": (2496, 1664), "2:3": (1664, 2496), "21:9": (3024, 1296)},
    "4K": {"1:1": (4096, 4096), "16:9": (4096, 2304), "9:16": (2304, 4096), "4:3": (4096, 3072), "3:4": (3072, 4096),
           "3:2": (4096, 2730), "2:3": (2730, 4096), "21:9": (4096, 1755)},
}

# Prompt scaffolding for product-demo assets. {prompt} is the user's description.
# All presets forbid text/logos because captions are rendered later by the composer.
PRESETS = {
    "none": "{prompt}",
    "hero-bg": (
        "Cinematic widescreen hero background for an enterprise software product video. {prompt}. "
        "Abstract composition: layered frosted glass panels, soft volumetric light, subtle depth of field, "
        "deep gradient, clean negative space in the center for a title. Photorealistic 3D render, high detail. "
        "No text, no letters, no numbers, no logos, no watermark, no people, no hands."),
    "title-card": (
        "Elegant dark title card background for a technology product launch video. {prompt}. "
        "Minimal, premium, soft glow at the edges, darker center so white text stays readable, "
        "fine film grain, restrained color palette. No text, no letters, no logos, no watermark, no people."),
    "feature-icon": (
        "A single minimal 3D glass icon representing {prompt}, centered on a plain dark background, "
        "soft studio lighting, subtle rim light, gentle reflections, product-design style, lots of empty space around it. "
        "No text, no letters, no logos, no watermark."),
    "restyle-screenshot": (
        "Turn the reference screenshot into a polished marketing hero image. Keep the interface layout, colors and "
        "content exactly as shown and fully legible; place the screen on a floating glass card with soft shadow and a "
        "thin highlight edge, slight perspective tilt, above a background of: {prompt}. "
        "Premium enterprise software aesthetic. Do not add any extra text, labels, logos or watermark."),
}


def resolve_size(size: str, ratio: str | None) -> str:
    s = size.strip().upper()
    if re.fullmatch(r"\d{3,4}X\d{3,4}", s):
        w, h = (int(v) for v in s.split("X"))
        if w * h < 1280 * 720 or max(w, h) > 4096:
            raise ArkError("explicit size must be between 1280x720 (area) and 4096 px on the long side")
        return f"{w}x{h}"
    if s not in SIZE_TABLE:
        raise ArkError("--size must be 1K, 2K, 4K or WxH (e.g. 2560x1440)")
    if not ratio:
        return s
    table = SIZE_TABLE[s]
    if ratio in table:
        w, h = table[ratio]
        return f"{w}x{h}"
    m = re.fullmatch(r"(\d+):(\d+)", ratio)
    if not m:
        raise ArkError("--ratio must look like 16:9")
    rw, rh = int(m.group(1)), int(m.group(2))
    area = {"1K": 1024 * 1024, "2K": 2048 * 2048, "4K": 4096 * 4096}[s]
    w = int(math.sqrt(area * rw / rh) // 16 * 16)
    h = int(w * rh / rw // 16 * 16)
    w, h = min(w, 4096), min(h, 4096)
    return f"{w}x{h}"


def parse_args(argv=None) -> argparse.Namespace:
    ap = argparse.ArgumentParser(
        prog="generate_still.py",
        description="Generate a still image (title card, hero background, feature icon, restyled screenshot) with Seedream.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Models: " + ", ".join(IMAGE_MODELS) + "\nPresets: " + ", ".join(PRESETS) +
               "\nExit codes: 0 ok, 2 usage, 3 key missing, 4 API error")
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--prompt", help="description (Chinese or English). Do not ask for on-screen text; captions come later")
    src.add_argument("--prompt-file", help="read the prompt from a UTF-8 text file")
    ap.add_argument("--preset", default="none", choices=sorted(PRESETS), help="wrap the prompt in product-demo scaffolding")
    ap.add_argument("--model", default=DEFAULT_IMAGE_MODEL, help=f"Seedream model id (default {DEFAULT_IMAGE_MODEL})")
    ap.add_argument("--size", default="2K", help="1K | 2K | 4K | WxH (default 2K). With --ratio a class is turned into explicit pixels")
    ap.add_argument("--ratio", help="16:9, 9:16, 1:1, 4:3, 3:4, 3:2, 2:3, 21:9 (hero-bg/title-card default to 16:9)")
    ap.add_argument("--reference", metavar="IMG", action="append", default=[], help="reference image path or URL (repeatable, up to 10)")
    ap.add_argument("--out", help="output path; .png/.jpg/.webp (default ai-clips/still-<hash>.png)")
    ap.add_argument("--seed", type=int, help="seed (also part of the cache key)")
    ap.add_argument("--format", choices=["png", "jpeg", "webp"], help="ask the API for this output_format (otherwise converted locally)")
    ap.add_argument("--watermark", action="store_true", help="keep the provider watermark (default off)")
    ap.add_argument("--extra", help="JSON object merged into the request body")
    ap.add_argument("--max-image-side", type=int, default=2048, help="downscale local reference images before embedding")
    ap.add_argument("--cache-dir", help="cache directory (default <out dir>/.cache)")
    ap.add_argument("--force", action="store_true", help="ignore the cache and generate again (bills again)")
    ap.add_argument("--dry-run", action="store_true", help="print the request JSON and cost estimate; no network call")
    ap.add_argument("--json", action="store_true", help="print the result record as JSON on stdout")
    ap.add_argument("--verbose", action="store_true", help="log HTTP calls (never the key)")
    return ap.parse_args(argv)


def main(argv=None) -> int:
    args = parse_args(argv)
    log = lambda m: print(m, file=sys.stderr, flush=True)  # noqa: E731
    prompt = args.prompt
    if args.prompt_file:
        try:
            prompt = Path(args.prompt_file).read_text(encoding="utf-8")
        except OSError as e:
            print(f"error: cannot read prompt file: {e}", file=sys.stderr)
            return EXIT_USAGE
    if not prompt or not prompt.strip():
        print("error: prompt is empty", file=sys.stderr)
        return EXIT_USAGE
    if args.preset == "restyle-screenshot" and not args.reference:
        print("error: --preset restyle-screenshot needs --reference <screenshot>", file=sys.stderr)
        return EXIT_USAGE
    if len(args.reference) > 10:
        print("error: at most 10 reference images", file=sys.stderr)
        return EXIT_USAGE
    if args.model not in IMAGE_MODELS:
        log(f"warning: {args.model} is not in the known model table; the API decides whether it exists")
    ratio = args.ratio or ("16:9" if args.preset in ("hero-bg", "title-card") else None)
    extra = None
    if args.extra:
        try:
            extra = json.loads(args.extra)
            assert isinstance(extra, dict)
        except Exception:
            print("error: --extra must be a JSON object", file=sys.stderr)
            return EXIT_USAGE

    full_prompt = PRESETS[args.preset].format(prompt=prompt.strip())
    try:
        size = resolve_size(args.size, ratio)
        refs = [resolve_image_ref(r, max_side=args.max_image_side) for r in args.reference]
        payload = ArkClient.build_image_payload(args.model, full_prompt, images=refs, size=size, response_format="url",
                                                watermark=bool(args.watermark), seed=args.seed,
                                                output_format=args.format, extra=extra)
    except ArkError as e:
        print(f"error: {e}", file=sys.stderr)
        return EXIT_USAGE

    key = Cache.key_for("image", payload)
    out = Path(args.out) if args.out else Path("ai-clips") / f"still-{key[:8]}.png"
    try:
        record = run_image_generation(payload, out, cache_dir=args.cache_dir, dry_run=args.dry_run, force=args.force,
                                      verbose=args.verbose, log=log)
    except ArkConfigError as e:
        print(f"error: {e}", file=sys.stderr)
        return EXIT_CONFIG
    except ArkAPIError as e:
        print(f"error: {e}", file=sys.stderr)
        if e.status == 400:
            print("hint: 400 means a rejected parameter (size/ratio/model/reference) - see the message above", file=sys.stderr)
        return EXIT_API
    except ArkError as e:
        print(f"error: {e}", file=sys.stderr)
        return EXIT_API

    if args.json:
        print(json.dumps(record, ensure_ascii=False, indent=2))
        return 0
    est = record.get("cost_estimate", {})
    if record["status"] == "dry-run":
        print("DRY RUN - request that would be sent to POST /images/generations:")
        print(json.dumps(redact_for_display(payload), ensure_ascii=False, indent=2))
        print(f"estimated cost: ¥{est.get('estimated_yuan')} ({est.get('note')})  cache key: {key}  output: {out}")
        return 0
    print(f"{record['status']}: {out}")
    if record.get("size"):
        print(f"reported size: {record['size']}")
    if record.get("usage"):
        print(f"usage: {json.dumps(record['usage'])}  actual cost estimate: ¥{record.get('actual_cost_estimate')}")
    print(f"sidecar: {out.with_name(out.name + '.json')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

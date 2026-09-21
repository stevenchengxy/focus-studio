#!/usr/bin/env python3
"""
generate_clip.py - generate one video clip with Volcengine Ark (火山方舟) Seedance.

Examples
--------
  # cheapest smoke test (≈0.2-0.3 元/s at 480p with the mini model)
  python3 generate_clip.py --prompt "abstract dark purple glass UI panels, slow push-in, no text" \
      --model doubao-seedance-2-0-mini-260615 --resolution 480p --ratio 16:9 --duration 5 \
      --out ai-clips/hero.mp4

  # image-to-video from a Seedream still (local files are embedded as data URLs)
  python3 generate_clip.py --prompt "camera slowly pushes in, soft light sweeps across" \
      --first-frame ai-clips/hero-bg.png --duration 5 --resolution 720p --out ai-clips/hero-i2v.mp4

  # inspect the request and the cost estimate without calling the API
  python3 generate_clip.py --prompt "..." --dry-run

Outputs: the MP4 at --out, a sidecar <out>.json (request, task id, usage, cost), and a
content-addressed cache entry in <out dir>/.cache so the same request is never billed twice.
The API key is read from $ARK_API_KEY or ~/.config/focus-studio/ark.env and never printed.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve()


def _find_shared() -> Path:
    env = os.environ.get("FOCUS_SKILLS_SHARED")
    candidates = ([Path(env)] if env else []) + [
        HERE.parents[1] / "_shared",            # <skill>/_shared (copied into the skill folder)
        HERE.parents[2] / "_shared",            # skills/_shared (sibling of the skill folder)
        Path.home() / ".claude" / "skills" / "_shared",
    ]
    for c in candidates:
        if (c / "ark_client.py").is_file():
            return c
    sys.exit("error: cannot find _shared/ark_client.py - copy the `_shared` folder next to this skill "
             "folder or set FOCUS_SKILLS_SHARED=/path/to/_shared")


sys.path.insert(0, str(_find_shared()))
from ark_client import (  # noqa: E402
    ArkAPIError, ArkClient, ArkConfigError, ArkError, ArkTaskError, ArkTimeoutError, DEFAULT_VIDEO_MODEL,
    VIDEO_MODELS, VIDEO_RATIOS, VIDEO_RESOLUTIONS, estimate_video_cost, resolve_image_ref, run_video_generation,
)

EXIT_USAGE, EXIT_CONFIG, EXIT_API, EXIT_TASK, EXIT_TIMEOUT = 2, 3, 4, 5, 6


def parse_args(argv=None) -> argparse.Namespace:
    ap = argparse.ArgumentParser(
        prog="generate_clip.py",
        description="Generate a video clip with Volcengine Ark Seedance (text-to-video or image-to-video).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Models: " + ", ".join(VIDEO_MODELS) + "\nExit codes: 0 ok, 2 usage, 3 key missing, 4 API error, 5 task failed, 6 timeout")
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--prompt", help="text prompt (Chinese or English). Keep on-screen text out of the prompt; captions are added by the composer.")
    src.add_argument("--prompt-file", help="read the prompt from a UTF-8 text file")
    ap.add_argument("--model", default=DEFAULT_VIDEO_MODEL, help=f"Seedance model id (default: {DEFAULT_VIDEO_MODEL})")
    ap.add_argument("--resolution", default="720p", choices=VIDEO_RESOLUTIONS + ["4k"], help="output resolution (default 720p)")
    ap.add_argument("--ratio", default="16:9", choices=VIDEO_RATIOS, help="aspect ratio; 'adaptive' follows the first frame image")
    ap.add_argument("--duration", type=int, default=5, help="seconds (Seedance 2.x: 4-15, 1.0: 2-12). Default 5")
    ap.add_argument("--first-frame", metavar="IMG", help="image path or URL used as the first frame (image-to-video)")
    ap.add_argument("--last-frame", metavar="IMG", help="image path or URL used as the last frame (needs --first-frame)")
    ap.add_argument("--reference", metavar="IMG", action="append", default=[], help="reference image (repeatable; Seedance 2.x). Mutually exclusive with first/last frame on most models")
    ap.add_argument("--out", help="output .mp4 path (default ai-clips/clip-<hash>.mp4)")
    ap.add_argument("--seed", type=int, help="seed for reproducibility (also part of the cache key)")
    ap.add_argument("--audio", action="store_true", help="ask the model to generate audio (Seedance 2.x). Off by default: BGM is mixed later")
    ap.add_argument("--camera-fixed", action="store_true", help="lock the camera (no camera motion)")
    ap.add_argument("--return-last-frame", action="store_true", help="also download the last frame (for chaining clips)")
    ap.add_argument("--watermark", action="store_true", help="keep the provider watermark (default off)")
    ap.add_argument("--extra", help="JSON object merged into the request body for parameters not covered here")
    ap.add_argument("--max-image-side", type=int, default=2048, help="downscale local images to this longest side before embedding (default 2048)")
    ap.add_argument("--cache-dir", help="cache directory (default <out dir>/.cache)")
    ap.add_argument("--force", action="store_true", help="ignore the cache and generate again (bills again)")
    ap.add_argument("--timeout", type=float, default=1800, help="max seconds to wait for the task (default 1800)")
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
    if not (1 <= args.duration <= 30):
        print("error: --duration must be between 1 and 30 seconds", file=sys.stderr)
        return EXIT_USAGE
    info = VIDEO_MODELS.get(args.model)
    if info is None:
        log(f"warning: {args.model} is not in the known model table; the API decides whether it exists")
    else:
        lo, hi = info["durations"]
        if not (lo <= args.duration <= hi):
            log(f"warning: {args.model} usually accepts {lo}-{hi} s; the API may reject {args.duration} s")
        if args.resolution not in info["resolutions"]:
            log(f"warning: {args.model} is documented for {info['resolutions']}; {args.resolution} may be rejected")
        if args.audio and not info.get("audio"):
            log(f"warning: {args.model} does not support generate_audio; the flag will be ignored")
    if args.last_frame and not args.first_frame:
        print("error: --last-frame requires --first-frame", file=sys.stderr)
        return EXIT_USAGE
    if args.reference and (args.first_frame or args.last_frame):
        log("warning: reference images and first/last frames are mutually exclusive on Seedance 2.x; the API may reject this")
    extra = None
    if args.extra:
        try:
            extra = json.loads(args.extra)
            assert isinstance(extra, dict)
        except Exception:
            print("error: --extra must be a JSON object", file=sys.stderr)
            return EXIT_USAGE

    try:
        images = []
        if args.first_frame:
            images.append({"url": resolve_image_ref(args.first_frame, max_side=args.max_image_side), "role": "first_frame"})
        if args.last_frame:
            images.append({"url": resolve_image_ref(args.last_frame, max_side=args.max_image_side), "role": "last_frame"})
        for ref in args.reference:
            images.append({"url": resolve_image_ref(ref, max_side=args.max_image_side), "role": "reference_image"})
        generate_audio = None
        if info is None or info.get("audio"):
            generate_audio = bool(args.audio)
        payload = ArkClient.build_video_payload(
            args.model, prompt, images=images, resolution=args.resolution, ratio=args.ratio, duration=args.duration,
            generate_audio=generate_audio, watermark=bool(args.watermark), seed=args.seed,
            camera_fixed=True if args.camera_fixed else None,
            return_last_frame=True if args.return_last_frame else None, extra=extra)
    except ArkError as e:
        print(f"error: {e}", file=sys.stderr)
        return EXIT_USAGE

    from ark_client import Cache, redact_for_display  # local import keeps the top tidy
    key = Cache.key_for("video", payload)
    out = Path(args.out) if args.out else Path("ai-clips") / f"clip-{key[:8]}.mp4"
    if out.suffix.lower() != ".mp4":
        log("warning: Seedance returns MP4; using the given path anyway")

    try:
        record = run_video_generation(payload, out, cache_dir=args.cache_dir, dry_run=args.dry_run, force=args.force,
                                      timeout=args.timeout, verbose=args.verbose, log=log)
    except ArkConfigError as e:
        print(f"error: {e}", file=sys.stderr)
        return EXIT_CONFIG
    except ArkTaskError as e:
        print(f"error: {e}", file=sys.stderr)
        return EXIT_TASK
    except ArkTimeoutError as e:
        print(f"error: {e}", file=sys.stderr)
        return EXIT_TIMEOUT
    except ArkAPIError as e:
        print(f"error: {e}", file=sys.stderr)
        if e.status == 400:
            print("hint: the API rejected a parameter - check model/resolution/ratio/duration and image roles above", file=sys.stderr)
        return EXIT_API
    except ArkError as e:
        print(f"error: {e}", file=sys.stderr)
        return EXIT_API

    if args.json:
        print(json.dumps(record, ensure_ascii=False, indent=2))
        return 0
    est = record.get("cost_estimate", {})
    status = record["status"]
    if status == "dry-run":
        print("DRY RUN - request that would be sent to POST /contents/generations/tasks:")
        print(json.dumps(redact_for_display(payload), ensure_ascii=False, indent=2))
        print(f"estimated tokens: {est.get('estimated_tokens')}  estimated cost: ¥{est.get('estimated_yuan')}  ({est.get('note')})")
        print(f"cache key: {key}  output: {out}")
        return 0
    print(f"{status}: {out}")
    if record.get("task_id"):
        print(f"task id: {record['task_id']}")
    if record.get("usage"):
        print(f"usage: {json.dumps(record['usage'])}  actual cost estimate: ¥{record.get('actual_cost_estimate')}")
    else:
        print(f"estimated cost: ¥{est.get('estimated_yuan')}")
    print(f"sidecar: {out.with_name(out.name + '.json')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

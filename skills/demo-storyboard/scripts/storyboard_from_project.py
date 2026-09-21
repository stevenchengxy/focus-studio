#!/usr/bin/env python3
"""
storyboard_from_project.py - draft a storyboard.json from a Focus Studio project.

Reads ``project.json`` (clickEvents / zoomSegments / duration / settings), clusters the
zoom segments into 3-6 chapters, and writes a draft storyboard with: an AI hero opener,
one ``demo`` segment per chapter (trimmed from the Focus Studio export) with caption
placeholders, and a closing CTA title card. Every chapter carries ``notes`` (zoom times
and targets) so the author - usually Claude - can replace the TODO captions with real copy.

  python3 storyboard_from_project.py --project ~/Library/Application\ Support/FocusStudio/Projects/<uuid> \
      --export ~/Movies/focus-demo.mp4 --product "Focus Studio, a macOS product-demo recorder" \
      --lang zh --out storyboard.json --thumbs thumbs/

Without --export the demo segments point at raw.mp4 (no zooms/cursor baked in) - replace
``source`` with the Focus Studio export before composing.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

EXIT_USAGE = 2


def load_project(path: Path) -> Tuple[Dict[str, Any], Path]:
    p = path.expanduser()
    if p.is_dir():
        p = p / "project.json"
    if not p.is_file():
        raise FileNotFoundError(f"project.json not found at {p}")
    with open(p, encoding="utf-8") as fh:
        return json.load(fh), p.parent


def ffprobe_duration(path: Path) -> Optional[float]:
    ffprobe = shutil.which("ffprobe") or "/usr/local/bin/ffprobe"
    if not Path(ffprobe).is_file():
        return None
    res = subprocess.run([ffprobe, "-v", "error", "-show_entries", "format=duration", "-of", "json", str(path)],
                         capture_output=True, text=True)
    try:
        return float(json.loads(res.stdout)["format"]["duration"])
    except Exception:
        return None


# ---------------------------------------------------------------------------
# Chapter clustering
# ---------------------------------------------------------------------------
def cluster_events(events: List[Tuple[float, float, Dict[str, Any]]], gap: float) -> List[List[Tuple[float, float, Dict[str, Any]]]]:
    clusters: List[List[Tuple[float, float, Dict[str, Any]]]] = []
    for ev in sorted(events, key=lambda e: e[0]):
        if clusters and ev[0] - clusters[-1][-1][1] <= gap:
            clusters[-1].append(ev)
        else:
            clusters.append([ev])
    return clusters


def fit_cluster_count(clusters: List[List[Any]], lo: int, hi: int) -> List[List[Any]]:
    clusters = [list(c) for c in clusters]
    # too many chapters: merge the pair with the smallest gap
    while len(clusters) > hi:
        gaps = [(clusters[i + 1][0][0] - clusters[i][-1][1], i) for i in range(len(clusters) - 1)]
        _, i = min(gaps)
        clusters[i] = clusters[i] + clusters[i + 1]
        del clusters[i + 1]
    # too few chapters: split the cluster with the largest internal gap
    while len(clusters) < lo:
        best = None
        for ci, c in enumerate(clusters):
            for j in range(len(c) - 1):
                g = c[j + 1][0] - c[j][1]
                if best is None or g > best[0]:
                    best = (g, ci, j)
        if best is None or best[0] <= 0.0:
            break
        _, ci, j = best
        c = clusters[ci]
        clusters[ci:ci + 1] = [c[:j + 1], c[j + 1:]]
    return clusters


def propose_chapters(project: Dict[str, Any], *, duration: float, min_ch: int, max_ch: int, gap: Optional[float],
                     lead: float, skip_head: float, trim_tail: float) -> List[Dict[str, Any]]:
    zooms = [z for z in project.get("zoomSegments", []) if z.get("isEnabled", True)]
    events: List[Tuple[float, float, Dict[str, Any]]] = []
    kind = "zoom"
    if zooms:
        events = [(float(z["start"]), float(z["end"]), z) for z in zooms]
    elif project.get("clickEvents"):
        kind = "click"
        events = [(float(c["time"]), float(c["time"]) + 1.0, c) for c in project["clickEvents"]]
    end_limit = max(0.5, duration - trim_tail)
    if not events:
        n = max(min_ch, 3)
        step = (end_limit - skip_head) / n
        return [{"index": i + 1, "start": round(skip_head + i * step, 3), "end": round(skip_head + (i + 1) * step, 3),
                 "events": [], "basis": "even split (no zooms/clicks recorded)"} for i in range(n)]
    if gap is None:
        gap = max(3.0, min(8.0, duration / 8.0))
    clusters = fit_cluster_count(cluster_events(events, gap), min_ch, max_ch)
    chapters: List[Dict[str, Any]] = []
    prev_end = skip_head
    for i, c in enumerate(clusters):
        first_start, last_end = c[0][0], c[-1][1]
        if i + 1 < len(clusters):
            next_start = clusters[i + 1][0][0]
            cut = min(next_start - lead, (last_end + next_start) / 2.0)
            cut = max(cut, last_end + 0.2)
            cut = min(cut, next_start)
        else:
            cut = end_limit
        start = prev_end if i > 0 else min(prev_end, max(0.0, first_start - lead)) if first_start - lead < prev_end else prev_end
        chapters.append({
            "index": i + 1, "start": round(max(0.0, start), 3), "end": round(cut, 3), "basis": kind,
            "events": [{"time": round(s, 2), "end": round(e, 2), "x": round(float(ev.get("targetX", ev.get("x", 0))), 3),
                        "y": round(float(ev.get("targetY", ev.get("y", 0))), 3), "scale": ev.get("scale"),
                        "kind": ev.get("kind", kind)} for s, e, ev in c],
        })
        prev_end = cut
    # drop degenerate chapters (< 1.5 s)
    return [ch for ch in chapters if ch["end"] - ch["start"] >= 1.5]


# ---------------------------------------------------------------------------
# Storyboard assembly
# ---------------------------------------------------------------------------
def hex_ok(c: Optional[str]) -> str:
    return c if c and re.fullmatch(r"#[0-9A-Fa-f]{6}", c) else "#0B0A1F"


def build_storyboard(project: Dict[str, Any], chapters: List[Dict[str, Any]], *, source: str, product: str, title: str,
                     lang: str, width: int, fps: int, hero: bool, cta: bool, bgm: Optional[str], video_model: str,
                     image_model: str, brand: str) -> Dict[str, Any]:
    zh = lang == "zh"
    height = round(width * 9 / 16 / 2) * 2
    accent = brand
    segments: List[Dict[str, Any]] = []
    if hero:
        segments.append({
            "id": "hero", "type": "ai_clip", "duration": 5,
            "prompt": (f"Cinematic abstract hero shot for {product}: layered frosted glass UI panels floating in a deep "
                       f"{brand} gradient space, soft volumetric light, slow camera push-in, subtle particles, premium enterprise "
                       "software mood, photorealistic 3D render. No text, no letters, no logos, no people."),
            "model": video_model, "resolution": "720p", "ratio": "16:9", "seed": 20260921,
            "asset": "assets/hero.mp4",
            "title": {"text": title, "subtitle": ("产品演示" if zh else "Product demo"), "start": 0.6},
            "transition": {"type": "fade", "duration": 0.6},
            "notes": "Opener. Replace subtitle with the one-line value proposition. Generate with --generate or drop any 16:9 clip at assets/hero.mp4.",
        })
    for ch in chapters:
        i = ch["index"]
        ev = ch["events"]
        ev_txt = "; ".join(f"{e['kind']} @{e['time']}s (x={e['x']}, y={e['y']})" for e in ev) or ch.get("basis", "")
        segments.append({
            "id": f"chapter-{i:02d}", "type": "demo", "source": source,
            "trim": {"start": ch["start"], "end": ch["end"]},
            "caption": {"kicker": f"{i:02d}", "text": (f"TODO: 用一句话说明第 {i} 步做了什么" if zh else f"TODO: one line describing step {i}"),
                        "position": "bottom", "start": 0.4},
            "audio": True,
            "transition": {"type": "fade" if i == 1 else "slideleft", "duration": 0.5},
            "notes": f"{ch['end'] - ch['start']:.1f}s from the recording, {ch['start']}-{ch['end']}s. Interactions: {ev_txt}. "
                     "Write the caption from what happens on screen (check the thumbnail).",
        })
    if cta:
        segments.append({
            "id": "cta", "type": "title", "duration": 4, "background": hex_ok(project.get("settings", {}).get("backgroundColor")),
            "title": {"text": ("立即体验" if zh else "Get started today"), "subtitle": ("TODO: 网址 / 二维码文案 / 版本号" if zh else "TODO: URL / call to action / version")},
            "transition": {"type": "fade", "duration": 0.8},
            "notes": "Closing CTA. Swap for a `still` segment (Seedream title card) if you want an image background.",
        })
    sb: Dict[str, Any] = {
        "version": 1,
        "title": title,
        "language": lang,
        "product": product,
        "output": {"path": "final.mp4", "width": width, "height": height, "fps": fps,
                   "background": hex_ok(project.get("settings", {}).get("backgroundColor")), "font": None,
                   "codec": "libx264", "crf": 18, "preset": "medium", "fade_in": 0.4, "fade_out": 0.8},
        "style": {"accent": accent,
                  "title": {"size": 96, "subtitle_size": 40, "color": "#FFFFFF", "subtitle_color": "#D6D2FF"},
                  "caption": {"size": 44, "color": "#FFFFFF", "box": True, "box_color": "#000000@0.45", "margin": 96,
                              "kicker_size": 26, "kicker_color": accent},
                  "text_fade": 0.35},
        "audio": {"bgm": ({"path": bgm, "volume": 0.18, "fade_in": 1.5, "fade_out": 2.0, "loop": True,
                           "duck": {"mode": "sidechain", "level": 0.3, "threshold": 0.02, "ratio": 8, "attack": 30, "release": 600}}
                          if bgm else None),
                  "loudnorm": False, "master_volume": 1.0},
        "generation": {"enabled": False, "assets_dir": "assets",
                       "video": {"model": video_model, "resolution": "720p", "ratio": "16:9", "generate_audio": False},
                       "image": {"model": image_model, "size": "2K"}},
        "segments": segments,
        "source_project": {"title": project.get("title"), "duration": project.get("duration"),
                           "sourceWidth": project.get("sourceWidth"), "sourceHeight": project.get("sourceHeight"),
                           "frameRate": project.get("settings", {}).get("frameRate"),
                           "exportWidth": project.get("settings", {}).get("exportWidth"),
                           "zoomSegments": len(project.get("zoomSegments", [])), "clickEvents": len(project.get("clickEvents", []))},
    }
    return sb


def extract_thumbs(video: Path, chapters: List[Dict[str, Any]], out_dir: Path) -> List[str]:
    ffmpeg = shutil.which("ffmpeg") or "/usr/local/bin/ffmpeg"
    out_dir.mkdir(parents=True, exist_ok=True)
    written = []
    for ch in chapters:
        t = ch["events"][0]["time"] + 0.3 if ch["events"] else (ch["start"] + ch["end"]) / 2
        t = min(max(t, ch["start"]), max(ch["start"], ch["end"] - 0.1))
        dest = out_dir / f"chapter-{ch['index']:02d}.jpg"
        cmd = [ffmpeg, "-y", "-hide_banner", "-loglevel", "error", "-ss", f"{t:.3f}", "-i", str(video),
               "-frames:v", "1", "-vf", "scale=960:-2", "-q:v", "3", str(dest)]
        if subprocess.run(cmd).returncode == 0:
            written.append(str(dest))
            ch["thumbnail"] = str(dest)
    return written


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Draft a storyboard.json from a Focus Studio project.json (or just an exported mp4).",
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--project", help="project directory or project.json")
    ap.add_argument("--export", help="Focus Studio exported mp4 (used as the demo `source`; its duration wins)")
    ap.add_argument("--product", default="the product", help="one-line product description used in prompts")
    ap.add_argument("--title", help="video title (default: project title)")
    ap.add_argument("--lang", default="zh", choices=["zh", "en"], help="caption placeholder language")
    ap.add_argument("--min-chapters", type=int, default=3)
    ap.add_argument("--max-chapters", type=int, default=6)
    ap.add_argument("--gap", type=float, help="seconds of inactivity that separate chapters (default: adaptive 3-8 s)")
    ap.add_argument("--lead", type=float, default=1.0, help="seconds of context before a chapter's first interaction (default 1.0)")
    ap.add_argument("--skip-head", type=float, default=0.0, help="seconds to skip at the start of the recording")
    ap.add_argument("--trim-tail", type=float, default=0.0, help="seconds to drop at the end of the recording")
    ap.add_argument("--width", type=int, default=1920, choices=[1280, 1920, 2560, 3840])
    ap.add_argument("--fps", type=int, default=30, choices=[24, 30, 60])
    ap.add_argument("--no-hero", action="store_true", help="do not add the AI hero opener")
    ap.add_argument("--no-cta", action="store_true", help="do not add the closing CTA title card")
    ap.add_argument("--bgm", help="background music file to reference in the storyboard")
    ap.add_argument("--video-model", default="doubao-seedance-2-0-mini-260615")
    ap.add_argument("--image-model", default="doubao-seedream-4-5-251128")
    ap.add_argument("--brand-color", help="hex accent color (default: project backgroundColor)")
    ap.add_argument("--thumbs", help="directory: write one JPEG per chapter so the author can look at each step")
    ap.add_argument("--out", default="storyboard.json")
    args = ap.parse_args(argv)

    if not args.project and not args.export:
        print("error: give --project and/or --export", file=sys.stderr)
        return EXIT_USAGE
    if args.min_chapters < 1 or args.max_chapters < args.min_chapters:
        print("error: need 1 <= --min-chapters <= --max-chapters", file=sys.stderr)
        return EXIT_USAGE

    project: Dict[str, Any] = {}
    project_dir: Optional[Path] = None
    if args.project:
        try:
            project, project_dir = load_project(Path(args.project))
        except (OSError, ValueError) as e:
            print(f"error: {e}", file=sys.stderr)
            return EXIT_USAGE
    export = Path(args.export).expanduser() if args.export else None
    if export and not export.is_file():
        print(f"error: export not found: {export}", file=sys.stderr)
        return EXIT_USAGE
    duration = float(project.get("duration") or 0.0)
    if export:
        d = ffprobe_duration(export)
        if d:
            if duration and abs(d - duration) > 0.75:
                print(f"note: export is {d:.2f}s but project.json says {duration:.2f}s; using the export", file=sys.stderr)
            duration = d
    if duration <= 0:
        print("error: could not determine the recording duration", file=sys.stderr)
        return EXIT_USAGE

    chapters = propose_chapters(project, duration=duration, min_ch=args.min_chapters, max_ch=args.max_chapters,
                                gap=args.gap, lead=args.lead, skip_head=args.skip_head, trim_tail=args.trim_tail)
    if export:
        source = str(export)
    elif project_dir is not None:
        source = str(project_dir / (project.get("sourceVideoPath") or "raw.mp4"))
        print("note: no --export given; demo segments point at raw.mp4 (no zooms/cursor). Export from Focus Studio and set `source`.", file=sys.stderr)
    else:
        source = "REPLACE_WITH_EXPORT.mp4"

    brand = args.brand_color or project.get("settings", {}).get("backgroundColor") or "#6D5DFB"
    if not re.fullmatch(r"#[0-9A-Fa-f]{6}", brand):
        brand = "#6D5DFB"
    title = args.title or project.get("title") or Path(source).stem
    sb = build_storyboard(project, chapters, source=source, product=args.product, title=title, lang=args.lang,
                          width=args.width, fps=args.fps, hero=not args.no_hero, cta=not args.no_cta, bgm=args.bgm,
                          video_model=args.video_model, image_model=args.image_model, brand=brand)
    if args.thumbs:
        video_for_thumbs = export or (project_dir / (project.get("sourceVideoPath") or "raw.mp4") if project_dir else None)
        if video_for_thumbs and Path(video_for_thumbs).is_file():
            thumbs = extract_thumbs(Path(video_for_thumbs), chapters, Path(args.thumbs))
            for seg, ch in zip([s for s in sb["segments"] if s["type"] == "demo"], chapters):
                if ch.get("thumbnail"):
                    seg["thumbnail"] = ch["thumbnail"]
            print(f"wrote {len(thumbs)} thumbnails to {args.thumbs}", file=sys.stderr)
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(sb, ensure_ascii=False, indent=2), encoding="utf-8")

    total = sum((s.get("duration") or (s["trim"]["end"] - s["trim"]["start"])) for s in sb["segments"])
    print(f"storyboard: {out}  ({len(sb['segments'])} segments, ~{total:.1f}s before transitions)")
    print(f"{'id':<12}{'type':<9}{'start':>8}{'end':>8}{'len':>7}  notes")
    for s in sb["segments"]:
        if s["type"] == "demo":
            st, en = s["trim"]["start"], s["trim"]["end"]
            print(f"{s['id']:<12}{s['type']:<9}{st:>8.2f}{en:>8.2f}{en - st:>7.2f}  {s['notes'][:70]}")
        else:
            print(f"{s['id']:<12}{s['type']:<9}{'':>8}{'':>8}{s.get('duration', 0):>7.2f}  {s.get('notes', '')[:70]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

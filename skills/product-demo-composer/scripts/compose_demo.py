#!/usr/bin/env python3
"""
compose_demo.py - render a storyboard.json into a finished product-demo MP4 with ffmpeg.

Pipeline
  1. resolve every segment (demo export / AI clip / still / title card); optionally generate
     missing AI assets through the shared Ark client (only with --generate) or use placeholders
  2. normalise each segment to the output size / fps / yuv420p, burn title + caption overlays
     (drawtext, CJK-capable font lookup) into an intermediate .mov (h264 + PCM audio)
  3. join the intermediates with xfade / acrossfade transitions (cuts use concat)
  4. mix background music with fade in/out and ducking under the program audio
  5. write <output>.mp4 + render-report.json

  python3 compose_demo.py storyboard.json                 # placeholders for missing AI assets, no spend
  python3 compose_demo.py storyboard.json --generate      # generate missing ai_clip/still assets (bills the Ark account)
  python3 compose_demo.py storyboard.json --dry-run       # print the plan, costs and ffmpeg commands only
  python3 compose_demo.py storyboard.json --preview       # fast 720p check render

See ../SKILL.md and ../../demo-storyboard/references/storyboard-schema.md for the schema.
"""
from __future__ import annotations

import argparse
import datetime as _dt
import glob
import json
import math
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

HERE = Path(__file__).resolve()
sys.path.insert(0, str(HERE.parent))
from probe_media import find_ffmpeg, probe  # noqa: E402


def _find_shared() -> Optional[Path]:
    env = os.environ.get("FOCUS_SKILLS_SHARED")
    for c in ([Path(env)] if env else []) + [HERE.parents[1] / "_shared", HERE.parents[2] / "_shared",
                                              Path.home() / ".claude" / "skills" / "_shared"]:
        if (c / "ark_client.py").is_file():
            return c
    return None


SHARED = _find_shared()

EXIT_USAGE, EXIT_CONFIG, EXIT_API, EXIT_FFMPEG = 2, 3, 4, 7
SEGMENT_TYPES = ("demo", "ai_clip", "still", "title")
XFADE_TRANSITIONS = set((
    "fade wipeleft wiperight wipeup wipedown slideleft slideright slideup slidedown circlecrop rectcrop distance "
    "fadeblack fadewhite radial smoothleft smoothright smoothup smoothdown circleopen circleclose vertopen vertclose "
    "horzopen horzclose dissolve pixelize diagtl diagtr diagbl diagbr hlslice hrslice vuslice vdslice hblur fadegrays "
    "wipetl wipetr wipebl wipebr squeezeh squeezev zoomin fadefast fadeslow hlwind hrwind vuwind vdwind coverleft "
    "coverright coverup coverdown revealleft revealright revealup revealdown").split())
MOTIONS = ("zoom_in", "zoom_out", "pan_left", "pan_right", "none")

FONT_CANDIDATES = [
    "/System/Library/Fonts/PingFang.ttc",
    "/System/Library/Fonts/Hiragino Sans GB.ttc",
    "/System/Library/Fonts/STHeiti Medium.ttc",
    "/System/Library/Fonts/Supplemental/Songti.ttc",
    "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
    "/Library/Fonts/Arial Unicode.ttf",
    "/System/Library/Fonts/Helvetica.ttc",
    "/System/Library/Fonts/HelveticaNeue.ttc",
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/truetype/wqy/wqy-microhei.ttc",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
]

DEFAULT_STYLE = {
    "accent": "#8B7CFF",
    "title": {"size": 96, "subtitle_size": 40, "color": "#FFFFFF", "subtitle_color": "#D6D2FF", "gap": 28},
    "caption": {"size": 44, "color": "#FFFFFF", "box": True, "box_color": "#000000@0.45", "margin": 96,
                "kicker_size": 26, "kicker_color": "#0B0A1F", "box_border": 18},
    "text_fade": 0.35,
    "placeholder_label_size": 24,
}


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def die(msg: str, code: int = 1) -> None:
    print(f"error: {msg}", file=sys.stderr, flush=True)
    sys.exit(code)


# ---------------------------------------------------------------------------
# ffmpeg string helpers
# ---------------------------------------------------------------------------
def esc_opt(value: str) -> str:
    """Two-level escaping for a value inside a -filter_complex option (paths, expressions)."""
    lvl1 = value.replace("\\", "\\\\").replace("'", "\\'").replace(":", "\\:")
    return re.sub(r"([\\'\[\],;])", r"\\\1", lvl1)


def color_ff(color: Optional[str], default: str = "#000000") -> str:
    """'#RRGGBB[@alpha]' or named colour -> ffmpeg colour string."""
    c = (color or default).strip()
    m = re.fullmatch(r"#([0-9A-Fa-f]{6})(@[0-9.]+)?", c)
    if m:
        return f"0x{m.group(1).upper()}{m.group(2) or ''}"
    return c


def hex_rgb(color: str) -> Tuple[int, int, int]:
    m = re.fullmatch(r"#([0-9A-Fa-f]{6})", color.strip())
    if not m:
        return (11, 10, 31)
    v = int(m.group(1), 16)
    return ((v >> 16) & 255, (v >> 8) & 255, v & 255)


def rgb_hex(r: float, g: float, b: float) -> str:
    return "#{:02X}{:02X}{:02X}".format(*(int(max(0, min(255, round(x)))) for x in (r, g, b)))


def shade(color: str, factor: float) -> str:
    """factor < 1 darkens, > 1 lightens towards white."""
    r, g, b = hex_rgb(color)
    if factor <= 1:
        return rgb_hex(r * factor, g * factor, b * factor)
    f = factor - 1
    return rgb_hex(r + (255 - r) * f, g + (255 - g) * f, b + (255 - b) * f)


def fade_alpha(start: float, end: float, fade: float) -> str:
    s, e, f = f"{start:.3f}", f"{end:.3f}", f"{max(fade, 0.01):.3f}"
    return f"if(lt(t,{s}),0,if(lt(t,{s}+{f}),(t-{s})/{f},if(lt(t,{e}-{f}),1,if(lt(t,{e}),({e}-t)/{f},0))))"


def find_font(preferred: Optional[str]) -> str:
    cands: List[str] = []
    if preferred:
        cands.append(str(Path(preferred).expanduser()))
    if os.environ.get("FOCUS_DEMO_FONT"):
        cands.append(os.environ["FOCUS_DEMO_FONT"])
    cands += sorted(glob.glob("/System/Library/AssetsV2/com_apple_MobileAsset_Font*/*/AssetData/PingFang.ttc"))
    cands += FONT_CANDIDATES
    for c in cands:
        if c and Path(c).is_file():
            return c
    die("no usable font found; pass --font /path/to/font.ttf (needs CJK glyphs for Chinese captions)", EXIT_USAGE)
    return ""


def shell_join(cmd: List[str]) -> str:
    return " ".join(shlex.quote(c) for c in cmd)


# ---------------------------------------------------------------------------
# Storyboard model
# ---------------------------------------------------------------------------
class Ctx:
    def __init__(self, sb: Dict[str, Any], sb_path: Path, args: argparse.Namespace):
        self.sb = sb
        self.base = sb_path.parent.resolve()
        out = sb.get("output", {}) or {}
        self.width = int(args.width or out.get("width", 1920))
        self.height = int(args.height or out.get("height", round(self.width * 9 / 16)))
        self.fps = int(args.fps or out.get("fps", 30))
        if args.preview:
            self.width, self.height, self.fps = 1280, 720, min(self.fps, 30)
        if self.width % 2 or self.height % 2:
            die("output width/height must be even", EXIT_USAGE)
        self.bg = out.get("background") or "#0B0A1F"
        self.codec = out.get("codec", "libx264")
        self.crf = int(out.get("crf", 18)) if not args.preview else 28
        self.preset = str(out.get("preset", "medium")) if not args.preview else "ultrafast"
        self.fade_in = float(out.get("fade_in", 0) or 0)
        self.fade_out = float(out.get("fade_out", 0) or 0)
        self.logo = out.get("logo")
        self.out_path = Path(args.out).expanduser() if args.out else (self.base / (out.get("path") or "final.mp4"))
        if args.preview and not args.out:
            self.out_path = self.out_path.with_name(self.out_path.stem + "-preview.mp4")
        self.style = json.loads(json.dumps(DEFAULT_STYLE))
        for k, v in (sb.get("style") or {}).items():
            if isinstance(v, dict) and isinstance(self.style.get(k), dict):
                self.style[k].update(v)
            else:
                self.style[k] = v
        self.font = find_font(args.font or out.get("font"))
        gen = sb.get("generation") or {}
        self.generate = bool(args.generate)
        self.force_generate = bool(args.force_generate)
        self.assets_dir = self.resolve(gen.get("assets_dir") or "assets")
        self.gen_video = dict(gen.get("video") or {})
        self.gen_image = dict(gen.get("image") or {})
        self.dry_run = bool(args.dry_run)
        self.verbose = bool(args.verbose)
        self.preview = bool(args.preview)
        self.ffmpeg = find_ffmpeg()
        self.commands: List[str] = []
        self.scale = self.height / 1080.0
        self.text_counter = 0
        self.work = Path(args.work_dir).expanduser() if args.work_dir else Path(tempfile.mkdtemp(prefix="compose-demo-"))
        self.work.mkdir(parents=True, exist_ok=True)

    def resolve(self, p: str) -> Path:
        path = Path(p).expanduser()
        return path if path.is_absolute() else (self.base / path)

    def text_file(self, text: str) -> Path:
        self.text_counter += 1
        f = self.work / f"text-{self.text_counter:03d}.txt"
        f.write_text(text, encoding="utf-8")
        return f

    def run(self, cmd: List[str], what: str) -> None:
        self.commands.append(shell_join(cmd))
        if self.dry_run:
            return
        if self.verbose:
            log(f"[ffmpeg] {what}: {shell_join(cmd)}")
        res = subprocess.run(cmd, capture_output=True, text=True)
        if res.returncode != 0:
            tail = "\n".join(res.stderr.strip().splitlines()[-12:])
            die(f"ffmpeg failed while {what}:\n{tail}\ncommand: {shell_join(cmd)}", EXIT_FFMPEG)


def load_storyboard(path: Path) -> Dict[str, Any]:
    try:
        sb = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        die(f"cannot read storyboard {path}: {e}", EXIT_USAGE)
    if not isinstance(sb, dict) or not isinstance(sb.get("segments"), list) or not sb["segments"]:
        die("storyboard must be an object with a non-empty `segments` list", EXIT_USAGE)
    seen = set()
    for i, seg in enumerate(sb["segments"]):
        if not isinstance(seg, dict):
            die(f"segment #{i} is not an object", EXIT_USAGE)
        seg.setdefault("id", f"seg-{i + 1:02d}")
        if seg["id"] in seen:
            die(f"duplicate segment id {seg['id']!r}", EXIT_USAGE)
        seen.add(seg["id"])
        if seg.get("type") not in SEGMENT_TYPES:
            die(f"segment {seg['id']}: type must be one of {SEGMENT_TYPES}", EXIT_USAGE)
        tr = seg.get("transition")
        if tr is not None:
            if not isinstance(tr, dict):
                die(f"segment {seg['id']}: transition must be an object {{type, duration}}", EXIT_USAGE)
            t = tr.get("type", "fade")
            if t != "cut" and t not in XFADE_TRANSITIONS:
                die(f"segment {seg['id']}: unknown transition {t!r} (xfade names or 'cut')", EXIT_USAGE)
        if seg["type"] == "still" and seg.get("motion", "zoom_in") not in MOTIONS:
            die(f"segment {seg['id']}: motion must be one of {MOTIONS}", EXIT_USAGE)
    return sb


# ---------------------------------------------------------------------------
# Asset generation / placeholders
# ---------------------------------------------------------------------------
def default_asset(ctx: Ctx, seg: Dict[str, Any]) -> Path:
    ext = ".mp4" if seg["type"] == "ai_clip" else ".png"
    return ctx.resolve(seg["asset"]) if seg.get("asset") else ctx.assets_dir / f"{seg['id']}{ext}"


def generate_asset(ctx: Ctx, seg: Dict[str, Any], dest: Path) -> Dict[str, Any]:
    """Generate a missing ai_clip/still via the shared Ark client (cache-aware)."""
    if SHARED is None:
        die("cannot generate: _shared/ark_client.py not found next to the skills", EXIT_CONFIG)
    sys.path.insert(0, str(SHARED))
    import ark_client as ark  # type: ignore
    prompt = seg.get("prompt")
    if not prompt:
        die(f"segment {seg['id']}: needs a `prompt` to generate {dest.name}", EXIT_USAGE)
    cache_dir = ctx.assets_dir / ".cache"
    try:
        if seg["type"] == "ai_clip":
            images = []
            for role, key in (("first_frame", "first_frame"), ("last_frame", "last_frame")):
                if seg.get(key):
                    images.append({"url": ark.resolve_image_ref(str(ctx.resolve(seg[key]))), "role": role})
            for ref in seg.get("reference") or []:
                images.append({"url": ark.resolve_image_ref(str(ctx.resolve(ref))), "role": "reference_image"})
            model = seg.get("model") or ctx.gen_video.get("model") or ark.DEFAULT_VIDEO_MODEL
            gen_audio = seg.get("generate_audio", ctx.gen_video.get("generate_audio", False))
            payload = ark.ArkClient.build_video_payload(
                model, prompt, images=images,
                resolution=seg.get("resolution") or ctx.gen_video.get("resolution", "720p"),
                ratio=seg.get("ratio") or ctx.gen_video.get("ratio", "16:9"),
                duration=int(seg.get("duration") or ctx.gen_video.get("duration", 5)),
                generate_audio=bool(gen_audio) if ark.VIDEO_MODELS.get(model, {}).get("audio", True) else None,
                watermark=False, seed=seg.get("seed"), camera_fixed=seg.get("camera_fixed"),
                extra=seg.get("extra"))
            return ark.run_video_generation(payload, dest, cache_dir=cache_dir, dry_run=ctx.dry_run,
                                            force=ctx.force_generate, verbose=ctx.verbose, log=log)
        model = seg.get("model") or ctx.gen_image.get("model") or ark.DEFAULT_IMAGE_MODEL
        refs = [ark.resolve_image_ref(str(ctx.resolve(r))) for r in (seg.get("reference") or [])]
        size = seg.get("size") or ctx.gen_image.get("size", "2K")
        ratio = seg.get("ratio") or ctx.gen_image.get("ratio")
        if re.fullmatch(r"[124]K", str(size).upper()) and ratio:
            table = {"1K": {"16:9": "1280x720", "9:16": "720x1280", "1:1": "1024x1024"},
                     "2K": {"16:9": "2560x1440", "9:16": "1440x2560", "1:1": "2048x2048"},
                     "4K": {"16:9": "4096x2304", "9:16": "2304x4096", "1:1": "4096x4096"}}
            size = table[str(size).upper()].get(ratio, size)
        payload = ark.ArkClient.build_image_payload(model, prompt, images=refs, size=str(size), watermark=False,
                                                    seed=seg.get("seed"), extra=seg.get("extra"))
        return ark.run_image_generation(payload, dest, cache_dir=cache_dir, dry_run=ctx.dry_run,
                                        force=ctx.force_generate, verbose=ctx.verbose, log=log)
    except ark.ArkConfigError as e:
        die(str(e), EXIT_CONFIG)
    except ark.ArkError as e:
        die(f"generation failed for segment {seg['id']}: {e}", EXIT_API)
    return {}


def ensure_assets(ctx: Ctx, report: Dict[str, Any]) -> None:
    """Decide, per ai_clip/still segment, whether to use an existing asset, generate it, or fall back to a placeholder."""
    for seg in ctx.sb["segments"]:
        if seg["type"] not in ("ai_clip", "still"):
            continue
        dest = default_asset(ctx, seg)
        seg["_asset"] = dest
        entry = {"id": seg["id"], "asset": str(dest)}
        if dest.is_file() and not ctx.force_generate:
            entry["status"] = "existing"
        elif ctx.generate:
            rec = generate_asset(ctx, seg, dest)
            entry.update(status=rec.get("status"), task_id=rec.get("task_id"), usage=rec.get("usage"),
                         cost_estimate=rec.get("cost_estimate"), actual_cost_estimate=rec.get("actual_cost_estimate"))
            if rec.get("status") == "dry-run":
                seg["_placeholder"] = True
        else:
            entry["status"] = "placeholder"
            seg["_placeholder"] = True
            log(f"[plan] {seg['id']}: {dest.name} missing -> placeholder (run with --generate to create it)")
        report["assets"].append(entry)


# ---------------------------------------------------------------------------
# Text overlays
# ---------------------------------------------------------------------------
def drawtext(ctx: Ctx, text: str, *, size: float, color: str, x: str, y: str, start: float, end: float,
             box: bool = False, box_color: str = "#000000@0.45", border: float = 0, line_spacing: float = 0,
             shadow: bool = True, fade: Optional[float] = None) -> str:
    tf = ctx.text_file(text)
    fade = ctx.style["text_fade"] if fade is None else fade
    fade = min(fade, max(0.01, (end - start) / 2.0))
    parts = [f"fontfile='{esc_opt(ctx.font)}'", f"textfile='{esc_opt(str(tf))}'", "expansion=none",
             f"fontsize={int(round(size))}", f"fontcolor={color_ff(color, '#FFFFFF')}", f"x={x}", f"y={y}",
             f"line_spacing={int(round(line_spacing))}"]
    if shadow:
        parts += ["shadowcolor=0x000000@0.55", f"shadowx={max(1, int(round(2 * ctx.scale)))}", f"shadowy={max(1, int(round(2 * ctx.scale)))}"]
    if box:
        parts += ["box=1", f"boxcolor={color_ff(box_color)}", f"boxborderw={int(round(border))}"]
    parts.append(f"alpha='{fade_alpha(start, end, fade)}'")
    parts.append(f"enable='between(t,{start:.3f},{end:.3f})'")
    return "drawtext=" + ":".join(parts)


def overlay_filters(ctx: Ctx, seg: Dict[str, Any], dur: float) -> List[str]:
    st = ctx.style
    sc = ctx.scale
    out: List[str] = []
    title = seg.get("title")
    if isinstance(title, dict) and title.get("text"):
        ts = st["title"]
        start = float(title.get("start", 0.0))
        end = float(title.get("end", dur))
        size = float(title.get("size", ts["size"])) * sc
        sub = title.get("subtitle")
        align = title.get("align", "center")
        if align == "left":
            x_main = f"{int(120 * sc)}"
        else:
            x_main = "(w-text_w)/2"
        if sub:
            sub_size = float(title.get("subtitle_size", ts["subtitle_size"])) * sc
            gap = float(ts.get("gap", 28)) * sc
            y_main = f"h/2-text_h-{gap / 2:.0f}"
            y_sub = f"h/2+{gap / 2:.0f}"
            out.append(drawtext(ctx, str(title["text"]), size=size, color=title.get("color", ts["color"]), x=x_main,
                                y=y_main, start=start, end=end))
            out.append(drawtext(ctx, str(sub), size=sub_size, color=title.get("subtitle_color", ts["subtitle_color"]),
                                x=x_main, y=y_sub, start=min(end, start + 0.25), end=end))
        else:
            out.append(drawtext(ctx, str(title["text"]), size=size, color=title.get("color", ts["color"]), x=x_main,
                                y="(h-text_h)/2", start=start, end=end))
    cap = seg.get("caption")
    if isinstance(cap, dict) and cap.get("text"):
        cs = st["caption"]
        start = float(cap.get("start", 0.0))
        end = float(cap.get("end", dur))
        size = float(cap.get("size", cs["size"])) * sc
        margin = float(cap.get("margin", cs["margin"])) * sc
        border = float(cs.get("box_border", 18)) * sc
        lines = str(cap["text"]).count("\n") + 1
        block_h = size * 1.25 * lines
        kicker = cap.get("kicker")
        position = cap.get("position", "bottom")
        if position == "top":
            y_cap = f"{margin + (cs['kicker_size'] * sc * 1.7 if kicker else 0):.0f}"
            y_kick = f"{margin:.0f}"
        else:
            y_cap = f"h-text_h-{margin:.0f}"
            y_kick = f"h-{margin + block_h + border + cs['kicker_size'] * sc * 1.1:.0f}-text_h"
        x = "(w-text_w)/2" if cap.get("align", "center") == "center" else f"{int(120 * sc)}"
        if kicker:
            # accent "chip": dark text on an accent-coloured box so chapter numbers read at a glance
            chip_bg = cap.get("kicker_box_color", st.get("accent", "#8B7CFF"))
            out.append(drawtext(ctx, str(kicker), size=float(cs["kicker_size"]) * sc, color=cap.get("kicker_color", "#0B0A1F"),
                                x=x, y=y_kick, start=start, end=end, shadow=False, box=True, box_color=chip_bg,
                                border=max(4.0, 8 * sc)))
        out.append(drawtext(ctx, str(cap["text"]), size=size, color=cap.get("color", cs["color"]), x=x, y=y_cap,
                            start=start, end=end, box=bool(cap.get("box", cs["box"])), box_color=cap.get("box_color", cs["box_color"]),
                            border=border, line_spacing=size * 0.25))
    if seg.get("_placeholder"):
        label = f"AI placeholder · {seg['id']} · " + (seg.get("prompt") or "")[:70]
        out.append(drawtext(ctx, label, size=st["placeholder_label_size"] * sc, color="#FFFFFF@0.7",
                            x=f"{int(40 * sc)}", y=f"{int(40 * sc)}", start=0, end=dur, fade=0.01, shadow=False))
    return out


# ---------------------------------------------------------------------------
# Segment rendering (intermediates)
# ---------------------------------------------------------------------------
def gradient_source(ctx: Ctx, base: str, dur: float, seed: int = 7) -> str:
    c0, c1, c2 = shade(base, 1.18), base, shade(base, 0.35)
    W, H = ctx.width, ctx.height
    return (f"gradients=s={W}x{H}:r={ctx.fps}:d={dur:.3f}:c0={color_ff(c0)}:c1={color_ff(c1)}:c2={color_ff(c2)}:n=3:"
            f"x0={int(W * 0.15)}:y0={int(H * 0.1)}:x1={int(W * 0.9)}:y1={int(H * 0.95)}:speed=0.006:type=linear:seed={seed}")


def fit_chain(ctx: Ctx, fit: str) -> str:
    W, H = ctx.width, ctx.height
    if fit == "cover":
        return f"scale={W}:{H}:force_original_aspect_ratio=increase:flags=lanczos,crop={W}:{H},setsar=1"
    return (f"scale={W}:{H}:force_original_aspect_ratio=decrease:flags=lanczos,"
            f"pad={W}:{H}:(ow-iw)/2:(oh-ih)/2:color={color_ff(ctx.bg)},setsar=1")


def plan_segment(ctx: Ctx, seg: Dict[str, Any]) -> Dict[str, Any]:
    """Resolve input file, trim and planned duration for one segment."""
    t = seg["type"]
    plan: Dict[str, Any] = {"id": seg["id"], "type": t, "audio": bool(seg.get("audio", t == "demo")), "fit": seg.get("fit")}
    if t == "demo":
        src = ctx.resolve(seg.get("source") or "")
        if not seg.get("source") or not src.is_file():
            die(f"segment {seg['id']}: demo `source` not found: {src}", EXIT_USAGE)
        info = probe(src)
        speed = float(seg.get("speed", 1.0) or 1.0)
        if not (0.5 <= speed <= 4.0):
            die(f"segment {seg['id']}: speed must be within 0.5-4.0", EXIT_USAGE)
        trim = seg.get("trim") or {}
        start = float(trim.get("start", 0.0))
        end = float(trim["end"]) if trim.get("end") is not None else (start + float(trim["duration"]) if trim.get("duration") else float(info["duration"]))
        if start < 0 or end <= start or start >= float(info["duration"]):
            die(f"segment {seg['id']}: bad trim {start}-{end} for a {info['duration']:.2f}s source", EXIT_USAGE)
        end = min(end, float(info["duration"]))
        plan.update(input=src, kind="video", start=start, end=end, speed=speed, duration=(end - start) / speed,
                    has_audio=bool(info.get("has_audio")), fit=plan["fit"] or "contain", probe=info)
    elif t == "ai_clip":
        asset = seg.get("_asset")
        if asset and Path(asset).is_file() and not seg.get("_placeholder"):
            info = probe(asset)
            trim = seg.get("trim") or {}
            start = float(trim.get("start", 0.0))
            end = float(trim.get("end") or info["duration"])
            end = min(end, float(info["duration"]))
            if end <= start:
                die(f"segment {seg['id']}: bad trim for {asset}", EXIT_USAGE)
            plan.update(input=Path(asset), kind="video", start=start, end=end, speed=1.0, duration=end - start,
                        has_audio=bool(info.get("has_audio")) and bool(seg.get("audio", False)), fit=plan["fit"] or "cover", probe=info)
            plan["audio"] = plan["has_audio"]
        else:
            plan.update(input=None, kind="synthetic", duration=float(seg.get("duration", 5)), placeholder=True, audio=False)
    elif t == "still":
        asset = seg.get("_asset")
        dur = float(seg.get("duration", 4))
        if asset and Path(asset).is_file() and not seg.get("_placeholder"):
            plan.update(input=Path(asset), kind="image", duration=dur, motion=seg.get("motion", "zoom_in"),
                        motion_amount=float(seg.get("motion_amount", 0.08)), fit=plan["fit"] or "cover", audio=False)
        else:
            plan.update(input=None, kind="synthetic", duration=dur, placeholder=True, audio=False)
    else:  # title
        bg = seg.get("background")
        dur = float(seg.get("duration", 4))
        if bg and not re.fullmatch(r"#[0-9A-Fa-f]{6}", str(bg)) and ctx.resolve(str(bg)).is_file():
            plan.update(input=ctx.resolve(str(bg)), kind="image", duration=dur, motion=seg.get("motion", "zoom_in"),
                        motion_amount=float(seg.get("motion_amount", 0.06)), fit="cover", audio=False)
        else:
            plan.update(input=None, kind="synthetic", duration=dur, background=bg if bg else ctx.bg, audio=False)
    if plan["duration"] < 0.5:
        die(f"segment {seg['id']}: duration {plan['duration']:.2f}s is too short", EXIT_USAGE)
    return plan


def render_segment(ctx: Ctx, seg: Dict[str, Any], plan: Dict[str, Any], idx: int) -> Path:
    W, H, fps = ctx.width, ctx.height, ctx.fps
    dur = float(plan["duration"])
    out = ctx.work / f"seg-{idx:02d}-{re.sub(r'[^A-Za-z0-9_-]+', '_', seg['id'])}.mov"
    cmd: List[str] = [ctx.ffmpeg, "-y", "-hide_banner", "-loglevel", "error", "-nostdin"]
    vchain: List[str] = []
    achain: Optional[str] = None
    n_inputs = 0
    if plan["kind"] == "video":
        cmd += ["-ss", f"{plan['start']:.3f}", "-t", f"{plan['end'] - plan['start']:.3f}", "-i", str(plan["input"])]
        n_inputs = 1
        v = "[0:v]"
        if plan["speed"] != 1.0:
            vchain.append(f"setpts=PTS/{plan['speed']:.4f}")
        vchain.append(fit_chain(ctx, plan["fit"]))
        vchain.append(f"fps={fps}")
        vchain.append("format=yuv420p")
        if plan["audio"] and plan["has_audio"]:
            tempo = f"atempo={plan['speed']:.4f}," if plan["speed"] != 1.0 else ""
            achain = f"[0:a]{tempo}aresample=48000,aformat=sample_fmts=s16:channel_layouts=stereo[a]"
    elif plan["kind"] == "image":
        n_inputs = 1
        motion = plan.get("motion", "zoom_in")
        amount = plan.get("motion_amount", 0.08)
        frames = max(2, int(round(dur * fps)))
        if motion == "none":
            cmd += ["-loop", "1", "-framerate", str(fps), "-t", f"{dur:.3f}", "-i", str(plan["input"])]
            v = "[0:v]"
            vchain.append(fit_chain(ctx, plan["fit"]))
        else:
            cmd += ["-i", str(plan["input"])]
            v = "[0:v]"
            ow, oh = W * 2, H * 2
            vchain.append(f"scale={ow}:{oh}:force_original_aspect_ratio=increase:flags=lanczos,crop={ow}:{oh},setsar=1")
            N = frames
            ease = f"(1-cos(PI*on/{N}))/2"
            if motion == "zoom_in":
                z, x, y = f"1+{amount}*{ease}", "iw/2-(iw/zoom/2)", "ih/2-(ih/zoom/2)"
            elif motion == "zoom_out":
                z, x, y = f"1+{amount}-{amount}*{ease}", "iw/2-(iw/zoom/2)", "ih/2-(ih/zoom/2)"
            elif motion == "pan_right":
                z, x, y = f"{1 + amount}", f"(iw-iw/zoom)*{ease}", "(ih-ih/zoom)/2"
            else:  # pan_left
                z, x, y = f"{1 + amount}", f"(iw-iw/zoom)*(1-{ease})", "(ih-ih/zoom)/2"
            vchain.append(f"zoompan=z='{esc_opt(z)}':x='{esc_opt(x)}':y='{esc_opt(y)}':d={N}:s={W}x{H}:fps={fps}")
        vchain.append("format=yuv420p")
    else:  # synthetic gradient
        base = plan.get("background") or ctx.bg
        cmd += ["-f", "lavfi", "-i", gradient_source(ctx, str(base), dur, seed=idx + 3)]
        n_inputs = 1
        v = "[0:v]"
        vchain.append("format=yuv420p")
    vchain += overlay_filters(ctx, seg, dur)
    if achain is None:
        cmd += ["-f", "lavfi", "-t", f"{dur:.3f}", "-i", "anullsrc=r=48000:cl=stereo"]
        achain = f"[{n_inputs}:a]aformat=sample_fmts=s16:channel_layouts=stereo[a]"
    graph = f"{v}{','.join(vchain)}[v];{achain}"
    cmd += ["-filter_complex", graph, "-map", "[v]", "-map", "[a]", "-t", f"{dur:.3f}", "-r", str(fps),
            "-c:v", "libx264", "-preset", "ultrafast" if ctx.preview else "veryfast", "-crf", "23" if ctx.preview else "14",
            "-pix_fmt", "yuv420p", "-c:a", "pcm_s16le", "-ar", "48000", "-ac", "2", str(out)]
    ctx.run(cmd, f"rendering segment {seg['id']}")
    return out


# ---------------------------------------------------------------------------
# Final assembly
# ---------------------------------------------------------------------------
def transition_for(ctx: Ctx, seg: Dict[str, Any], prev_dur: float, this_dur: float) -> Optional[Dict[str, Any]]:
    tr = seg.get("transition")
    if not tr:
        return None
    t = tr.get("type", "fade")
    d = float(tr.get("duration", 0.5) or 0)
    if t == "cut" or d <= 0:
        return None
    limit = max(0.05, min(prev_dur, this_dur) - 0.15)
    if d > limit:
        log(f"[plan] segment {seg['id']}: transition {d:.2f}s clamped to {limit:.2f}s (segments too short)")
        d = limit
    return {"type": t, "duration": round(d, 3)}


def assemble(ctx: Ctx, parts: List[Dict[str, Any]], report: Dict[str, Any]) -> float:
    """parts: [{path, duration, transition (into this part or None), audio_active}]"""
    n = len(parts)
    cmd: List[str] = [ctx.ffmpeg, "-y", "-hide_banner", "-loglevel", "error", "-nostdin"]
    for p in parts:
        cmd += ["-i", str(p["path"])]
    lines: List[str] = []
    # group consecutive cuts -> concat
    groups: List[List[int]] = [[0]]
    for i in range(1, n):
        if parts[i]["transition"] is None:
            groups[-1].append(i)
        else:
            groups.append([i])
    gl: List[Dict[str, Any]] = []
    for gi, members in enumerate(groups):
        if len(members) == 1:
            m = members[0]
            gl.append({"v": f"[{m}:v]", "a": f"[{m}:a]", "dur": parts[m]["duration"], "first": m})
        else:
            ins = "".join(f"[{m}:v][{m}:a]" for m in members)
            lines.append(f"{ins}concat=n={len(members)}:v=1:a=1[g{gi}v][g{gi}a]")
            gl.append({"v": f"[g{gi}v]", "a": f"[g{gi}a]", "dur": sum(parts[m]["duration"] for m in members), "first": members[0]})
    cur_v, cur_a, acc = gl[0]["v"], gl[0]["a"], gl[0]["dur"]
    timeline: List[Tuple[float, float, int]] = [(0.0, acc, 0)]
    starts = {0: 0.0}
    for gi, members in enumerate(groups):
        if gi == 0:
            t0 = 0.0
            for m in members:
                starts[m] = t0
                t0 += parts[m]["duration"]
    for k in range(1, len(gl)):
        tr = parts[gl[k]["first"]]["transition"]
        d, t = tr["duration"], tr["type"]
        offset = max(0.0, acc - d)
        lines.append(f"{cur_v}{gl[k]['v']}xfade=transition={t}:duration={d:.3f}:offset={offset:.3f}[x{k}v]")
        lines.append(f"{cur_a}{gl[k]['a']}acrossfade=d={d:.3f}:c1=tri:c2=tri[x{k}a]")
        cur_v, cur_a = f"[x{k}v]", f"[x{k}a]"
        t0 = offset
        for m in groups[k]:
            starts[m] = t0
            t0 += parts[m]["duration"]
        acc = offset + gl[k]["dur"]
    total = acc
    # final video: fades + optional logo
    vf: List[str] = []
    if ctx.fade_in > 0:
        vf.append(f"fade=t=in:st=0:d={ctx.fade_in:.3f}")
    if ctx.fade_out > 0:
        vf.append(f"fade=t=out:st={max(0.0, total - ctx.fade_out):.3f}:d={ctx.fade_out:.3f}")
    next_input = n
    logo = ctx.logo if isinstance(ctx.logo, dict) and ctx.logo.get("path") else None
    lines.append(f"{cur_v}{','.join(vf) if vf else 'null'}[vbase]")
    if logo and ctx.resolve(logo["path"]).is_file():
        cmd += ["-i", str(ctx.resolve(logo["path"]))]
        lw = int(float(logo.get("width", 160)) * ctx.scale)
        m = int(float(logo.get("margin", 48)) * ctx.scale)
        op = float(logo.get("opacity", 0.9))
        pos = logo.get("position", "top-right")
        x = f"W-w-{m}" if "right" in pos else f"{m}"
        y = f"H-h-{m}" if "bottom" in pos else f"{m}"
        lines.append(f"[{next_input}:v]scale={lw}:-1,format=rgba,colorchannelmixer=aa={op}[lg]")
        lines.append(f"[vbase][lg]overlay=x={x}:y={y}[vout]")
        next_input += 1
    else:
        lines.append("[vbase]null[vout]")
    # audio: bgm + ducking
    audio = ctx.sb.get("audio") or {}
    bgm = audio.get("bgm") if isinstance(audio.get("bgm"), dict) else None
    prog = cur_a
    if bgm and bgm.get("path"):
        bpath = ctx.resolve(bgm["path"])
        if not bpath.is_file():
            die(f"bgm not found: {bpath}", EXIT_USAGE)
        if bgm.get("loop", True):
            cmd += ["-stream_loop", "-1"]
        cmd += ["-i", str(bpath)]
        bi = next_input
        next_input += 1
        vol = float(bgm.get("volume", 0.18))
        fi, fo = float(bgm.get("fade_in", 1.5)), float(bgm.get("fade_out", 2.0))
        lines.append(f"[{bi}:a]aformat=sample_fmts=s16:channel_layouts=stereo,aresample=48000,atrim=0:{total:.3f},"
                     f"asetpts=PTS-STARTPTS,volume={vol:.3f},afade=t=in:st=0:d={fi:.3f},afade=t=out:st={max(0.0, total - fo):.3f}:d={fo:.3f}[bgm0]")
        duck = bgm.get("duck") or {}
        mode = duck.get("mode", "sidechain") if duck.get("enabled", True) else "none"
        if mode == "sidechain":
            thr = float(duck.get("threshold", 0.02)); ratio = float(duck.get("ratio", 8))
            att = float(duck.get("attack", 30)); rel = float(duck.get("release", 600))
            lines.append(f"{prog}asplit=2[prog][sc]")
            lines.append(f"[bgm0][sc]sidechaincompress=threshold={thr}:ratio={ratio}:attack={att}:release={rel}:makeup=1:level_sc={float(duck.get('level_sc', 1.0))}[bgmd]")
            lines.append("[prog][bgmd]amix=inputs=2:duration=first:dropout_transition=0:normalize=0[amix]")
        elif mode == "segments":
            level = float(duck.get("level", 0.3))
            spans = [f"between(t,{starts[i]:.3f},{starts[i] + parts[i]['duration']:.3f})" for i, p in enumerate(parts) if p["audio_active"]]
            if spans:
                expr = f"if({'+'.join(spans)},{level},1)"
                lines.append(f"[bgm0]volume='{esc_opt(expr)}':eval=frame[bgmd]")
            else:
                lines.append("[bgm0]anull[bgmd]")
            lines.append(f"{prog}[bgmd]amix=inputs=2:duration=first:dropout_transition=0:normalize=0[amix]")
        else:
            lines.append(f"{prog}[bgm0]amix=inputs=2:duration=first:dropout_transition=0:normalize=0[amix]")
        report["audio"] = {"bgm": str(bpath), "duck_mode": mode, "volume": vol}
    else:
        lines.append(f"{prog}anull[amix]")
        report["audio"] = {"bgm": None}
    master: List[str] = []
    if audio.get("loudnorm"):
        master.append("loudnorm=I=-16:TP=-1.5:LRA=11")
    mv = float(audio.get("master_volume", 1.0) or 1.0)
    if abs(mv - 1.0) > 1e-3:
        master.append(f"volume={mv:.3f}")
    lines.append(f"[amix]{','.join(master) if master else 'anull'}[aout]")
    graph = ";".join(lines)
    ctx.out_path.parent.mkdir(parents=True, exist_ok=True)
    vcodec = [ "-c:v", ctx.codec]
    if ctx.codec == "libx264":
        vcodec += ["-preset", ctx.preset, "-crf", str(ctx.crf), "-profile:v", "high"]
    elif ctx.codec in ("h264_videotoolbox", "hevc_videotoolbox"):
        vcodec += ["-b:v", str(ctx.sb.get("output", {}).get("bitrate", "16M"))]
    cmd += ["-filter_complex", graph, "-map", "[vout]", "-map", "[aout]", "-r", str(ctx.fps), *vcodec,
            "-pix_fmt", "yuv420p", "-movflags", "+faststart", "-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-ac", "2",
            "-t", f"{total:.3f}", str(ctx.out_path)]
    ctx.run(cmd, "assembling the final video")
    report["timeline"] = [{"id": parts[i]["id"], "start": round(starts[i], 3), "end": round(starts[i] + parts[i]["duration"], 3)} for i in range(n)]
    return total


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="compose_demo.py", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("storyboard", help="storyboard.json (paths inside are relative to this file)")
    ap.add_argument("--out", help="output mp4 (default: output.path in the storyboard)")
    ap.add_argument("--generate", action="store_true", help="generate missing ai_clip/still assets with Volcengine Ark (spends money; cached)")
    ap.add_argument("--force-generate", action="store_true", help="with --generate: regenerate even if the asset or cache exists")
    ap.add_argument("--dry-run", action="store_true", help="print the plan, cost estimate and ffmpeg commands; render nothing")
    ap.add_argument("--preview", action="store_true", help="fast 1280x720 draft render (crf 28, ultrafast)")
    ap.add_argument("--width", type=int, help="override output width (even number)")
    ap.add_argument("--height", type=int, help="override output height (even number)")
    ap.add_argument("--fps", type=int, help="override output fps (24/30/60)")
    ap.add_argument("--font", help="font file for overlays (default: PingFang / Hiragino Sans GB / Arial Unicode / Helvetica)")
    ap.add_argument("--work-dir", help="keep intermediates here (default: temp dir, deleted unless --keep-work)")
    ap.add_argument("--keep-work", action="store_true", help="do not delete the temp work dir")
    ap.add_argument("--report", help="path for render-report.json (default: next to the output)")
    ap.add_argument("--verbose", action="store_true", help="print every ffmpeg command as it runs")
    args = ap.parse_args(argv)
    if args.fps and args.fps not in (24, 25, 30, 50, 60):
        die("--fps must be 24, 25, 30, 50 or 60", EXIT_USAGE)

    sb_path = Path(args.storyboard).expanduser()
    sb = load_storyboard(sb_path)
    ctx = Ctx(sb, sb_path, args)
    report: Dict[str, Any] = {"storyboard": str(sb_path.resolve()), "output": str(ctx.out_path), "created_at": _dt.datetime.now().isoformat(timespec="seconds"),
                              "spec": {"width": ctx.width, "height": ctx.height, "fps": ctx.fps, "codec": ctx.codec, "crf": ctx.crf, "font": ctx.font},
                              "generation": {"enabled": ctx.generate}, "assets": [], "segments": [], "dry_run": ctx.dry_run}
    log(f"[plan] output {ctx.width}x{ctx.height}@{ctx.fps}fps -> {ctx.out_path}  font: {Path(ctx.font).name}")

    ensure_assets(ctx, report)
    plans = [plan_segment(ctx, seg) for seg in sb["segments"]]
    for i, (seg, plan) in enumerate(zip(sb["segments"], plans)):
        prev_dur = plans[i - 1]["duration"] if i > 0 else 0.0
        plan["transition"] = transition_for(ctx, seg, prev_dur, plan["duration"]) if i > 0 else None
        if i == 0 and seg.get("transition"):
            log("[plan] first segment's transition is ignored (use output.fade_in for a fade from black)")

    parts: List[Dict[str, Any]] = []
    for i, (seg, plan) in enumerate(zip(sb["segments"], plans)):
        path = render_segment(ctx, seg, plan, i)
        actual = plan["duration"]
        if not ctx.dry_run:
            info = probe(path)
            actual = float(info.get("video_duration") or info["duration"])
        parts.append({"id": seg["id"], "path": path, "duration": actual, "transition": plan["transition"],
                      "audio_active": bool(plan.get("audio")) and plan["kind"] == "video"})
        report["segments"].append({"id": seg["id"], "type": seg["type"], "input": str(plan.get("input") or ""),
                                   "kind": plan["kind"], "placeholder": bool(plan.get("placeholder")),
                                   "trim": ({"start": plan["start"], "end": plan["end"]} if plan.get("start") is not None else None),
                                   "planned_duration": round(plan["duration"], 3), "rendered_duration": round(actual, 3),
                                   "transition": plan["transition"], "audio": bool(plan.get("audio")),
                                   "caption": (seg.get("caption") or {}).get("text"), "title": (seg.get("title") or {}).get("text")})
    total = assemble(ctx, parts, report)
    report["planned_total_duration"] = round(total, 3)

    est_total = sum((a.get("cost_estimate") or {}).get("estimated_yuan") or 0 for a in report["assets"] if a.get("status") in ("dry-run", "generated"))
    act_total = sum(a.get("actual_cost_estimate") or 0 for a in report["assets"] if a.get("status") == "generated")
    report["generation"].update(estimated_yuan=round(est_total, 3), actual_yuan_estimate=round(act_total, 3),
                                usage=[{"id": a["id"], "usage": a.get("usage")} for a in report["assets"] if a.get("usage")])

    if ctx.dry_run:
        print(f"DRY RUN  {ctx.width}x{ctx.height}@{ctx.fps}fps  planned duration {total:.2f}s  -> {ctx.out_path}")
        print(f"{'#':<3}{'id':<14}{'type':<9}{'kind':<10}{'dur':>7}  {'transition':<18} input")
        for i, (seg, plan) in enumerate(zip(sb["segments"], plans)):
            tr = plan["transition"]
            trs = f"{tr['type']} {tr['duration']:.2f}s" if tr else ("-" if i == 0 else "cut")
            src = Path(str(plan.get("input"))).name if plan.get("input") else ("PLACEHOLDER" if plan.get("placeholder") else "gradient")
            print(f"{i:<3}{seg['id']:<14}{seg['type']:<9}{plan['kind']:<10}{plan['duration']:>7.2f}  {trs:<18} {src}")
        gen = [a for a in report["assets"] if a.get("status") in ("dry-run",)]
        if gen:
            print(f"would generate {len(gen)} asset(s), estimated ≈ ¥{est_total:.2f}: " + ", ".join(a["id"] for a in gen))
        elif any(a.get("status") == "placeholder" for a in report["assets"]):
            print("placeholders will be used for: " + ", ".join(a["id"] for a in report["assets"] if a.get("status") == "placeholder") + "  (add --generate to create them)")
        print("\nffmpeg commands:")
        for c in ctx.commands:
            print("  " + c)
        if not args.work_dir:
            shutil.rmtree(ctx.work, ignore_errors=True)
        return 0

    info = probe(ctx.out_path)
    report["output_probe"] = info
    report["commands"] = ctx.commands
    report_path = Path(args.report).expanduser() if args.report else ctx.out_path.with_name(ctx.out_path.stem + "-render-report.json")
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2, default=str), encoding="utf-8")
    print(f"done: {ctx.out_path}  {info['width']}x{info['height']}@{(info.get('fps') or 0):.3g}fps  {info['duration']:.2f}s  "
          f"audio={'yes' if info.get('has_audio') else 'no'}  size={info['size_bytes'] / 1e6:.1f}MB")
    print(f"report: {report_path}")
    if est_total or act_total:
        print(f"generation cost: estimated ¥{est_total:.2f}, from usage ¥{act_total:.2f}")
    if args.keep_work or args.work_dir:
        print(f"intermediates kept in {ctx.work}")
    else:
        shutil.rmtree(ctx.work, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())

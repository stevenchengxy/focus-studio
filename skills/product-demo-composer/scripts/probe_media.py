#!/usr/bin/env python3
"""
probe_media.py - small ffprobe wrapper used by the composer and handy on its own.

  python3 probe_media.py final.mp4 clip.mp4          # JSON per file
  python3 probe_media.py --brief *.mp4               # one line per file

Importable: ``from probe_media import probe, find_ffmpeg, find_ffprobe``.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional

_CANDIDATE_DIRS = ["/usr/local/bin", "/opt/homebrew/bin", "/usr/bin"]


def _find_tool(name: str, env_var: str) -> str:
    override = os.environ.get(env_var)
    if override and Path(override).is_file():
        return override
    found = shutil.which(name)
    if found:
        return found
    for d in _CANDIDATE_DIRS:
        p = Path(d) / name
        if p.is_file():
            return str(p)
    sys.exit(f"error: {name} not found (install ffmpeg 7.x, e.g. `brew install ffmpeg`, or set {env_var})")


def find_ffmpeg() -> str:
    return _find_tool("ffmpeg", "FFMPEG_BIN")


def find_ffprobe() -> str:
    return _find_tool("ffprobe", "FFPROBE_BIN")


def _fraction(s: Optional[str]) -> Optional[float]:
    if not s or s in ("0/0", "N/A"):
        return None
    if "/" in s:
        num, den = s.split("/", 1)
        try:
            return float(num) / float(den) if float(den) else None
        except ValueError:
            return None
    try:
        return float(s)
    except ValueError:
        return None


def probe(path: os.PathLike) -> Dict[str, Any]:
    """Return a flat description of the first video and audio streams of ``path``."""
    p = Path(path)
    if not p.is_file():
        raise FileNotFoundError(str(p))
    cmd = [find_ffprobe(), "-v", "error", "-print_format", "json", "-show_format", "-show_streams", str(p)]
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        raise RuntimeError(f"ffprobe failed for {p}: {res.stderr.strip()[:400]}")
    data = json.loads(res.stdout or "{}")
    fmt = data.get("format", {})
    streams = data.get("streams", [])
    video = next((s for s in streams if s.get("codec_type") == "video" and s.get("disposition", {}).get("attached_pic", 0) == 0), None)
    audio = next((s for s in streams if s.get("codec_type") == "audio"), None)
    info: Dict[str, Any] = {
        "path": str(p),
        "size_bytes": int(fmt.get("size", p.stat().st_size)),
        "format": fmt.get("format_name"),
        "duration": float(fmt["duration"]) if fmt.get("duration") not in (None, "N/A") else None,
        "bit_rate": int(fmt["bit_rate"]) if fmt.get("bit_rate") not in (None, "N/A") else None,
        "has_video": video is not None,
        "has_audio": audio is not None,
    }
    if video:
        rot = 0
        for sd in video.get("side_data_list", []) or []:
            if "rotation" in sd:
                rot = int(sd["rotation"])
        w, h = int(video.get("width", 0)), int(video.get("height", 0))
        if rot in (90, -90, 270, -270):
            w, h = h, w
        info.update({
            "width": w, "height": h, "video_codec": video.get("codec_name"), "pix_fmt": video.get("pix_fmt"),
            "fps": _fraction(video.get("avg_frame_rate")) or _fraction(video.get("r_frame_rate")),
            "video_duration": float(video["duration"]) if video.get("duration") not in (None, "N/A") else info["duration"],
            "nb_frames": int(video["nb_frames"]) if str(video.get("nb_frames", "")).isdigit() else None,
            "sar": video.get("sample_aspect_ratio"), "rotation": rot,
        })
        if info["duration"] is None:
            info["duration"] = info["video_duration"]
    if audio:
        info.update({
            "audio_codec": audio.get("codec_name"), "sample_rate": int(audio.get("sample_rate", 0) or 0),
            "channels": int(audio.get("channels", 0) or 0),
            "audio_duration": float(audio["duration"]) if audio.get("duration") not in (None, "N/A") else info["duration"],
        })
    return info


def brief(info: Dict[str, Any]) -> str:
    parts = [Path(info["path"]).name]
    if info.get("has_video"):
        parts.append(f"{info['width']}x{info['height']}@{(info.get('fps') or 0):.3g}fps {info.get('video_codec')} {info.get('pix_fmt')}")
    if info.get("has_audio"):
        parts.append(f"audio {info.get('audio_codec')} {info.get('sample_rate')}Hz x{info.get('channels')}")
    else:
        parts.append("no audio")
    parts.append(f"{(info.get('duration') or 0):.3f}s")
    parts.append(f"{info['size_bytes'] / 1e6:.2f}MB")
    return " | ".join(parts)


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="ffprobe wrapper: duration, size, fps, codecs, audio presence.")
    ap.add_argument("paths", nargs="+")
    ap.add_argument("--brief", action="store_true", help="one human-readable line per file")
    args = ap.parse_args(argv)
    rc = 0
    results = []
    for p in args.paths:
        try:
            info = probe(p)
        except Exception as e:
            print(f"error: {p}: {e}", file=sys.stderr)
            rc = 1
            continue
        if args.brief:
            print(brief(info))
        else:
            results.append(info)
    if not args.brief:
        print(json.dumps(results if len(results) != 1 else results[0], indent=2, ensure_ascii=False))
    return rc


if __name__ == "__main__":
    sys.exit(main())

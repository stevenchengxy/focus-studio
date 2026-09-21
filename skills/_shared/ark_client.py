#!/usr/bin/env python3
"""
ark_client.py - dependency-free client for Volcengine Ark (火山方舟) Seedance video
generation and Seedream image generation.

Design goals
------------
* Python 3.9+ standard library only (urllib); Pillow is optional and only used to
  shrink local images before embedding them as ``data:`` URLs.
* The API key is read from the ``ARK_API_KEY`` environment variable first and then
  from ``~/.config/focus-studio/ark.env``. It is never printed, logged or written
  anywhere by this module.
* Every paid call goes through a content-addressed cache (sha256 of the request
  JSON) so re-running a storyboard never re-bills a clip that already finished.
* ``dry_run`` builds the exact request payload and a cost estimate without any
  network access.

Import from a skill script::

    import sys, pathlib
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "_shared"))
    from ark_client import ArkClient, load_config, Cache

Command line helpers (never print secrets)::

    python3 ark_client.py check            # is the key configured? (prints source only)
    python3 ark_client.py models           # GET /models (free)
    python3 ark_client.py task <task_id>   # poll one video task
    python3 ark_client.py cancel <task_id> # DELETE a queued task
    python3 ark_client.py estimate --model ... --resolution 720p --duration 5
"""
from __future__ import annotations

import argparse
import base64
import datetime as _dt
import hashlib
import io
import json
import mimetypes
import os
import re
import shutil
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, List, Optional, Tuple

__all__ = [
    "ArkClient", "ArkError", "ArkConfigError", "ArkAPIError", "ArkTaskError", "ArkTimeoutError",
    "Cache", "load_config", "missing_key_instructions", "image_to_data_url", "resolve_image_ref",
    "estimate_video_cost", "estimate_image_cost", "cost_from_usage", "VIDEO_MODELS", "IMAGE_MODELS",
    "redact_for_display", "DEFAULT_BASE_URL", "ENV_FILE",
    "run_video_generation", "run_image_generation", "write_sidecar", "DEFAULT_VIDEO_MODEL", "DEFAULT_IMAGE_MODEL",
    "VIDEO_RATIOS", "VIDEO_RESOLUTIONS", "IMAGE_ROLES", "canonical_json", "utc_now", "probe_activation", "ssl_context",
]

DEFAULT_BASE_URL = "https://ark.cn-beijing.volces.com/api/v3"
ENV_FILE = Path(os.environ.get("FOCUS_STUDIO_ARK_ENV", str(Path.home() / ".config" / "focus-studio" / "ark.env")))
USER_AGENT = "focus-studio-skills/1.0 (+urllib)"

# ---------------------------------------------------------------------------
# Model catalogue (verified with GET /models on 2026-09-21) and pricing hints.
# Prices are 人民币 estimates used only for budgeting; the authoritative number is
# the Volcengine console bill. Calibrate with the `usage.completion_tokens`
# recorded next to every generated asset.
# ---------------------------------------------------------------------------
VIDEO_MODELS: Dict[str, Dict[str, Any]] = {
    "doubao-seedance-2-5-260628": {
        "family": "seedance-2.5", "resolutions": ["480p", "720p", "1080p"], "durations": (4, 15),
        "audio": True, "yuan_per_ktoken": 0.046, "pricing_note": "estimate - not yet verified on this account",
        "tier": "flagship",
    },
    "doubao-seedance-2-0-260128": {
        "family": "seedance-2.0", "resolutions": ["480p", "720p", "1080p"], "durations": (4, 15),
        "audio": True, "yuan_per_ktoken": 0.046, "pricing_note": "estimate (mini is advertised as ~50% cheaper)",
        "tier": "quality",
    },
    "doubao-seedance-2-0-fast-260128": {
        "family": "seedance-2.0", "resolutions": ["480p", "720p", "1080p"], "durations": (4, 15),
        "audio": True, "yuan_per_ktoken": 0.035, "pricing_note": "estimate",
        "tier": "fast",
    },
    "doubao-seedance-2-0-mini-260615": {
        "family": "seedance-2.0", "resolutions": ["480p", "720p"], "durations": (4, 15),
        "audio": True, "yuan_per_ktoken": 0.023, "pricing_note": "public price 2026-06: 0.023 元/千tokens (t2v/i2v), 0.014 with video input",
        "tier": "budget",
    },
    "doubao-seedance-1-0-pro-250528": {
        "family": "seedance-1.0", "resolutions": ["480p", "720p", "1080p"], "durations": (2, 12),
        "audio": False, "yuan_per_ktoken": 0.015, "pricing_note": "public price list (1080p 5s ≈ 3.6 元)",
        "tier": "legacy",
    },
    "doubao-seedance-1-0-pro-fast-251015": {
        "family": "seedance-1.0", "resolutions": ["480p", "720p", "1080p"], "durations": (2, 12),
        "audio": False, "yuan_per_ktoken": 0.010, "pricing_note": "estimate",
        "tier": "legacy-fast",
    },
}

IMAGE_MODELS: Dict[str, Dict[str, Any]] = {
    "doubao-seedream-5-0-pro-260628": {"yuan_per_image": 0.35, "pricing_note": "estimate", "tier": "flagship"},
    "doubao-seedream-5-0-260128": {"yuan_per_image": 0.30, "pricing_note": "estimate", "tier": "quality"},
    "doubao-seedream-4-5-251128": {"yuan_per_image": 0.25, "pricing_note": "≈0.25-0.3 元/张 at 2K", "tier": "default"},
    "doubao-seedream-4-0-250828": {"yuan_per_image": 0.20, "pricing_note": "≈0.2 元/张", "tier": "budget"},
}

DEFAULT_VIDEO_MODEL = "doubao-seedance-2-0-mini-260615"
DEFAULT_IMAGE_MODEL = "doubao-seedream-4-5-251128"

VIDEO_RATIOS = ["16:9", "9:16", "1:1", "4:3", "3:4", "21:9", "adaptive"]
VIDEO_RESOLUTIONS = ["480p", "720p", "1080p"]
IMAGE_ROLES = ["first_frame", "last_frame", "reference_image"]

# Approximate output pixel counts used for token estimates (24 fps assumed).
_RES_PIXELS = {"480p": 864 * 480, "720p": 1280 * 720, "1080p": 1920 * 1080, "4k": 3840 * 2160}


# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------
class ArkError(Exception):
    """Base class for all client errors."""


class ArkConfigError(ArkError):
    """API key / base URL not configured."""


class ArkAPIError(ArkError):
    def __init__(self, status: int, code: str, message: str, body: Any = None):
        self.status, self.code, self.message, self.body = status, code, message, body
        super().__init__(f"HTTP {status} {code}: {message}")


class ArkTaskError(ArkError):
    """Video task ended in failed/cancelled state."""

    def __init__(self, task: Dict[str, Any]):
        self.task = task
        err = task.get("error") or {}
        super().__init__(f"task {task.get('id')} {task.get('status')}: {err.get('code', '')} {err.get('message', '')}".strip())


class ArkTimeoutError(ArkError):
    """wait_for_task gave up."""


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
def _parse_env_file(path: Path) -> Dict[str, str]:
    values: Dict[str, str] = {}
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return values
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export "):].strip()
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        values[key.strip()] = value
    return values


def missing_key_instructions() -> str:
    return (
        "ARK_API_KEY is not configured.\n"
        "Create the key file (never commit it, never paste it into chat or docs):\n"
        f"  mkdir -p {ENV_FILE.parent}\n"
        f"  printf 'ARK_API_KEY=<your key>\\nARK_BASE_URL={DEFAULT_BASE_URL}\\n' > {ENV_FILE}\n"
        f"  chmod 600 {ENV_FILE}\n"
        "Get a key in the Volcengine console: 火山方舟 → API Key 管理. Alternatively export\n"
        "ARK_API_KEY in the shell for one session. This tool never prints the key."
    )


def load_config(require_key: bool = True) -> Tuple[Optional[str], str, str]:
    """Return (api_key, base_url, source). Environment beats the env file."""
    key = (os.environ.get("ARK_API_KEY") or "").strip()
    base = (os.environ.get("ARK_BASE_URL") or "").strip()
    source = "environment"
    if not key or not base:
        file_values = _parse_env_file(ENV_FILE)
        if not key:
            key = (file_values.get("ARK_API_KEY") or "").strip()
            source = f"file:{ENV_FILE}" if key else source
        if not base:
            base = (file_values.get("ARK_BASE_URL") or "").strip()
    base = (base or DEFAULT_BASE_URL).rstrip("/")
    if require_key and not key:
        raise ArkConfigError(missing_key_instructions())
    return (key or None), base, source


def redact_secrets(text: str, key: Optional[str]) -> str:
    """Mask the API key (and anything that looks like a bearer token) in free text."""
    if key:
        text = text.replace(key, "***ARK_API_KEY***")
    return re.sub(r"(?i)(bearer\s+)[A-Za-z0-9._\-]{8,}", r"\1***", text)


# ---------------------------------------------------------------------------
# Helpers for display / hashing
# ---------------------------------------------------------------------------
def redact_for_display(obj: Any) -> Any:
    """Replace base64 data URLs with a short placeholder so payloads print nicely."""
    if isinstance(obj, dict):
        return {k: redact_for_display(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [redact_for_display(v) for v in obj]
    if isinstance(obj, str) and obj.startswith("data:") and len(obj) > 120:
        digest = hashlib.sha256(obj.encode("utf-8")).hexdigest()[:12]
        return f"{obj[:32]}...<data URL, {len(obj)} chars, sha256:{digest}>"
    return obj


def canonical_json(obj: Any) -> str:
    return json.dumps(obj, sort_keys=True, ensure_ascii=False, separators=(",", ":"))


def utc_now() -> str:
    return _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ---------------------------------------------------------------------------
# Image handling (local file -> data URL)
# ---------------------------------------------------------------------------
def image_to_data_url(path: os.PathLike, *, max_side: int = 2048, max_bytes: int = 4 * 1024 * 1024,
                      prefer: str = "jpeg") -> str:
    """Encode a local image as ``data:image/...;base64,...``.

    Uses Pillow when available to downscale to ``max_side`` and keep the encoded
    size under ``max_bytes`` (Ark rejects very large inline images). Falls back to
    raw bytes when Pillow is missing.
    """
    p = Path(path)
    if not p.is_file():
        raise ArkError(f"image not found: {p}")
    try:
        from PIL import Image  # type: ignore
    except Exception:  # Pillow missing -> raw bytes
        data = p.read_bytes()
        if len(data) > max_bytes:
            raise ArkError(f"{p} is {len(data)} bytes; install Pillow or shrink it under {max_bytes} bytes")
        mime = mimetypes.guess_type(str(p))[0] or "image/png"
        return f"data:{mime};base64,{base64.b64encode(data).decode('ascii')}"

    with Image.open(p) as im:
        im.load()
        has_alpha = im.mode in ("RGBA", "LA") or (im.mode == "P" and "transparency" in im.info)
        fmt = "PNG" if (prefer == "png" or (has_alpha and prefer != "jpeg")) else "JPEG"
        if fmt == "JPEG":
            im = im.convert("RGB")
        elif im.mode not in ("RGB", "RGBA"):
            im = im.convert("RGBA" if has_alpha else "RGB")
        w, h = im.size
        scale = min(1.0, max_side / float(max(w, h)))
        if scale < 1.0:
            im = im.resize((max(1, round(w * scale)), max(1, round(h * scale))), Image.LANCZOS)
        quality = 92
        while True:
            buf = io.BytesIO()
            if fmt == "JPEG":
                im.save(buf, format="JPEG", quality=quality, optimize=True)
            else:
                im.save(buf, format="PNG", optimize=True)
            data = buf.getvalue()
            if len(data) * 4 // 3 <= max_bytes or (fmt == "JPEG" and quality <= 40) or (fmt == "PNG" and max(im.size) <= 512):
                if len(data) * 4 // 3 > max_bytes and fmt == "PNG":
                    fmt = "JPEG"; im = im.convert("RGB"); quality = 85; continue
                break
            if fmt == "PNG":
                fmt = "JPEG"; im = im.convert("RGB"); continue
            quality -= 10
            if quality < 40:
                nw, nh = im.size
                im = im.resize((max(1, nw * 3 // 4), max(1, nh * 3 // 4)), Image.LANCZOS)
                quality = 80
    mime = "image/jpeg" if fmt == "JPEG" else "image/png"
    return f"data:{mime};base64,{base64.b64encode(data).decode('ascii')}"


def resolve_image_ref(ref: str, **kwargs: Any) -> str:
    """Accept an http(s) URL, an existing data URL, or a local path (-> data URL)."""
    if ref.startswith(("http://", "https://", "data:")):
        return ref
    return image_to_data_url(Path(ref).expanduser(), **kwargs)


# ---------------------------------------------------------------------------
# Cost estimation
# ---------------------------------------------------------------------------
def _pixels_for(resolution: str, ratio: str) -> int:
    return _RES_PIXELS.get(str(resolution).lower(), _RES_PIXELS["720p"])


def estimate_video_tokens(resolution: str, ratio: str, duration: float, fps: int = 24) -> int:
    """Ark bills video by tokens ≈ width × height × fps × seconds / 1024."""
    return int(round(_pixels_for(resolution, ratio) * fps * float(duration) / 1024.0))


def estimate_video_cost(model: str, resolution: str, ratio: str, duration: float, fps: int = 24) -> Dict[str, Any]:
    info = VIDEO_MODELS.get(model, {})
    tokens = estimate_video_tokens(resolution, ratio, duration, fps)
    rate = info.get("yuan_per_ktoken")
    yuan = round(tokens / 1000.0 * rate, 3) if rate else None
    return {"model": model, "resolution": resolution, "ratio": ratio, "duration": duration,
            "estimated_tokens": tokens, "yuan_per_ktoken": rate, "estimated_yuan": yuan,
            "note": info.get("pricing_note", "unknown model - no pricing data")}


def estimate_image_cost(model: str, n: int = 1) -> Dict[str, Any]:
    info = IMAGE_MODELS.get(model, {})
    per = info.get("yuan_per_image")
    return {"model": model, "images": n, "yuan_per_image": per,
            "estimated_yuan": round(per * n, 3) if per else None,
            "note": info.get("pricing_note", "unknown model - no pricing data")}


def cost_from_usage(model: str, usage: Optional[Dict[str, Any]]) -> Optional[float]:
    """Best-effort cost in 元 from a real ``usage`` block (video tokens or image count)."""
    if not usage:
        return None
    if model in VIDEO_MODELS:
        tokens = usage.get("completion_tokens") or usage.get("total_tokens")
        rate = VIDEO_MODELS[model].get("yuan_per_ktoken")
        if tokens and rate:
            return round(float(tokens) / 1000.0 * rate, 3)
    if model in IMAGE_MODELS:
        n = usage.get("generated_images") or usage.get("output_images") or 1
        per = IMAGE_MODELS[model].get("yuan_per_image")
        if per:
            return round(per * int(n), 3)
    return None


# ---------------------------------------------------------------------------
# Content-addressed cache
# ---------------------------------------------------------------------------
class Cache:
    """Stores one JSON record + one media file per request hash.

    Layout: ``<cache_dir>/<sha256>.json`` and ``<cache_dir>/<sha256>.<ext>``.
    """

    def __init__(self, cache_dir: os.PathLike):
        self.dir = Path(cache_dir)

    @staticmethod
    def key_for(kind: str, payload: Dict[str, Any]) -> str:
        return hashlib.sha256(canonical_json({"kind": kind, "payload": payload}).encode("utf-8")).hexdigest()

    def record_path(self, key: str) -> Path:
        return self.dir / f"{key}.json"

    def lookup(self, key: str) -> Optional[Dict[str, Any]]:
        rp = self.record_path(key)
        if not rp.is_file():
            return None
        try:
            rec = json.loads(rp.read_text(encoding="utf-8"))
        except Exception:
            return None
        media = rec.get("media")
        if media and (self.dir / media).is_file():
            rec["media_path"] = str(self.dir / media)
            return rec
        return None

    def store(self, key: str, record: Dict[str, Any], media_src: Optional[os.PathLike], ext: str) -> Dict[str, Any]:
        self.dir.mkdir(parents=True, exist_ok=True)
        rec = dict(record)
        if media_src is not None:
            dest = self.dir / f"{key}{ext}"
            if Path(media_src).resolve() != dest.resolve():
                shutil.copy2(media_src, dest)
            rec["media"] = dest.name
            rec["media_path"] = str(dest)
        rec["cache_key"] = key
        rec["cached_at"] = utc_now()
        self.record_path(key).write_text(json.dumps(rec, ensure_ascii=False, indent=2), encoding="utf-8")
        return rec


# ---------------------------------------------------------------------------
# TLS: python.org builds on macOS ship without CA certificates unless
# "Install Certificates.command" was run. Verification is never disabled; we just
# look for a trustworthy bundle (env SSL_CERT_FILE / ARK_CA_BUNDLE, certifi, system).
# ---------------------------------------------------------------------------
_CA_BUNDLE_CANDIDATES = [
    "/etc/ssl/cert.pem",                                  # macOS / BSD system bundle
    "/etc/ssl/certs/ca-certificates.crt",                 # Debian / Ubuntu
    "/etc/pki/tls/certs/ca-bundle.crt",                   # RHEL / Fedora
    "/usr/local/etc/ca-certificates/cert.pem",            # Homebrew (Intel)
    "/opt/homebrew/etc/ca-certificates/cert.pem",         # Homebrew (Apple Silicon)
    "/usr/local/etc/openssl@3/cert.pem",
    "/opt/homebrew/etc/openssl@3/cert.pem",
]
_SSL_CONTEXT: Optional[ssl.SSLContext] = None


def ssl_context() -> ssl.SSLContext:
    """Return a verifying SSL context that works even when Python has no default CA store."""
    global _SSL_CONTEXT
    if _SSL_CONTEXT is not None:
        return _SSL_CONTEXT
    ctx = ssl.create_default_context()
    try:
        if ctx.cert_store_stats().get("x509_ca", 0) > 0:
            _SSL_CONTEXT = ctx
            return ctx
    except Exception:
        pass
    candidates = [os.environ.get("ARK_CA_BUNDLE"), os.environ.get("SSL_CERT_FILE")]
    try:
        import certifi  # type: ignore
        candidates.append(certifi.where())
    except Exception:
        pass
    candidates += _CA_BUNDLE_CANDIDATES
    for cafile in candidates:
        if cafile and Path(cafile).is_file():
            try:
                c = ssl.create_default_context(cafile=cafile)
                if c.cert_store_stats().get("x509_ca", 0) > 0:
                    _SSL_CONTEXT = c
                    return c
            except Exception:
                continue
    _SSL_CONTEXT = ctx  # may fail with CERTIFICATE_VERIFY_FAILED; the error message explains the fix
    return ctx


# ---------------------------------------------------------------------------
# HTTP client
# ---------------------------------------------------------------------------
class ArkClient:
    def __init__(self, api_key: Optional[str] = None, base_url: Optional[str] = None, *,
                 timeout: float = 120.0, retries: int = 3, verbose: bool = False,
                 log: Optional[Callable[[str], None]] = None):
        if api_key is None or base_url is None:
            k, b, _ = load_config(require_key=api_key is None)
            api_key = api_key or k
            base_url = base_url or b
        if not api_key:
            raise ArkConfigError(missing_key_instructions())
        self._api_key = api_key
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout
        self.retries = max(0, retries)
        self.verbose = verbose
        self._log = log or (lambda m: print(m, file=sys.stderr, flush=True))

    # -- low level ---------------------------------------------------------
    def log(self, msg: str) -> None:
        self._log(redact_secrets(msg, self._api_key))

    def _headers(self) -> Dict[str, str]:
        return {"Authorization": f"Bearer {self._api_key}", "Content-Type": "application/json",
                "Accept": "application/json", "User-Agent": USER_AGENT}

    def _request(self, method: str, path: str, payload: Optional[Dict[str, Any]] = None, *,
                 timeout: Optional[float] = None, retry_on_5xx: bool = True) -> Dict[str, Any]:
        url = path if path.startswith("http") else f"{self.base_url}/{path.lstrip('/')}"
        data = canonical_json(payload).encode("utf-8") if payload is not None else None
        attempt = 0
        while True:
            attempt += 1
            req = urllib.request.Request(url, data=data, method=method, headers=self._headers())
            if self.verbose:
                size = f" ({len(data)} bytes)" if data else ""
                self.log(f"[ark] {method} {url}{size}")
            try:
                with urllib.request.urlopen(req, timeout=timeout or self.timeout, context=ssl_context()) as resp:
                    raw = resp.read()
                    if not raw:
                        return {}
                    return json.loads(raw.decode("utf-8"))
            except urllib.error.HTTPError as e:
                body_raw = e.read()
                try:
                    body = json.loads(body_raw.decode("utf-8"))
                except Exception:
                    body = body_raw.decode("utf-8", "replace")
                err = body.get("error", body) if isinstance(body, dict) else {}
                code = str(err.get("code", "")) if isinstance(err, dict) else ""
                message = str(err.get("message", body if not isinstance(body, dict) else "")) if isinstance(err, dict) else str(body)
                transient = e.code == 429 or (retry_on_5xx and 500 <= e.code < 600)
                if transient and attempt <= self.retries:
                    delay = min(30.0, 2.0 ** attempt)
                    self.log(f"[ark] HTTP {e.code} {code} - retrying in {delay:.0f}s ({attempt}/{self.retries})")
                    time.sleep(delay)
                    continue
                message = redact_secrets(message, self._api_key)[:2000]
                if code == "ModelNotOpen":
                    message += ("\nhint: this model is listed but not activated for the account. Open the Ark console "
                                "(火山方舟控制台 → 开通管理 / 模型广场) and activate it, then re-run. Nothing was billed.")
                elif code.startswith("InvalidEndpointOrModel"):
                    message += "\nhint: unknown model id for this account/region - check `ark_client.py models`."
                elif e.code == 401:
                    message += f"\nhint: the key was rejected - check ARK_API_KEY in {ENV_FILE} (never paste it into chat)."
                raise ArkAPIError(e.code, code or "http_error", message, body)
            except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
                if attempt <= self.retries:
                    delay = min(30.0, 2.0 ** attempt)
                    self.log(f"[ark] network error ({e}); retrying in {delay:.0f}s ({attempt}/{self.retries})")
                    time.sleep(delay)
                    continue
                hint = ""
                if "CERTIFICATE_VERIFY_FAILED" in str(e):
                    hint = " (no CA bundle found: set SSL_CERT_FILE=/etc/ssl/cert.pem or run Python's 'Install Certificates.command')"
                raise ArkError(f"network error talking to {url}: {e}{hint}")

    # -- models ------------------------------------------------------------
    def list_models(self) -> List[Dict[str, Any]]:
        resp = self._request("GET", "/models")
        return resp.get("data", resp if isinstance(resp, list) else [])

    # -- video -------------------------------------------------------------
    @staticmethod
    def build_video_payload(model: str, prompt: str, *, images: Iterable[Dict[str, str]] = (),
                            resolution: Optional[str] = None, ratio: Optional[str] = None,
                            duration: Optional[int] = None, generate_audio: Optional[bool] = None,
                            watermark: Optional[bool] = False, seed: Optional[int] = None,
                            camera_fixed: Optional[bool] = None, return_last_frame: Optional[bool] = None,
                            extra: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        """Build the JSON body for POST /contents/generations/tasks.

        ``images`` items: ``{"url": <http(s)/data URL>, "role": first_frame|last_frame|reference_image}``.
        Only parameters that are not None are sent, so model-specific rejects are avoided.
        """
        if not prompt or not prompt.strip():
            raise ArkError("prompt must not be empty")
        content: List[Dict[str, Any]] = [{"type": "text", "text": prompt.strip()}]
        for img in images:
            url = img["url"]
            role = img.get("role", "first_frame")
            if role not in IMAGE_ROLES:
                raise ArkError(f"unknown image role {role!r}; expected one of {IMAGE_ROLES}")
            content.append({"type": "image_url", "image_url": {"url": url}, "role": role})
        payload: Dict[str, Any] = {"model": model, "content": content}
        for key, val in (("resolution", resolution), ("ratio", ratio), ("duration", duration),
                         ("generate_audio", generate_audio), ("watermark", watermark), ("seed", seed),
                         ("camera_fixed", camera_fixed), ("return_last_frame", return_last_frame)):
            if val is not None:
                payload[key] = val
        if extra:
            payload.update(extra)
        return payload

    def create_video_task(self, payload_or_model: Any, prompt: Optional[str] = None, **kwargs: Any) -> Dict[str, Any]:
        """Submit a video task. Accepts a prebuilt payload dict or (model, prompt, **options)."""
        payload = payload_or_model if isinstance(payload_or_model, dict) else \
            self.build_video_payload(payload_or_model, prompt or "", **kwargs)
        resp = self._request("POST", "/contents/generations/tasks", payload, retry_on_5xx=False)
        if "id" not in resp:
            raise ArkError(f"unexpected create response: {json.dumps(redact_for_display(resp), ensure_ascii=False)[:500]}")
        return resp

    def get_task(self, task_id: str) -> Dict[str, Any]:
        return self._request("GET", f"/contents/generations/tasks/{urllib.parse.quote(task_id)}")

    def cancel_task(self, task_id: str) -> Dict[str, Any]:
        return self._request("DELETE", f"/contents/generations/tasks/{urllib.parse.quote(task_id)}")

    def wait_for_task(self, task_id: str, *, timeout: float = 1800.0, initial: float = 5.0, maximum: float = 20.0,
                      on_update: Optional[Callable[[Dict[str, Any]], None]] = None) -> Dict[str, Any]:
        """Poll until succeeded (returns task) or failed/cancelled (raises ArkTaskError)."""
        start = time.monotonic()
        delay = initial
        last_status = None
        while True:
            task = self.get_task(task_id)
            status = task.get("status")
            if status != last_status:
                elapsed = time.monotonic() - start
                self.log(f"[ark] task {task_id}: {status} (+{elapsed:.0f}s)")
                last_status = status
            if on_update:
                on_update(task)
            if status == "succeeded":
                return task
            if status in ("failed", "cancelled", "canceled", "expired"):
                raise ArkTaskError(task)
            if time.monotonic() - start > timeout:
                raise ArkTimeoutError(f"task {task_id} still {status} after {timeout:.0f}s; poll later with: ark_client.py task {task_id}")
            time.sleep(delay)
            delay = min(maximum, delay * 1.5)

    # -- images ------------------------------------------------------------
    @staticmethod
    def build_image_payload(model: str, prompt: str, *, images: Iterable[str] = (), size: str = "2K",
                            response_format: str = "url", watermark: bool = False, seed: Optional[int] = None,
                            output_format: Optional[str] = None,
                            sequential_image_generation: str = "disabled",
                            extra: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        """Build the JSON body for POST /images/generations (Seedream 4.x / 5.x)."""
        if not prompt or not prompt.strip():
            raise ArkError("prompt must not be empty")
        payload: Dict[str, Any] = {"model": model, "prompt": prompt.strip(), "size": size,
                                   "response_format": response_format, "watermark": bool(watermark),
                                   "sequential_image_generation": sequential_image_generation}
        imgs = list(images)
        if imgs:
            payload["image"] = imgs[0] if len(imgs) == 1 else imgs
        if seed is not None:
            payload["seed"] = int(seed)
        if output_format:
            payload["output_format"] = output_format
        if extra:
            payload.update(extra)
        return payload

    def generate_image(self, payload_or_model: Any, prompt: Optional[str] = None, **kwargs: Any) -> Dict[str, Any]:
        payload = payload_or_model if isinstance(payload_or_model, dict) else \
            self.build_image_payload(payload_or_model, prompt or "", **kwargs)
        resp = self._request("POST", "/images/generations", payload, timeout=max(self.timeout, 300.0), retry_on_5xx=False)
        if "data" not in resp:
            raise ArkError(f"unexpected image response: {json.dumps(redact_for_display(resp), ensure_ascii=False)[:500]}")
        if resp.get("error"):
            err = resp["error"]
            raise ArkAPIError(200, str(err.get("code", "")), str(err.get("message", "")), resp)
        return resp

    # -- downloads ---------------------------------------------------------
    def download(self, url: str, dest: os.PathLike, *, chunk: int = 1 << 20, timeout: float = 300.0) -> Path:
        """Stream a (temporary, signed) result URL to ``dest``. Also handles data URLs."""
        dest = Path(dest)
        dest.parent.mkdir(parents=True, exist_ok=True)
        if url.startswith("data:"):
            head, _, b64 = url.partition(",")
            dest.write_bytes(base64.b64decode(b64))
            return dest
        req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
        tmp = dest.with_suffix(dest.suffix + ".part")
        with urllib.request.urlopen(req, timeout=timeout, context=ssl_context()) as resp, open(tmp, "wb") as fh:
            while True:
                block = resp.read(chunk)
                if not block:
                    break
                fh.write(block)
        tmp.replace(dest)
        return dest

    def save_image_result(self, resp: Dict[str, Any], dest: os.PathLike, index: int = 0) -> Path:
        item = resp["data"][index]
        if item.get("url"):
            return self.download(item["url"], dest)
        if item.get("b64_json"):
            dest = Path(dest)
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(base64.b64decode(item["b64_json"]))
            return dest
        raise ArkError(f"image item has neither url nor b64_json: {json.dumps(redact_for_display(item))[:300]}")


# ---------------------------------------------------------------------------
# High-level "generate with cache" helpers shared by all skills
# ---------------------------------------------------------------------------
def write_sidecar(out_path: os.PathLike, record: Dict[str, Any]) -> Path:
    """Write ``<out>.json`` next to a generated asset (request, task id, usage, cost)."""
    out = Path(out_path)
    side = out.with_name(out.name + ".json")
    side.parent.mkdir(parents=True, exist_ok=True)
    side.write_text(json.dumps(record, ensure_ascii=False, indent=2), encoding="utf-8")
    return side


def _copy_if_different(src: os.PathLike, dst: os.PathLike) -> None:
    src, dst = Path(src), Path(dst)
    dst.parent.mkdir(parents=True, exist_ok=True)
    if src.resolve() != dst.resolve():
        shutil.copy2(src, dst)


def run_video_generation(payload: Dict[str, Any], out_path: os.PathLike, *, cache_dir: Optional[os.PathLike] = None,
                         dry_run: bool = False, force: bool = False, timeout: float = 1800.0,
                         client: Optional["ArkClient"] = None, verbose: bool = False,
                         log: Optional[Callable[[str], None]] = None) -> Dict[str, Any]:
    """Create → poll → download one Seedance clip, with the content-addressed cache in front.

    Returns a record dict with ``status`` in {"cached", "dry-run", "generated"}.
    Never bills twice for the same request JSON unless ``force`` is set.
    """
    _log = log or (lambda m: print(m, file=sys.stderr, flush=True))
    out = Path(out_path)
    cache = Cache(cache_dir or out.parent / ".cache")
    key = Cache.key_for("video", payload)
    model = payload.get("model", "")
    est = estimate_video_cost(model, str(payload.get("resolution", "720p")), str(payload.get("ratio", "16:9")),
                              float(payload.get("duration", 5)))
    record: Dict[str, Any] = {"kind": "video", "cache_key": key, "model": model,
                              "request": redact_for_display(payload), "cost_estimate": est,
                              "output": str(out), "created_at": utc_now()}
    hit = None if force else cache.lookup(key)
    if hit:
        _copy_if_different(hit["media_path"], out)
        record.update(status="cached", task_id=hit.get("task_id"), usage=hit.get("usage"),
                      actual_cost_estimate=hit.get("actual_cost_estimate"), cached_at=hit.get("cached_at"))
        write_sidecar(out, record)
        _log(f"[ark] cache hit {key[:12]} -> {out} (no API call, no charge)")
        return record
    if dry_run:
        record["status"] = "dry-run"
        return record
    client = client or ArkClient(verbose=verbose, log=log)
    task = client.create_video_task(payload)
    task_id = task["id"]
    _log(f"[ark] created video task {task_id} (model {model}); polling...")
    final = client.wait_for_task(task_id, timeout=timeout)
    content = final.get("content") or {}
    video_url = content.get("video_url")
    if not video_url:
        raise ArkError(f"task {task_id} succeeded but has no content.video_url: {json.dumps(redact_for_display(final))[:400]}")
    out.parent.mkdir(parents=True, exist_ok=True)
    client.download(video_url, out)
    extras: Dict[str, str] = {}
    if content.get("last_frame_url"):
        lf = out.with_name(f"{out.stem}-last-frame.jpg")
        try:
            client.download(content["last_frame_url"], lf)
            extras["last_frame"] = str(lf)
        except Exception as e:  # not fatal
            _log(f"[ark] could not download last frame: {e}")
    usage = final.get("usage")
    record.update(status="generated", task_id=task_id, usage=usage,
                  actual_cost_estimate=cost_from_usage(model, usage), task=redact_for_display(final), extras=extras)
    cache.store(key, record, out, out.suffix or ".mp4")
    write_sidecar(out, record)
    _log(f"[ark] saved {out} ({out.stat().st_size} bytes); usage={json.dumps(usage)}")
    return record


def _sniff_image_ext(data: bytes) -> str:
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return ".png"
    if data[:3] == b"\xff\xd8\xff":
        return ".jpg"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return ".webp"
    return ""


def run_image_generation(payload: Dict[str, Any], out_path: os.PathLike, *, cache_dir: Optional[os.PathLike] = None,
                         dry_run: bool = False, force: bool = False, client: Optional["ArkClient"] = None,
                         verbose: bool = False, log: Optional[Callable[[str], None]] = None) -> Dict[str, Any]:
    """Generate one Seedream image with caching; converts to the requested extension via Pillow if needed."""
    _log = log or (lambda m: print(m, file=sys.stderr, flush=True))
    out = Path(out_path)
    cache = Cache(cache_dir or out.parent / ".cache")
    key = Cache.key_for("image", payload)
    model = payload.get("model", "")
    est = estimate_image_cost(model, 1)
    record: Dict[str, Any] = {"kind": "image", "cache_key": key, "model": model,
                              "request": redact_for_display(payload), "cost_estimate": est,
                              "output": str(out), "created_at": utc_now()}
    hit = None if force else cache.lookup(key)
    if hit:
        _copy_if_different(hit["media_path"], out)
        record.update(status="cached", usage=hit.get("usage"), actual_cost_estimate=hit.get("actual_cost_estimate"),
                      cached_at=hit.get("cached_at"), size=hit.get("size"))
        write_sidecar(out, record)
        _log(f"[ark] cache hit {key[:12]} -> {out} (no API call, no charge)")
        return record
    if dry_run:
        record["status"] = "dry-run"
        return record
    client = client or ArkClient(verbose=verbose, log=log)
    _log(f"[ark] requesting image from {model} (size {payload.get('size')})...")
    resp = client.generate_image(payload)
    item = resp["data"][0]
    out.parent.mkdir(parents=True, exist_ok=True)
    tmp = out.with_name(out.stem + ".download")
    client.save_image_result(resp, tmp)
    data = tmp.read_bytes()
    actual_ext = _sniff_image_ext(data)
    want_ext = out.suffix.lower() if out.suffix else (actual_ext or ".png")
    if actual_ext and want_ext not in (actual_ext, ".jpeg" if actual_ext == ".jpg" else actual_ext):
        try:
            from PIL import Image  # type: ignore
            with Image.open(tmp) as im:
                im.load()
                if want_ext in (".jpg", ".jpeg"):
                    im = im.convert("RGB")
                im.save(out)
            tmp.unlink(missing_ok=True)
            _log(f"[ark] converted {actual_ext} result to {out.suffix}")
        except Exception as e:
            _log(f"[ark] could not convert {actual_ext} -> {want_ext} ({e}); keeping original bytes")
            tmp.replace(out)
    else:
        tmp.replace(out)
    usage = resp.get("usage")
    record.update(status="generated", usage=usage, actual_cost_estimate=cost_from_usage(model, usage),
                  size=item.get("size"), revised_prompt=item.get("revised_prompt"),
                  response={k: v for k, v in resp.items() if k != "data"})
    cache.store(key, record, out, out.suffix or actual_ext or ".png")
    write_sidecar(out, record)
    _log(f"[ark] saved {out} ({out.stat().st_size} bytes, reported size {item.get('size')}); usage={json.dumps(usage)}")
    return record


# ---------------------------------------------------------------------------
# Zero-cost activation probe. Ark checks whether a model is activated for the
# account *before* validating parameters, so a deliberately invalid request tells
# us "activated" (HTTP 400 InvalidParameter) or "not activated" (404 ModelNotOpen)
# without ever creating a task or billing anything. Verified 2026-09-21.
# ---------------------------------------------------------------------------
def probe_activation(client: "ArkClient", models: Iterable[str]) -> List[Dict[str, Any]]:
    results = []
    for m in models:
        if m in IMAGE_MODELS or "seedream" in m:
            path, payload = "/images/generations", {"model": m, "prompt": "probe", "size": "7x7", "response_format": "url", "watermark": False}
        else:
            path, payload = "/contents/generations/tasks", {"model": m, "content": [{"type": "text", "text": "probe"}],
                                                            "resolution": "480p", "ratio": "99:1", "duration": 5}
        try:
            resp = client._request("POST", path, payload, retry_on_5xx=False)
            state = "accepted-unexpectedly"
            if resp.get("id"):  # should never happen with the invalid ratio; cancel to avoid billing
                try:
                    client.cancel_task(resp["id"])
                    state += "(cancelled)"
                except Exception:
                    pass
            results.append({"model": m, "state": state, "detail": json.dumps(redact_for_display(resp))[:200]})
        except ArkAPIError as e:
            if e.code == "ModelNotOpen":
                state = "not-activated"
            elif e.status == 404:
                state = "unknown-model"
            elif e.status == 400:
                state = "activated"
            elif e.status == 401:
                state = "bad-key"
            else:
                state = f"http-{e.status}"
            results.append({"model": m, "state": state, "code": e.code, "detail": e.message.split("\n")[0][:160]})
        except ArkError as e:
            results.append({"model": m, "state": "error", "detail": str(e)[:160]})
    return results


# ---------------------------------------------------------------------------
# CLI (diagnostics only)
# ---------------------------------------------------------------------------
def _cli(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="Diagnostics for the Volcengine Ark client (never prints the key).")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("check", help="verify that ARK_API_KEY is configured (prints only the source)")
    sub.add_parser("models", help="GET /models - list model ids available to this key (free)")
    p_task = sub.add_parser("task", help="GET one video generation task")
    p_task.add_argument("task_id")
    p_task.add_argument("--wait", action="store_true", help="poll until it finishes")
    p_cancel = sub.add_parser("cancel", help="DELETE a queued/running video task")
    p_cancel.add_argument("task_id")
    p_probe = sub.add_parser("probe-activation", help="free check: which Seedance/Seedream models are activated for this key")
    p_probe.add_argument("models", nargs="*", help="model ids (default: all known video + image models)")
    p_est = sub.add_parser("estimate", help="estimate the cost of a video request")
    p_est.add_argument("--model", default=DEFAULT_VIDEO_MODEL)
    p_est.add_argument("--resolution", default="720p")
    p_est.add_argument("--ratio", default="16:9")
    p_est.add_argument("--duration", type=float, default=5)
    args = ap.parse_args(argv)

    try:
        if args.cmd == "check":
            key, base, source = load_config()
            print(json.dumps({"configured": True, "source": source, "base_url": base, "key_length": len(key or "")}, indent=2))
            return 0
        if args.cmd == "estimate":
            print(json.dumps(estimate_video_cost(args.model, args.resolution, args.ratio, args.duration), indent=2, ensure_ascii=False))
            return 0
        client = ArkClient()
        if args.cmd == "models":
            models = client.list_models()
            ids = sorted(m.get("id", "?") for m in models) if isinstance(models, list) else models
            print(json.dumps(ids, indent=2, ensure_ascii=False))
            return 0
        if args.cmd == "task":
            task = client.wait_for_task(args.task_id) if args.wait else client.get_task(args.task_id)
            print(json.dumps(redact_for_display(task), indent=2, ensure_ascii=False))
            return 0
        if args.cmd == "probe-activation":
            models = args.models or (list(VIDEO_MODELS) + list(IMAGE_MODELS))
            rows = probe_activation(client, models)
            for r in rows:
                print(f"{r['model']:<40} {r['state']:<22} {r.get('detail', '')}")
            return 0 if any(r["state"] == "activated" for r in rows) else 1
        if args.cmd == "cancel":
            print(json.dumps(client.cancel_task(args.task_id), indent=2, ensure_ascii=False))
            return 0
    except ArkConfigError as e:
        print(f"error: {e}", file=sys.stderr)
        return 3
    except ArkTaskError as e:
        print(f"error: {e}", file=sys.stderr)
        return 5
    except ArkError as e:
        print(f"error: {e}", file=sys.stderr)
        return 4
    return 2


if __name__ == "__main__":
    sys.exit(_cli())

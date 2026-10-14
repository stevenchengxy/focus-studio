#!/usr/bin/env python3
"""Publish verified installers without overwriting a published release.

Authentication uses GH_TOKEN or the existing Git credential helper, never argv/files.
Example: publish-installers.py --tag v1.14.3-preview.1 --notes docs/releases/1.14.3.md
         --asset dist/releases/Focus-Studio-1.14.3-universal-local.dmg --publish
Without --publish this performs local validation only, with no network access.
Use --refresh-catalog alone to refresh public metadata from already published releases.
"""
import argparse
import base64
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
from urllib.parse import quote, urlparse

REPOSITORY = "stevenchengxy/focus-studio"
VERSION = r"(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)"
TAG = re.compile(rf"v(?P<version>{VERSION})(?:-preview\.(?:0|[1-9]\d*))?")
SHA = re.compile(r"[0-9a-f]{40}")
CATALOG_BRANCH = "release-feed"
CATALOG_PATH = "releases.json"
CATALOG_URL = f"https://raw.githubusercontent.com/{REPOSITORY}/{CATALOG_BRANCH}/{CATALOG_PATH}"


def sha256(path):
    with path.open("rb") as file:
        return hashlib.file_digest(file, "sha256").hexdigest()


def asset_identity(name):
    native = re.fullmatch(rf"Focus-Studio-(?P<version>{VERSION})-universal-(?:local|developer-id|notarized)\.dmg", name)
    desktop = re.fullmatch(rf"Focus-Studio-Desktop-(?P<version>{VERSION})-(?:windows-x64\.exe|linux-x86_64\.AppImage|linux-amd64\.deb)", name)
    if native:
        return "native", native["version"]
    if desktop:
        return "desktop", desktop["version"]
    raise ValueError(f"Not a versioned installer: {name}")


def validate_asset(path):
    asset_identity(path.name)
    if not path.is_file() or path.stat().st_size < 1024:
        raise ValueError(f"Not an installer file: {path.name}")
    with path.open("rb") as file:
        first = file.read(8)
        file.seek(-512, 2)
        tail = file.read(4)
    valid = (path.name.endswith(".dmg") and tail == b"koly") or (path.name.endswith(".exe") and first[:2] == b"MZ") or (path.name.endswith(".AppImage") and first[:4] == b"\x7fELF") or (path.name.endswith(".deb") and first == b"!<arch>\n")
    if not valid:
        raise ValueError(f"Installer signature does not match its extension: {path.name}")
    return sha256(path)


def validate_installers(tag, paths):
    match = TAG.fullmatch(tag)
    if not match:
        raise ValueError("Use vMAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH-preview.N")
    if not paths or len({p.name for p in paths}) != len(paths):
        raise ValueError("Supply uniquely named installers")
    desktop_versions = set()
    for path in paths:
        family, version = asset_identity(path.name)
        if family == "native" and version != match["version"]:
            raise ValueError(f"Mac installer version does not match release tag: {path.name}")
        if family == "desktop":
            desktop_versions.add(version)
    if len(desktop_versions) > 1:
        raise ValueError("All desktop installers must have the same version")
    return {path.name: validate_asset(path) for path in sorted(paths, key=lambda p: p.name)}


class APIError(RuntimeError):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


def api(path, method="GET", body=None, upload=None):
    token = os.environ.get("GH_TOKEN", "")
    if not token:
        credential = subprocess.run(["git", "credential", "fill"], input="protocol=https\nhost=github.com\n\n", text=True, capture_output=True, check=True)
        token = dict(line.split("=", 1) for line in credential.stdout.splitlines() if "=" in line)["password"]
    url = path if path.startswith("https://") else f"https://api.github.com/repos/{REPOSITORY}/{path}"
    parsed = urlparse(url)
    if (parsed.scheme != "https" or parsed.hostname not in ("api.github.com", "uploads.github.com") or
            parsed.username or parsed.password or parsed.port not in (None, 443) or parsed.fragment or
            not parsed.path.startswith(f"/repos/{REPOSITORY}/")):
        raise ValueError("Unexpected GitHub API endpoint")
    config = "\n".join(["url = " + json.dumps(url), "header = " + json.dumps("Authorization: Bearer " + token), 'header = "Accept: application/vnd.github+json"'])
    with tempfile.TemporaryDirectory(prefix="focus-release-") as folder:
        command = ["/usr/bin/curl", "--silent", "--show-error", "--max-time", "600", "--config", "-", "--request", method, "--write-out", "\n%{http_code}"]
        if upload:
            command += ["--header", "Content-Type: application/octet-stream", "--data-binary", "@" + str(upload)]
        elif body is not None:
            payload = Path(folder) / "request.json"
            payload.write_text(json.dumps(body), encoding="utf-8")
            command += ["--header", "Content-Type: application/json", "--data-binary", "@" + str(payload)]
        response = subprocess.run(command, input=config, text=True, capture_output=True)
        raw, _, status = response.stdout.rpartition("\n")
        status = int(status) if status.isdigit() else 0
        if response.returncode or not 200 <= status < 300:
            message = (response.stderr or raw or "GitHub request failed")[:800].replace(token, "[redacted]")
            raise APIError(status, message)
        return json.loads(raw)


def tag_commit(tag, api_call=api):
    """Resolve the ref object, not the release's mutable target_commitish label."""
    try:
        value = api_call("git/ref/tags/" + quote(tag, safe=""))["object"]
    except APIError as error:
        if error.status == 404:
            return None
        raise
    visited = set()
    for _ in range(16):
        sha, kind = value.get("sha"), value.get("type")
        if not isinstance(sha, str) or not SHA.fullmatch(sha) or sha in visited:
            raise ValueError("Invalid or cyclic release tag object")
        if kind == "commit":
            return sha
        if kind != "tag":
            raise ValueError("Release tag must resolve to a commit")
        visited.add(sha)
        value = api_call("git/tags/" + sha)["object"]
    raise ValueError("Release tag nesting is too deep")


def list_items(path, api_call):
    for page in range(1, 101):
        items = api_call(f"{path}?per_page=100&page={page}")
        if not isinstance(items, list):
            raise ValueError("Invalid GitHub listing response")
        yield from items
        if len(items) < 100:
            return
    raise ValueError("GitHub listing exceeded the safe page limit")


def release_metadata(tag, body):
    return {"name": "Focus Studio " + tag[1:], "body": body, "prerelease": "-preview." in tag}


def preflight_assets(existing, expected, require_complete=False):
    """Validate every existing asset before the first upload, including checksums."""
    names = [asset.get("name") for asset in existing]
    if len(names) != len(set(names)) or any(name not in expected for name in names):
        raise ValueError("Release contains unexpected or duplicate assets; leave it unchanged")
    for asset in existing:
        target = expected[asset["name"]]
        if (asset.get("digest") != "sha256:" + target["digest"] or asset.get("size") != target["size"] or
                asset.get("state") != "uploaded"):
            raise ValueError(f"Existing asset differs or is unverifiable: {asset['name']}; leave the release unchanged")
    missing = sorted(set(expected) - set(names))
    if require_complete and missing:
        raise ValueError("Published release is missing requested assets; publish a new version instead")
    return missing


def safe_catalog_release(release):
    """Keep public installer metadata only; no notes, authors or API URLs."""
    if not isinstance(release, dict) or release.get("draft") is not False or not isinstance(release.get("prerelease"), bool):
        return None
    tag = release.get("tag_name")
    if not isinstance(tag, str) or not TAG.fullmatch(tag):
        return None
    release_url = f"https://github.com/{REPOSITORY}/releases/tag/{tag}"
    if release.get("html_url") != release_url:
        return None
    try:
        published = datetime.fromisoformat(release["published_at"].replace("Z", "+00:00"))
        if published.tzinfo is None:
            return None
        published_at = published.astimezone(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
    except (KeyError, TypeError, ValueError, AttributeError):
        return None
    title = release.get("name")
    title = "".join(ch for ch in title if ch >= " " and ch != "\x7f")[:160].strip() if isinstance(title, str) else ""
    assets = []
    seen = set()
    for asset in release.get("assets", []) if isinstance(release.get("assets"), list) else []:
        if not isinstance(asset, dict) or not isinstance(asset.get("name"), str):
            continue
        name = asset["name"]
        try:
            family, version = asset_identity(name)
        except ValueError:
            continue
        if family == "native" and version != TAG.fullmatch(tag)["version"]:
            continue
        url = f"https://github.com/{REPOSITORY}/releases/download/{tag}/{name}"
        size = asset.get("size")
        if (name in seen or asset.get("browser_download_url") != url or asset.get("state") != "uploaded" or
                not isinstance(size, int) or isinstance(size, bool) or size <= 0 or size > 5_000_000_000):
            continue
        seen.add(name)
        clean = {"name": name, "browser_download_url": url, "state": "uploaded", "size": size}
        digest = asset.get("digest")
        if isinstance(digest, str) and re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
            clean["digest"] = digest
        assets.append(clean)
    if not assets:
        return None
    return {"tag_name": tag, "name": title or "Focus Studio " + tag[1:], "draft": False,
            "prerelease": release["prerelease"], "published_at": published_at, "html_url": release_url,
            "assets": sorted(assets, key=lambda asset: asset["name"])}


def public_catalog(api_call=api):
    releases = []
    tags = set()
    # The newest 500 releases are sufficient for update discovery. Do not fetch
    # unbounded history or write an ever-growing response into the public branch.
    for page in range(1, 6):
        items = api_call(f"releases?per_page=100&page={page}")
        if not isinstance(items, list):
            raise ValueError("Invalid release listing; catalog was not updated")
        for item in items:
            clean = safe_catalog_release(item)
            if clean and clean["tag_name"] not in tags:
                releases.append(clean)
                tags.add(clean["tag_name"])
        if len(items) < 100:
            break
    releases.sort(key=lambda release: (release["published_at"], release["tag_name"]), reverse=True)
    return releases


def refresh_catalog(source_sha=None, required_tag=None, api_call=api):
    """Only update releases.json on a dedicated branch, never release assets."""
    try:
        branch = api_call("git/ref/heads/" + CATALOG_BRANCH)
    except APIError as error:
        if error.status != 404:
            raise
        if source_sha is None:
            source_sha = api_call("git/ref/heads/main")["object"]["sha"]
        if not isinstance(source_sha, str) or not SHA.fullmatch(source_sha):
            raise ValueError("Catalog branch requires an exact source commit")
        try:
            api_call("git/refs", "POST", {"ref": "refs/heads/" + CATALOG_BRANCH, "sha": source_sha})
        except APIError as error:
            if error.status != 422:
                raise
        branch = api_call("git/ref/heads/" + CATALOG_BRANCH)
    if branch.get("object", {}).get("type") != "commit" or not SHA.fullmatch(branch.get("object", {}).get("sha", "")):
        raise ValueError("Invalid catalog branch")
    try:
        existing = api_call(f"contents/{CATALOG_PATH}?ref={CATALOG_BRANCH}")
    except APIError as error:
        if error.status != 404:
            raise
        existing = None
    previous = None
    if existing is not None:
        if (existing.get("type") != "file" or existing.get("encoding") != "base64" or
                not SHA.fullmatch(existing.get("sha", "")) or not isinstance(existing.get("content"), str)):
            raise ValueError("Catalog path is not a regular file; leave it unchanged")
        previous = base64.b64decode(existing["content"], validate=False)
        if len(previous) > 4_000_000:
            raise ValueError("Existing catalog exceeds the safe size limit")
    releases = public_catalog(api_call)
    if required_tag is not None and required_tag not in {release["tag_name"] for release in releases}:
        raise ValueError("Published release is not visible in the catalog yet; retry --refresh-catalog")
    content = (json.dumps(releases, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode("utf-8")
    if len(content) > 4_000_000:
        raise ValueError("Catalog exceeds the safe size limit")
    if content == previous:
        return {"url": CATALOG_URL, "changed": False, "releases": len(releases)}
    payload = {"message": "Update public installer release catalog", "branch": CATALOG_BRANCH,
               "content": base64.b64encode(content).decode("ascii")}
    if existing is not None:
        payload["sha"] = existing["sha"]
    # A concurrent edit fails with a conflict rather than overwriting a newer
    # catalog. Read the branch afresh by rerunning --refresh-catalog.
    api_call("contents/" + CATALOG_PATH, "PUT", payload)
    return {"url": CATALOG_URL, "changed": True, "releases": len(releases)}


def refresh_after_publish(tag, sha, api_call):
    try:
        result = refresh_catalog(source_sha=sha, required_tag=tag, api_call=api_call)
        print("Public installer catalog: " + result["url"])
    except Exception as error:
        raise RuntimeError("Release is published, but catalog refresh failed. Run --refresh-catalog to retry; do not replace release assets.") from error


def publish_release(tag, body, sha, paths, digests, api_call=api):
    if not SHA.fullmatch(sha):
        raise ValueError("Expected an exact Git commit SHA")
    resolved = tag_commit(tag, api_call)
    if resolved is not None and resolved != sha:
        raise ValueError("Release tag points to different source; bump the version")
    releases = [item for item in list_items("releases", api_call) if item.get("tag_name") == tag]
    if len(releases) > 1:
        raise ValueError("Multiple releases use this tag; leave them unchanged")
    release = releases[0] if releases else None
    metadata = release_metadata(tag, body)
    if release and any(release.get(key) != value for key, value in metadata.items()):
        raise ValueError("Existing release metadata differs; leave it unchanged")
    with tempfile.TemporaryDirectory(prefix="focus-checksums-") as folder:
        checksum = Path(folder) / "SHA256SUMS.txt"
        checksum.write_text("".join(f"{digests[name]}  {name}\n" for name in sorted(digests)), encoding="utf-8")
        files = {path.name: path for path in [*paths, checksum]}
        expected = {name: {"digest": digests.get(name) or sha256(path), "size": path.stat().st_size} for name, path in files.items()}
        existing = list(list_items(f"releases/{release['id']}/assets", api_call)) if release else []
        missing = preflight_assets(existing, expected, require_complete=bool(release and not release["draft"]))
        if release and not release["draft"]:
            if resolved != sha:
                raise ValueError("Published release has no matching tag; leave it unchanged")
            print(release["html_url"])
            refresh_after_publish(tag, sha, api_call)
            return release  # Release stays read-only; only catalog metadata may change.
        if resolved is None:
            try:
                api_call("git/refs", "POST", {"ref": "refs/tags/" + tag, "sha": sha})
            except APIError as error:
                if error.status != 422:  # Another publisher may have created it.
                    raise
            if tag_commit(tag, api_call) != sha:
                raise ValueError("Release tag changed during preflight; leave the release draft")
        if release is None:
            release = api_call("releases", "POST", {"tag_name": tag, "target_commitish": sha, **metadata, "draft": True})
        for name in missing:
            # A parallel publisher may have published the draft. Never append to
            # an already published release, even when an earlier lookup was draft.
            current = api_call("releases/" + str(release["id"]))
            if not current.get("draft"):
                raise ValueError("Release is already published; no assets will be uploaded")
            upload_url = current["upload_url"].split("{")[0] + "?name=" + quote(name, safe="")
            asset = api_call(upload_url, "POST", upload=files[name])
            preflight_assets([asset], {name: expected[name]}, require_complete=True)
            print(f"Verified upload: {name}", flush=True)
        final = api_call("releases/" + str(release["id"]))
        preflight_assets(list(list_items(f"releases/{release['id']}/assets", api_call)), expected, require_complete=True)
        if tag_commit(tag, api_call) != sha or any(final.get(key) != value for key, value in metadata.items()):
            raise ValueError("Release source or metadata changed; leave it unchanged")
        result = api_call("releases/" + str(release["id"]), "PATCH", {"draft": False}) if final["draft"] else final
        print(result["html_url"])
        refresh_after_publish(tag, sha, api_call)
        return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag")
    parser.add_argument("--notes", type=Path)
    parser.add_argument("--asset", action="append", type=Path)
    parser.add_argument("--publish", action="store_true")
    parser.add_argument("--refresh-catalog", action="store_true", help="Refresh public metadata from published releases; does not publish or upload installers")
    args = parser.parse_args(argv)
    if args.refresh_catalog:
        if args.tag or args.notes or args.asset or args.publish:
            parser.error("Use --refresh-catalog alone")
        print(json.dumps(refresh_catalog(), indent=2))
        return
    if not args.tag or not args.notes or not args.asset:
        parser.error("--tag, --notes and --asset are required for a dry run or publish")
    digests = validate_installers(args.tag, args.asset)
    body = args.notes.read_text(encoding="utf-8")
    sha = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    if not args.publish:
        print(json.dumps({"tag": args.tag, "commit": sha, "sha256": digests, "published": False}, indent=2))
        return
    if subprocess.check_output(["git", "status", "--porcelain"], text=True).strip():
        raise ValueError("Commit and test the release source before publishing")
    publish_release(args.tag, body, sha, args.asset, digests)


if __name__ == "__main__":
    main()

"""Offline publisher regression tests. No GitHub requests or release mutations."""
import contextlib
import base64
import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import types
import unittest
from unittest import mock
from urllib.parse import parse_qs, urlparse

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("publisher", ROOT / "scripts/publish-installers.py")
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)
COMMIT = "a" * 40
OTHER = "b" * 40
TAG = "v1.14.3-preview.1"
NOTES = "Tested installer release.\n"


class GitHubFixture:
    def __init__(self, release=None, ref=None, objects=None):
        self.release = release
        self.ref = ref
        self.objects = objects or {}
        self.calls = []
        self.uploads = []
        self.publish_on_check = False
        self.retarget_after_upload = False

    def __call__(self, path, method="GET", body=None, upload=None):
        self.calls.append((method, path, body))
        if path.startswith("git/ref/tags/"):
            if self.ref is None:
                raise publisher.APIError(404, "Not Found")
            return {"object": self.ref}
        if path.startswith("git/tags/"):
            return {"object": self.objects[path.removeprefix("git/tags/")]}
        if path == "git/refs" and method == "POST":
            self.ref = {"type": "commit", "sha": body["sha"]}
            return {"object": self.ref}
        if path.startswith("releases?"):
            return [copy.deepcopy(self.release)] if self.release else []
        if path == "releases" and method == "POST":
            self.release = {"id": 7, "html_url": "https://github.com/stevenchengxy/focus-studio/releases/tag/" + TAG,
                "upload_url": "https://uploads.github.com/repos/stevenchengxy/focus-studio/releases/7/assets{?name,label}",
                "assets": [], **body}
            return copy.deepcopy(self.release)
        if path.startswith("releases/7/assets?"):
            return copy.deepcopy(self.release["assets"])
        if path == "releases/7" and method == "GET":
            if self.publish_on_check:
                self.release["draft"] = False
            return copy.deepcopy(self.release)
        if path.startswith("https://uploads.github.com/") and method == "POST":
            assert self.release["draft"], "A published release must never receive uploads"
            name = parse_qs(urlparse(path).query)["name"][0]
            data = upload.read_bytes()
            asset = {"name": name, "digest": "sha256:" + hashlib.sha256(data).hexdigest(), "size": len(data), "state": "uploaded"}
            self.release["assets"].append(asset)
            self.uploads.append((name, data))
            if self.retarget_after_upload:
                self.ref = {"type": "commit", "sha": OTHER}
            return asset
        if path == "releases/7" and method == "PATCH":
            assert self.release["draft"], "A published release must never receive PATCH"
            self.release.update(body)
            return copy.deepcopy(self.release)
        raise AssertionError((method, path))

    @property
    def writes(self):
        return [call for call in self.calls if call[0] != "GET"]


class PublisherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="focus-publisher-test-")
        self.addCleanup(self.temp.cleanup)
        self.paths = []
        names = ["Focus-Studio-1.14.3-universal-local.dmg", "Focus-Studio-Desktop-0.1.1-windows-x64.exe",
                 "Focus-Studio-Desktop-0.1.1-linux-x86_64.AppImage", "Focus-Studio-Desktop-0.1.1-linux-amd64.deb"]
        for name in names:
            data = bytearray(2048)
            if name.endswith(".dmg"):
                data[-512:-508] = b"koly"
            elif name.endswith(".exe"):
                data[:2] = b"MZ"
            elif name.endswith(".AppImage"):
                data[:4] = b"\x7fELF"
            else:
                data[:8] = b"!<arch>\n"
            path = Path(self.temp.name) / name
            path.write_bytes(data)
            self.paths.append(path)
        self.digests = publisher.validate_installers(TAG, self.paths)
        self.manifest = "".join(f"{self.digests[name]}  {name}\n" for name in sorted(self.digests)).encode()
        self.assets = [{"name": path.name, "digest": "sha256:" + self.digests[path.name], "size": path.stat().st_size, "state": "uploaded"} for path in self.paths]
        self.assets.append({"name": "SHA256SUMS.txt", "digest": "sha256:" + hashlib.sha256(self.manifest).hexdigest(), "size": len(self.manifest), "state": "uploaded"})

    def release(self, draft=True, assets=None):
        return {"id": 7, "tag_name": TAG, "draft": draft, "target_commitish": "main", **publisher.release_metadata(TAG, NOTES),
                "upload_url": "https://uploads.github.com/repos/stevenchengxy/focus-studio/releases/7/assets{?name,label}",
                "html_url": "https://github.com/stevenchengxy/focus-studio/releases/tag/" + TAG,
                "assets": copy.deepcopy(assets if assets is not None else self.assets)}

    def publish(self, fixture, paths=None):
        with contextlib.redirect_stdout(io.StringIO()), mock.patch.object(publisher, "refresh_after_publish") as refresh:
            try:
                return publisher.publish_release(TAG, NOTES, COMMIT, paths or self.paths, self.digests, api_call=fixture)
            finally:
                self.refresh_calls = refresh.call_args_list

    def test_installer_signatures_and_actual_debian_amd64_name(self):
        self.assertEqual(len(self.digests), 4)
        with self.assertRaises(ValueError):
            publisher.asset_identity("Focus-Studio-Desktop-0.1.1-linux-x86_64.deb")
        self.paths[0].write_bytes(b"wrong" * 500)
        with self.assertRaisesRegex(ValueError, "signature"):
            publisher.validate_asset(self.paths[0])

    def test_mac_tag_version_and_desktop_consistency_checked(self):
        with self.assertRaisesRegex(ValueError, "Mac installer version"):
            publisher.validate_installers("v1.14.2", self.paths)
        changed = self.paths[1].with_name(self.paths[1].name.replace("0.1.1", "0.1.2"))
        self.paths[1].rename(changed)
        with self.assertRaisesRegex(ValueError, "same version"):
            publisher.validate_installers(TAG, [self.paths[0], changed, *self.paths[2:]])
        with self.assertRaisesRegex(ValueError, "uniquely"):
            publisher.validate_installers(TAG, [self.paths[0], self.paths[0]])

    def test_recursive_annotated_and_lightweight_tags_resolve_to_commit(self):
        fixture = GitHubFixture(ref={"type": "tag", "sha": "c" * 40}, objects={
            "c" * 40: {"type": "tag", "sha": "d" * 40}, "d" * 40: {"type": "commit", "sha": COMMIT}})
        self.assertEqual(publisher.tag_commit(TAG, fixture), COMMIT)
        self.assertEqual(publisher.tag_commit(TAG, GitHubFixture(ref={"type": "commit", "sha": COMMIT})), COMMIT)
        fixture.objects["d" * 40] = {"type": "tag", "sha": "c" * 40}
        with self.assertRaisesRegex(ValueError, "cyclic"):
            publisher.tag_commit(TAG, fixture)

    def test_wrong_existing_tag_rejected_before_any_write_even_without_release(self):
        for release in [None, self.release()]:
            fixture = GitHubFixture(release=release, ref={"type": "commit", "sha": OTHER})
            with self.assertRaisesRegex(ValueError, "different source"):
                self.publish(fixture)
            self.assertEqual(fixture.writes, [])

    def test_branch_target_commitish_ignored_when_actual_tag_matches(self):
        fixture = GitHubFixture(release=self.release(draft=False), ref={"type": "commit", "sha": COMMIT})
        self.publish(fixture)
        self.assertEqual(fixture.writes, [])
        self.assertEqual(self.refresh_calls, [mock.call(TAG, COMMIT, fixture)])

    def test_published_release_requires_exact_assets_and_metadata_and_never_mutates(self):
        for change in ["missing", "changed", "extra", "notes", "unverifiable", "missing-tag"]:
            release = self.release(draft=False)
            ref = {"type": "commit", "sha": COMMIT}
            if change == "missing": release["assets"].pop()
            if change == "changed": release["assets"][0]["digest"] = "sha256:bad"
            if change == "extra": release["assets"].append({**release["assets"][0], "name": "other.zip"})
            if change == "notes": release["body"] = "Other notes"
            if change == "unverifiable": release["assets"][0].pop("digest")
            if change == "missing-tag": ref = None
            fixture = GitHubFixture(release=release, ref=ref)
            with self.subTest(change=change), self.assertRaises(ValueError): self.publish(fixture)
            self.assertEqual(fixture.writes, [])

    def test_all_asset_conflicts_including_manifest_preflight_before_upload(self):
        # A missing early asset must not be uploaded before a later conflict is seen.
        for name in [self.paths[-1].name, "SHA256SUMS.txt"]:
            existing = next(copy.deepcopy(asset) for asset in self.assets if asset["name"] == name)
            existing["digest"] = "sha256:bad"
            fixture = GitHubFixture(release=self.release(assets=[existing]), ref={"type": "commit", "sha": COMMIT})
            with self.assertRaisesRegex(ValueError, "differs"):
                self.publish(fixture)
            self.assertEqual(fixture.writes, [])

    def test_new_release_creates_exact_tag_uploads_sorted_manifest_then_publishes(self):
        fixture = GitHubFixture()
        result = self.publish(fixture, paths=list(reversed(self.paths)))
        self.assertFalse(result["draft"])
        self.assertEqual(fixture.writes[0][1], "git/refs")
        self.assertEqual(fixture.writes[0][2], {"ref": "refs/tags/" + TAG, "sha": COMMIT})
        self.assertEqual(fixture.writes[-1], ("PATCH", "releases/7", {"draft": False}))
        self.assertEqual(dict(fixture.uploads)["SHA256SUMS.txt"], self.manifest)
        self.assertEqual(len(fixture.uploads), 5)
        self.assertEqual(self.refresh_calls, [mock.call(TAG, COMMIT, fixture)])

    def test_matching_draft_retry_uploads_only_missing_assets(self):
        fixture = GitHubFixture(release=self.release(assets=self.assets[:2]), ref={"type": "commit", "sha": COMMIT})
        self.publish(fixture)
        self.assertEqual({name for name, _ in fixture.uploads}, {asset["name"] for asset in self.assets[2:]})
        self.assertFalse(fixture.release["draft"])

    def test_published_by_another_client_before_upload_stops_without_writes(self):
        fixture = GitHubFixture(release=self.release(assets=[]), ref={"type": "commit", "sha": COMMIT})
        fixture.publish_on_check = True
        with self.assertRaisesRegex(ValueError, "already published"):
            self.publish(fixture)
        self.assertEqual(fixture.writes, [])

    def test_retargeted_tag_is_not_published_after_upload(self):
        fixture = GitHubFixture(release=self.release(assets=[]), ref={"type": "commit", "sha": COMMIT})
        fixture.retarget_after_upload = True
        with self.assertRaisesRegex(ValueError, "source or metadata changed"):
            self.publish(fixture)
        self.assertTrue(fixture.release["draft"])
        self.assertFalse(any(method == "PATCH" for method, _, _ in fixture.calls))

    def test_paginated_release_listing_is_not_limited_to_first_100(self):
        calls = []
        def api(path):
            calls.append(path)
            return [{}] * 100 if parse_qs(urlparse(path).query)["page"] == ["1"] else [{"id": 7}]
        self.assertEqual(len(list(publisher.list_items("releases", api))), 101)
        self.assertEqual(calls, ["releases?per_page=100&page=1", "releases?per_page=100&page=2"])

    def test_api_keeps_token_in_stdin_and_rejects_other_hosts_repositories_and_redirects(self):
        token = "sensitive-test-token"
        with mock.patch.dict(os.environ, {"GH_TOKEN": token}), mock.patch.object(publisher.subprocess, "run") as run:
            run.return_value = types.SimpleNamespace(returncode=0, stdout='{"ok":true}\n200', stderr="")
            self.assertEqual(publisher.api("releases"), {"ok": True})
            args, kwargs = run.call_args
            self.assertNotIn(token, " ".join(args[0]))
            self.assertIn(token, kwargs["input"])
            self.assertNotIn("--location", args[0])
            for endpoint in ["https://evil.test/repos/stevenchengxy/focus-studio/releases", "https://api.github.com/repos/other/repo/releases", "https://user@api.github.com/repos/stevenchengxy/focus-studio/releases"]:
                with self.assertRaises(ValueError): publisher.api(endpoint)
            run.return_value = types.SimpleNamespace(returncode=0, stdout=f'{{"message":"{token}"}}\n404', stderr="")
            with self.assertRaises(publisher.APIError) as failure: publisher.api("releases")
            self.assertEqual(failure.exception.status, 404)
            self.assertNotIn(token, str(failure.exception))
            run.return_value = types.SimpleNamespace(returncode=0, stdout='{}\n302', stderr="")
            with self.assertRaises(publisher.APIError): publisher.api("releases")


class CatalogFixture:
    def __init__(self, releases, branch=True, content=None):
        self.releases = releases
        self.branch = branch
        self.content = content
        self.calls = []
        self.conflict = False

    def __call__(self, path, method="GET", body=None, upload=None):
        self.calls.append((method, path, body))
        if path == "git/ref/heads/release-feed":
            if not self.branch: raise publisher.APIError(404, "Not found")
            return {"object": {"type": "commit", "sha": COMMIT}}
        if path == "git/ref/heads/main":
            return {"object": {"type": "commit", "sha": COMMIT}}
        if path == "git/refs" and method == "POST":
            assert body["ref"] == "refs/heads/release-feed"
            self.branch = True
            return {"object": {"type": "commit", "sha": body["sha"]}}
        if path == "contents/releases.json?ref=release-feed":
            if self.content is None: raise publisher.APIError(404, "Not found")
            return {"type": "file", "encoding": "base64", "sha": OTHER, "content": base64.b64encode(self.content).decode()}
        if path.startswith("releases?"):
            page = int(parse_qs(urlparse(path).query)["page"][0])
            return copy.deepcopy(self.releases[(page - 1) * 100:page * 100])
        if path == "contents/releases.json" and method == "PUT":
            if self.conflict: raise publisher.APIError(409, "Concurrent catalog update")
            self.content = base64.b64decode(body["content"])
            return {"content": {"sha": "c" * 40}}
        raise AssertionError((method, path))

    @property
    def writes(self):
        return [call for call in self.calls if call[0] != "GET"]


class CatalogTests(unittest.TestCase):
    setUp = PublisherTests.setUp
    release = PublisherTests.release
    def catalog_release(self):
        data = self.release(draft=False)
        data["published_at"] = "2026-10-14T10:00:00Z"
        for asset in data["assets"]:
            asset["browser_download_url"] = f"https://github.com/stevenchengxy/focus-studio/releases/download/{TAG}/{asset['name']}"
        return data

    def test_catalog_filters_drafts_unsafe_links_and_private_metadata(self):
        release = self.catalog_release()
        release["body"] = "INTERNAL_NOTES"
        release["author"] = {"email": "PRIVATE_EMAIL"}
        release["assets"][0]["uploader"] = {"secret": "PRIVATE_UPLOADER"}
        self.assertIsNone(publisher.safe_catalog_release({**release, "draft": True}))
        self.assertIsNone(publisher.safe_catalog_release({**release, "html_url": "https://evil.test/release"}))
        safe = publisher.safe_catalog_release(release)
        self.assertEqual(len(safe["assets"]), 4)  # Checksum text is not an installer.
        self.assertNotIn("INTERNAL", json.dumps(safe)); self.assertNotIn("PRIVATE", json.dumps(safe))
        self.assertEqual([asset["name"] for asset in safe["assets"]], sorted(asset["name"] for asset in safe["assets"]))
        invalid = copy.deepcopy(release)
        invalid["assets"][0]["browser_download_url"] += "?redirect=https://evil.test"
        self.assertEqual(len(publisher.safe_catalog_release(invalid)["assets"]), 3)
        self.assertIsNone(publisher.safe_catalog_release({**release, "published_at": "2026-10-14"}))

    def test_catalog_bootstrap_creates_only_branch_and_manifest_from_exact_sha(self):
        fixture = CatalogFixture([self.catalog_release()], branch=False)
        result = publisher.refresh_catalog(source_sha=COMMIT, required_tag=TAG, api_call=fixture)
        self.assertTrue(result["changed"]); self.assertEqual(result["releases"], 1)
        self.assertEqual(fixture.writes[0], ("POST", "git/refs", {"ref": "refs/heads/release-feed", "sha": COMMIT}))
        self.assertEqual(fixture.writes[1][0:2], ("PUT", "contents/releases.json"))
        self.assertEqual(fixture.writes[1][2]["branch"], "release-feed")
        self.assertNotIn("sha", fixture.writes[1][2])
        self.assertEqual(json.loads(fixture.content)[0]["tag_name"], TAG)
        self.assertNotIn("git/ref/heads/main", [path for _, path, _ in fixture.calls])

    def test_catalog_refresh_is_deterministic_and_noop_when_unchanged(self):
        fixture = CatalogFixture([self.catalog_release()])
        publisher.refresh_catalog(api_call=fixture)
        content = fixture.content
        fixture.calls.clear(); fixture.releases[0]["assets"].reverse()
        result = publisher.refresh_catalog(api_call=fixture)
        self.assertFalse(result["changed"]); self.assertEqual(fixture.writes, [])
        self.assertEqual(content, fixture.content)

    def test_catalog_updates_only_expected_file_using_optimistic_blob_sha(self):
        fixture = CatalogFixture([self.catalog_release()], content=b"[]\n")
        publisher.refresh_catalog(api_call=fixture)
        self.assertEqual(len(fixture.writes), 1)
        method, path, body = fixture.writes[0]
        self.assertEqual((method, path, body["branch"], body["sha"]), ("PUT", "contents/releases.json", "release-feed", OTHER))
        fixture = CatalogFixture([self.catalog_release()], content=b"[]\n"); fixture.conflict = True
        with self.assertRaises(publisher.APIError): publisher.refresh_catalog(api_call=fixture)
        self.assertEqual(fixture.content, b"[]\n")

    def test_catalog_missing_new_publication_does_not_replace_current_file(self):
        fixture = CatalogFixture([], content=b"[]\n")
        with self.assertRaisesRegex(ValueError, "not visible"):
            publisher.refresh_catalog(required_tag=TAG, api_call=fixture)
        self.assertEqual(fixture.writes, [])

    def test_catalog_refresh_paginates_and_standalone_bootstraps_from_main(self):
        fixture = CatalogFixture([{}] * 100 + [self.catalog_release()], branch=False)
        result = publisher.refresh_catalog(api_call=fixture)
        self.assertEqual(result["releases"], 1)
        self.assertIn(("GET", "git/ref/heads/main", None), fixture.calls)
        self.assertIn(("GET", "releases?per_page=100&page=2", None), fixture.calls)

    def test_published_release_remains_published_when_catalog_refresh_fails(self):
        with mock.patch.object(publisher, "refresh_catalog", side_effect=publisher.APIError(403, "Unavailable")):
            with self.assertRaisesRegex(RuntimeError, "Release is published.*refresh-catalog"):
                publisher.refresh_after_publish(TAG, COMMIT, None)


if __name__ == "__main__":
    unittest.main()

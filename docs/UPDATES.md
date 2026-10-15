# Release and update flow

The website and installed applications share `/api/releases?platform=mac|windows|linux&channel=preview|stable`.
It discovers uploaded installer assets through the public `release-feed/releases.json` catalog generated from
this repository's published GitHub Releases. The website reads this small file through GitHub's raw CDN,
avoiding anonymous GitHub API rate limits on shared hosting. Draft releases and
source ZIP archives never qualify. A preview channel includes stable releases; stable excludes previews.
Mac and Desktop versions are compared separately using their installer filenames, not the enclosing release tag.

## Publish an update

1. Bump the Mac version **and** build in `Resources/Info.plist`. Desktop shell changes also bump
   `desktop/package.json` and `desktop/package-lock.json`. Every shipped update needs a new semantic version;
   never replace the bytes behind an existing installer URL. Set `FocusStudioUpdateChannel` for the intended Mac channel.
2. Run the relevant tests and `scripts/package-release.sh`. The package verifies Universal 2, MCP discovery,
   signatures, resources and DMG integrity. For Windows/Linux, the Desktop Preview workflow runs native-host
   tests and produces NSIS, AppImage and Debian artifacts. Download those artifacts and inspect their checksums.
3. Write release notes stating compatibility, signing status and any untested external services. Commit and push
   the exact tested source. Keep user data, API keys and recordings out of all artifacts.
4. Run `python3 scripts/publish-installers.py --tag vVERSION-preview.1 --notes PATH --asset PATH_TO_DMG`
   (repeat `--asset` for desktop installers). This is a local dry run. Add `--publish` when ready.
   The command uses existing GitHub authentication, uploads to a draft, verifies GitHub's SHA-256 digest and only
   then publishes. It refuses to overwrite different assets or a release tied to different source. After publication,
   it refreshes only `releases.json` on the dedicated `release-feed` branch. Other files and branches are preserved.
   An exact retry does not change the release or its assets; it may refresh the catalog. Unchanged catalog content
   produces no new commit. A catalog conflict stops instead of overwriting a concurrent update.
5. Within five minutes the website resolves the new installer. Verify `/api/releases`, then download the actual
   file through `/api/download/PLATFORM?channel=preview&version=VERSION` and compare its checksum. Download errors
   remain error pages and are never saved under an installer extension. Versioned URLs keep resumed transfers stable.
6. Native apps check once per day, with a manual **Check for Updates** action. Failed checks must not report
   “up to date.” Updates are notices and user-initiated downloads; apps never silently replace themselves.

If publication succeeded but catalog refresh failed, retry metadata alone:

```sh
python3 scripts/publish-installers.py --refresh-catalog
```

This command uses existing GitHub authentication to list published releases and update the public catalog;
it never uploads installers, changes release notes or publishes drafts. On first use it creates `release-feed`
from `main`; normal publication creates it from the exact tested release commit. The catalog includes only
official installer URLs and public version metadata, with at most the newest 500 releases. Its public URL is
`https://raw.githubusercontent.com/stevenchengxy/focus-studio/release-feed/releases.json`.

An older app without the checker needs one manual update from the website. Mac users quit the app and replace
only `/Applications/Focus Studio.app`; project/media/conversation/provider data lives separately. Windows users
run the newer installer; Linux users replace the AppImage or upgrade the Debian package. Desktop/browser work
must be exported before closing. Start a fresh Codex conversation after updating the MCP helper.

Public launch still requires the publisher's Developer ID/notarization for Mac and appropriate Windows signing.
Preview download availability does not imply notarization, platform feature parity or paid provider acceptance.

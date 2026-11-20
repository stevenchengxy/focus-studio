"""Isolated preflight checks: mock only security and xcrun, never use Keychain."""
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/check-notarization.sh"
HASH = "0123456789ABCDEF0123456789ABCDEF01234567"
NAME = "Developer ID Application: Example Studio (TESTTEAM01)"
IDENTITIES = f'  1) {HASH} "{NAME}"\n     1 valid identities found\n'
PRIVATE_OUTPUT = "DO-NOT-PRINT-account-token-password-history"


class NotarizationPreflightTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="focus-notary-preflight-")
        self.addCleanup(self.temporary.cleanup)
        self.folder = Path(self.temporary.name)
        self.calls = self.folder / "calls"
        self.environment = {
            "PATH": f"{self.folder}:/usr/bin:/bin",
            "FOCUS_STUDIO_NOTARY_PROFILE": "release profile",
            "FOCUS_MOCK_CALLS": str(self.calls),
            "FOCUS_MOCK_IDENTITIES": IDENTITIES,
            "FOCUS_MOCK_PRIVATE_OUTPUT": PRIVATE_OUTPUT,
        }
        self.mock("security", '''#!/bin/sh
printf '%s\n' "security $*" >> "$FOCUS_MOCK_CALLS"
[ "$*" = "find-identity -v -p codesigning" ] || exit 99
printf '%s' "$FOCUS_MOCK_IDENTITIES"
exit "${FOCUS_MOCK_SECURITY_EXIT:-0}"
''')
        self.mock("xcrun", '''#!/bin/sh
printf '%s\n' "xcrun $*" >> "$FOCUS_MOCK_CALLS"
if [ "$*" = "--find notarytool" ]; then
    exit "${FOCUS_MOCK_FIND_EXIT:-0}"
fi
[ "$#" -eq 6 ] && [ "$1" = notarytool ] && [ "$2" = history ] &&
    [ "$3" = --keychain-profile ] && [ "$4" = "$FOCUS_STUDIO_NOTARY_PROFILE" ] &&
    [ "$5" = --output-format ] && [ "$6" = json ] || exit 99
printf '%s\n' "$FOCUS_MOCK_PRIVATE_OUTPUT"
printf '%s\n' "$FOCUS_MOCK_PRIVATE_OUTPUT" >&2
exit "${FOCUS_MOCK_HISTORY_EXIT:-0}"
''')

    def mock(self, name, content):
        tool = self.folder / name
        tool.write_text(content, encoding="utf-8")
        tool.chmod(0o755)

    def run_check(self, *arguments, **overrides):
        result = subprocess.run(
            ["/bin/zsh", str(SCRIPT), *arguments],
            env={**self.environment, **overrides},
            capture_output=True, text=True, timeout=10,
        )
        self.assertNotIn(PRIVATE_OUTPUT, result.stdout + result.stderr)
        return result

    def command_log(self):
        return self.calls.read_text() if self.calls.exists() else ""

    def test_missing_developer_id(self):
        result = self.run_check(FOCUS_MOCK_IDENTITIES=f'  1) {HASH} "Apple Development: Example"\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Missing a valid Developer ID Application", result.stderr)
        self.assertNotIn("xcrun", self.command_log())

    def test_wrong_explicit_identity(self):
        for identity in ["Apple Development: Example", "F" * 40, "-", "Developer ID Application: Missing (OTHER)"]:
            with self.subTest(identity=identity):
                result = self.run_check(FOCUS_STUDIO_SIGNING_IDENTITY=identity)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("does not match", result.stderr)
        self.assertNotIn("xcrun", self.command_log())

    def test_missing_profile(self):
        result = self.run_check(FOCUS_STUDIO_NOTARY_PROFILE="")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Set FOCUS_STUDIO_NOTARY_PROFILE", result.stderr)
        self.assertNotIn("xcrun", self.command_log())

    def test_success_with_default_name_and_hash(self):
        for identity in ["", NAME, HASH.lower()]:
            with self.subTest(identity=identity):
                result = self.run_check(FOCUS_STUDIO_SIGNING_IDENTITY=identity)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("Ready:", result.stdout)
        calls = self.command_log()
        self.assertIn("notarytool history --keychain-profile release profile --output-format json", calls)
        self.assertNotIn("submit", calls)
        self.assertNotIn("store-credentials", calls)

    def test_authentication_failure_is_redacted(self):
        result = self.run_check(FOCUS_MOCK_HISTORY_EXIT="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("authentication could not be verified", result.stderr)

    def test_security_failure_is_redacted(self):
        result = self.run_check(FOCUS_MOCK_SECURITY_EXIT="1", FOCUS_MOCK_IDENTITIES=PRIVATE_OUTPUT)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Could not inspect", result.stderr)
        self.assertNotIn("xcrun", self.command_log())

    def test_notarytool_missing(self):
        result = self.run_check(FOCUS_MOCK_FIND_EXIT="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("notarytool is unavailable", result.stderr)
        self.assertNotIn("history", self.command_log())

    def test_profile_control_characters_rejected(self):
        result = self.run_check(FOCUS_STUDIO_NOTARY_PROFILE="profile\nname")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("without control characters", result.stderr)
        self.assertNotIn("xcrun", self.command_log())

    def test_help_and_unknown_arguments_do_not_query_keychain(self):
        self.assertEqual(self.run_check("--help").returncode, 0)
        self.assertEqual(self.run_check("--upload").returncode, 2)
        self.assertEqual(self.command_log(), "")


if __name__ == "__main__":
    unittest.main()

#!/bin/zsh
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: scripts/check-notarization.sh [--help]

Read-only checks for a Mac notarized release:
  - A valid Developer ID Application signing identity with its private key.
  - Authentication through the existing FOCUS_STUDIO_NOTARY_PROFILE in Keychain.

Required environment:
  FOCUS_STUDIO_NOTARY_PROFILE     Existing notarytool Keychain profile name.
Optional environment:
  FOCUS_STUDIO_SIGNING_IDENTITY   Exact Developer ID Application name or SHA-1 hash.

No certificates or profiles are created, no files are uploaded, and notarization
history or authentication output is never printed. Profile verification requires
network access. Exit status is nonzero when a prerequisite cannot be verified.
USAGE
}

if [[ $# -eq 1 && "$1" == "--help" ]]; then
    usage
    exit 0
fi
if [[ $# -ne 0 ]]; then
    echo "Usage: scripts/check-notarization.sh [--help]" >&2
    exit 2
fi

REQUESTED_IDENTITY="${FOCUS_STUDIO_SIGNING_IDENTITY:-}"
NOTARY_PROFILE="${FOCUS_STUDIO_NOTARY_PROFILE:-}"
PREFLIGHT_ERRORS=()
DEVELOPER_ID_COUNT=0
SELECTED_IDENTITY_FOUND=false

if ! command -v security >/dev/null 2>&1; then
    PREFLIGHT_ERRORS+=("The macOS security command is unavailable. Run this check on the release Mac.")
elif ! IDENTITY_OUTPUT="$(security find-identity -v -p codesigning 2>/dev/null)"; then
    PREFLIGHT_ERRORS+=("Could not inspect valid code-signing identities. Check access to the release Mac's Keychain.")
else
    # find-identity reports certificate/private-key pairs; -v limits the list to
    # valid identities. Do not inspect or export any other Keychain contents.
    IDENTITY_PATTERN='^[[:space:]]*[0-9]+\)[[:space:]]+([[:xdigit:]]{40})[[:space:]]+"(Developer ID Application: [^"]+)"[[:space:]]*$'
    while IFS= read -r IDENTITY_LINE; do
        if [[ "$IDENTITY_LINE" =~ $IDENTITY_PATTERN ]]; then
            DEVELOPER_ID_COUNT=$((DEVELOPER_ID_COUNT + 1))
            IDENTITY_HASH="${match[1]}"
            IDENTITY_NAME="${match[2]}"
            if [[ -z "$REQUESTED_IDENTITY" || "$REQUESTED_IDENTITY" == "$IDENTITY_NAME" || "${REQUESTED_IDENTITY:u}" == "${IDENTITY_HASH:u}" ]]; then
                SELECTED_IDENTITY_FOUND=true
            fi
        fi
    done <<< "$IDENTITY_OUTPUT"
    if [[ $DEVELOPER_ID_COUNT -eq 0 ]]; then
        PREFLIGHT_ERRORS+=("Missing a valid Developer ID Application certificate with its private key. Apple Development and ad-hoc signatures cannot be notarized for distribution.")
    elif [[ "$SELECTED_IDENTITY_FOUND" != true ]]; then
        PREFLIGHT_ERRORS+=("FOCUS_STUDIO_SIGNING_IDENTITY does not match an available valid Developer ID Application name or SHA-1 hash.")
    fi
fi

if [[ -z "$NOTARY_PROFILE" ]]; then
    PREFLIGHT_ERRORS+=("Set FOCUS_STUDIO_NOTARY_PROFILE to an existing notarytool Keychain profile name.")
elif [[ "$NOTARY_PROFILE" == *[[:cntrl:]]* ]]; then
    PREFLIGHT_ERRORS+=("FOCUS_STUDIO_NOTARY_PROFILE must be a profile name without control characters.")
fi

if [[ ${#PREFLIGHT_ERRORS[@]} -gt 0 ]]; then
    for PREFLIGHT_ERROR in "${PREFLIGHT_ERRORS[@]}"; do
        print -u2 -r -- "Not ready: $PREFLIGHT_ERROR"
    done
    exit 1
fi

if ! command -v xcrun >/dev/null 2>&1 || ! xcrun --find notarytool >/dev/null 2>&1; then
    echo "Not ready: notarytool is unavailable. Select an Xcode or Command Line Tools installation that includes it." >&2
    exit 1
fi

# history is a read-only authentication check. Suppress both streams: successful
# history and server errors may contain account or submission information.
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --output-format json >/dev/null 2>&1; then
    echo "Not ready: notarization authentication could not be verified. Check the named Keychain profile, account access, and network connection. No files were uploaded." >&2
    exit 1
fi

echo "Ready: Developer ID Application signing identity and notarization authentication verified. No files were uploaded."

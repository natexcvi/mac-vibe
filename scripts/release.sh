#!/usr/bin/env bash
# Builds, signs, notarizes and packages MacVibe for distribution.
#
# Produces in dist/:
#   MacVibe-<version>.dmg   notarized + stapled, for humans
#   MacVibe-<version>.zip    notarized + stapled, consumed by Sparkle
#   appcast.xml              EdDSA-signed update feed
#
# Required:
#   SIGN_IDENTITY   "Developer ID Application: Name (TEAMID)"
#
# Notarization credentials — one of:
#   NOTARY_PROFILE=<name>            a `notarytool store-credentials` profile
#   APPLE_API_KEY_PATH=<.p8 path> APPLE_API_KEY_ID=… APPLE_API_ISSUER=…
#
# Sparkle signing — one of:
#   (nothing)                        uses the private key in your login keychain
#   SPARKLE_KEY_PATH=<file>          exported private key, for CI
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="MacVibe"
APP_DIR="build/${APP_NAME}.app"
DIST="dist"
SPARKLE_VERSION="2.9.6"

: "${SIGN_IDENTITY:?set SIGN_IDENTITY to your Developer ID Application identity}"

# ── notarization credentials ──────────────────────────────────────────────
notary_args=()
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    notary_args=(--keychain-profile "${NOTARY_PROFILE}")
elif [[ -n "${APPLE_API_KEY_PATH:-}" ]]; then
    : "${APPLE_API_KEY_ID:?APPLE_API_KEY_ID required alongside APPLE_API_KEY_PATH}"
    : "${APPLE_API_ISSUER:?APPLE_API_ISSUER required alongside APPLE_API_KEY_PATH}"
    notary_args=(--key "${APPLE_API_KEY_PATH}"
                 --key-id "${APPLE_API_KEY_ID}"
                 --issuer "${APPLE_API_ISSUER}")
else
    echo "✗ no notarization credentials (set NOTARY_PROFILE or APPLE_API_KEY_*)" >&2
    exit 1
fi

# ── Sparkle tools ─────────────────────────────────────────────────────────
# Fetched rather than vendored: they're only needed at release time and the
# binaries are large.
SPARKLE_BIN="build/sparkle-${SPARKLE_VERSION}/bin"
if [[ ! -x "${SPARKLE_BIN}/sign_update" ]]; then
    echo "▸ fetching Sparkle ${SPARKLE_VERSION} tools"
    mkdir -p "build/sparkle-${SPARKLE_VERSION}"
    curl -sL "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz" \
        | tar xJ -C "build/sparkle-${SPARKLE_VERSION}"
fi

sparkle_key_args=()
[[ -n "${SPARKLE_KEY_PATH:-}" ]] && sparkle_key_args=(--ed-key-file "${SPARKLE_KEY_PATH}")
# macOS ships bash 3.2, where expanding an empty array under `set -u` is an
# error rather than nothing. Locally the array *is* empty — the key comes from
# the keychain — so every use needs the ${a[@]+…} guard.

# ── build ─────────────────────────────────────────────────────────────────
SIGN_IDENTITY="${SIGN_IDENTITY}" ./build.sh

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP_DIR}/Contents/Info.plist")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${APP_DIR}/Contents/Info.plist")"
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "${APP_DIR}/Contents/Info.plist")"

rm -rf "${DIST}"
mkdir -p "${DIST}"
ZIP="${DIST}/${APP_NAME}-${VERSION}.zip"
DMG="${DIST}/${APP_NAME}-${VERSION}.dmg"

# ── notarize the app ──────────────────────────────────────────────────────
# notarytool takes an archive, not a bundle, so zip first. This zip is
# throwaway — the shipped one is rebuilt after stapling.
echo "▸ notarizing ${APP_NAME}.app"
ditto -c -k --sequesterRsrc --keepParent "${APP_DIR}" "${DIST}/notarize-app.zip"
xcrun notarytool submit "${DIST}/notarize-app.zip" "${notary_args[@]}" --wait
rm -f "${DIST}/notarize-app.zip"

# Stapling attaches the ticket to the bundle so Gatekeeper clears it without a
# network round-trip on the user's machine.
xcrun stapler staple "${APP_DIR}"

# ── package ───────────────────────────────────────────────────────────────
# Built from the *stapled* app so both artifacts carry the ticket.
echo "▸ building ${ZIP}"
ditto -c -k --sequesterRsrc --keepParent "${APP_DIR}" "${ZIP}"

echo "▸ building ${DMG}"
STAGING="$(mktemp -d)"
trap 'rm -rf "${STAGING}"' EXIT
cp -R "${APP_DIR}" "${STAGING}/"
ln -s /Applications "${STAGING}/Applications"
hdiutil create -volname "${APP_NAME}" -srcfolder "${STAGING}" \
    -ov -format UDZO -quiet "${DMG}"

codesign --force --timestamp --sign "${SIGN_IDENTITY}" "${DMG}"

echo "▸ notarizing ${DMG}"
xcrun notarytool submit "${DMG}" "${notary_args[@]}" --wait
xcrun stapler staple "${DMG}"

# ── appcast ───────────────────────────────────────────────────────────────
# Sparkle verifies this signature against SUPublicEDKey in Info.plist, so a
# compromised release page still can't push a payload users will install.
echo "▸ signing update + writing appcast"
SIGNATURE_LINE="$("${SPARKLE_BIN}/sign_update" ${sparkle_key_args[@]+"${sparkle_key_args[@]}"} "${ZIP}")"

RELEASE_TAG="${RELEASE_TAG:-v${VERSION}}"
DOWNLOAD_URL="https://github.com/natexcvi/mac-vibe/releases/download/${RELEASE_TAG}/$(basename "${ZIP}")"

python3 scripts/make_appcast.py \
    --version "${VERSION}" \
    --build "${BUILD_NUMBER}" \
    --min-os "${MIN_OS}" \
    --url "${DOWNLOAD_URL}" \
    --signature-line "${SIGNATURE_LINE}" \
    --notes-url "https://github.com/natexcvi/mac-vibe/releases/tag/${RELEASE_TAG}" \
    --previous "${PREVIOUS_APPCAST:-}" \
    --output "${DIST}/appcast.xml"

echo
echo "✓ ${VERSION} (${BUILD_NUMBER}) ready in ${DIST}/"
ls -lh "${DIST}"
echo
echo "Gatekeeper check:"
spctl --assess --type execute --verbose=2 "${APP_DIR}" 2>&1 | sed 's/^/  /'

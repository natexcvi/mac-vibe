#!/usr/bin/env bash
# Builds and signs MacVibe.app.
#
#   ./build.sh                       ad-hoc signed dev build
#   SIGN_IDENTITY="Developer ID Application: … (TEAMID)" ./build.sh
#                                    distribution build, hardened runtime
#   VERSION=1.2.3 ./build.sh         stamp an explicit marketing version
#   EMBED_MODEL=1 ./build.sh         embed the whisper weights in the bundle
#
# Released builds do NOT embed the model — the app downloads it on first
# launch (see Sources/MacVibe/ModelManager.swift) so that updates stay small.
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${CONFIG:-release}"
APP_NAME="MacVibe"
APP_DIR="build/${APP_NAME}.app"
ENTITLEMENTS="Resources/MacVibe.entitlements"

# ── version ───────────────────────────────────────────────────────────────
# Marketing version comes from $VERSION, else the current git tag, else the
# value already in Info.plist. CFBundleVersion is what Sparkle compares, so it
# must increase monotonically — we use the commit count.
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

# ── code signing identity ─────────────────────────────────────────────────
# Ad-hoc ("-") is fine for local runs but produces a signature that changes on
# every build, which makes macOS re-prompt for Accessibility each time.
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
if [[ "${SIGN_IDENTITY}" == "-" ]]; then
    CODESIGN_FLAGS=(--force --sign -)
    echo "▸ ad-hoc signing (set SIGN_IDENTITY for a distributable build)"
else
    # --options runtime is required for notarization; --timestamp gets a
    # trusted timestamp so the signature outlives the certificate.
    CODESIGN_FLAGS=(--force --options runtime --timestamp --sign "${SIGN_IDENTITY}")
    echo "▸ signing as ${SIGN_IDENTITY}"
fi

echo "▸ cargo build --release (whisper.cpp sidecar)"
( cd RustSidecar && cargo build --release ) >/dev/null

echo "▸ swift build (-c ${CONFIG})"
swift build -c "${CONFIG}" --product "${APP_NAME}"

BIN_DIR="$(swift build -c "${CONFIG}" --show-bin-path)"
BIN_PATH="${BIN_DIR}/${APP_NAME}"
if [[ ! -f "${BIN_PATH}" ]]; then
    echo "✗ binary not found at ${BIN_PATH}" >&2
    exit 1
fi

echo "▸ assembling ${APP_DIR} (${VERSION} build ${BUILD_NUMBER})"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"
mkdir -p "${APP_DIR}/Contents/Frameworks"

cp "${BIN_PATH}"           "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist    "${APP_DIR}/Contents/Info.plist"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" \
                        "${APP_DIR}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" \
                        "${APP_DIR}/Contents/Info.plist"

# Bundle the app icon. Regenerate it if Resources/icon/generate_icon.py is
# newer than the .icns (or the .icns is missing). Skips work in CI / quick
# iteration when the source hasn't changed.
if [[ ! -f Resources/AppIcon.icns ]] \
        || [[ Resources/icon/generate_icon.py -nt Resources/AppIcon.icns ]]; then
    echo "▸ regenerating AppIcon.icns"
    python3 Resources/icon/generate_icon.py
fi
cp Resources/AppIcon.icns  "${APP_DIR}/Contents/Resources/AppIcon.icns"

# ── Sparkle ───────────────────────────────────────────────────────────────
# SwiftPM drops Sparkle.framework next to the built binary. The executable
# links it via @rpath, so it goes in Contents/Frameworks and we add the
# matching rpath.
echo "▸ embedding Sparkle.framework"
cp -R "${BIN_DIR}/Sparkle.framework" "${APP_DIR}/Contents/Frameworks/"

# SwiftPM bakes in an rpath pointing at the local toolchain directory. Shipping
# a machine-specific search path is both useless and a dylib-hijack surface.
while read -r rpath; do
    case "${rpath}" in
        @*|/usr/lib/swift) ;;
        *) install_name_tool -delete_rpath "${rpath}" "${APP_DIR}/Contents/MacOS/${APP_NAME}" 2>/dev/null || true ;;
    esac
done < <(otool -l "${APP_DIR}/Contents/MacOS/${APP_NAME}" | awk '/LC_RPATH/{f=1} f&&/ path /{print $2; f=0}')

install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "${APP_DIR}/Contents/MacOS/${APP_NAME}"

# ── ASR sidecar ───────────────────────────────────────────────────────────
# Helper executables belong in Contents/MacOS. A Mach-O binary under
# Contents/Resources makes codesign treat the bundle as malformed.
cp RustSidecar/target/release/macvibe-asr "${APP_DIR}/Contents/MacOS/"
mkdir -p "${APP_DIR}/Contents/Resources/asr-sidecar"
cp RustSidecar/setup_model.sh "${APP_DIR}/Contents/Resources/asr-sidecar/"
chmod +x "${APP_DIR}/Contents/Resources/asr-sidecar/setup_model.sh"

# Optionally embed the whisper model. Off by default: releases ship without it
# and ModelManager fetches it on first launch.
MODEL_DIR_SRC="$(pwd)/RustSidecar/models"
MODEL_DIR_DST="${APP_DIR}/Contents/Resources/asr-sidecar/models"
if [[ "${EMBED_MODEL:-0}" == "1" ]]; then
    if ! compgen -G "${MODEL_DIR_SRC}/ggml-*.bin" >/dev/null; then
        echo "✗ EMBED_MODEL=1 but no model in ${MODEL_DIR_SRC}." >&2
        echo "  Run RustSidecar/setup_model.sh first." >&2
        exit 1
    fi
    mkdir -p "${MODEL_DIR_DST}"
    cp "${MODEL_DIR_SRC}"/ggml-*.bin "${MODEL_DIR_DST}/"
    echo "  (embedded whisper model — bundle is self-contained)"
fi

# ── signing ───────────────────────────────────────────────────────────────
# Inside out: nested code first, container last. `--deep` is deprecated by
# Apple and applies the wrong entitlements to nested binaries, so we walk the
# bundle explicitly.
echo "▸ codesign"

# Sparkle ships its own helpers, each of which is a separate signable unit.
SPARKLE_FW="${APP_DIR}/Contents/Frameworks/Sparkle.framework"
codesign "${CODESIGN_FLAGS[@]}" "${SPARKLE_FW}/Versions/B/XPCServices/Installer.xpc"
codesign "${CODESIGN_FLAGS[@]}" "${SPARKLE_FW}/Versions/B/XPCServices/Downloader.xpc"
codesign "${CODESIGN_FLAGS[@]}" "${SPARKLE_FW}/Versions/B/Autoupdate"
codesign "${CODESIGN_FLAGS[@]}" "${SPARKLE_FW}/Versions/B/Updater.app"
codesign "${CODESIGN_FLAGS[@]}" "${SPARKLE_FW}"

# The sidecar is a plain executable, not a bundle — it gets the same hardened
# runtime treatment but no entitlements of its own; it neither records audio
# nor drives other apps.
codesign "${CODESIGN_FLAGS[@]}" "${APP_DIR}/Contents/MacOS/macvibe-asr"

codesign "${CODESIGN_FLAGS[@]}" --entitlements "${ENTITLEMENTS}" "${APP_DIR}"

echo "▸ verifying"
codesign --verify --strict --verbose=2 "${APP_DIR}" 2>&1 | sed 's/^/  /'

echo "✓ built ${APP_DIR} — ${VERSION} (${BUILD_NUMBER})"

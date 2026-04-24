#!/usr/bin/env bash
# Builds a self-contained MacVibe.app (whisper model embedded) and installs it
# to ~/Applications. Replaces any previous install.
#
# Override the destination with: INSTALL_DIR=/Applications ./install.sh
set -euo pipefail

cd "$(dirname "$0")"

INSTALL_DIR="${INSTALL_DIR:-${HOME}/Applications}"
APP_NAME="MacVibe"
DEST="${INSTALL_DIR}/${APP_NAME}.app"

# Ensure a whisper model is downloaded before we try to embed it.
if ! compgen -G "RustSidecar/models/ggml-*.bin" >/dev/null; then
    echo "▸ no whisper model present; running setup_model.sh"
    ./RustSidecar/setup_model.sh
fi

echo "▸ building self-contained bundle"
EMBED_MODEL=1 ./build.sh

# Stop any running instance so we can replace the bundle on disk.
if pgrep -f "${APP_NAME}.app/Contents/MacOS/${APP_NAME}" >/dev/null; then
    echo "▸ stopping running ${APP_NAME}"
    osascript -e "tell application \"${APP_NAME}\" to quit" 2>/dev/null || true
    pkill -f "${APP_NAME}.app/Contents/MacOS/${APP_NAME}" 2>/dev/null || true
    pkill -f "macvibe-asr" 2>/dev/null || true
    sleep 1
fi

mkdir -p "${INSTALL_DIR}"
echo "▸ installing to ${DEST}"
rm -rf "${DEST}"
cp -R "build/${APP_NAME}.app" "${DEST}"

# Strip the quarantine attribute that LaunchServices stamps on apps copied
# from anywhere "downloaded" — keeps macOS from showing the Gatekeeper prompt
# on first launch of an ad-hoc-signed bundle.
xattr -dr com.apple.quarantine "${DEST}" 2>/dev/null || true

echo
echo "✓ installed: ${DEST}"
echo
echo "Heads-up:"
echo "  • Ad-hoc code signature changes on every rebuild, so macOS treats each"
echo "    install as a new app. You'll need to re-grant Accessibility +"
echo "    Microphone in System Settings → Privacy & Security after upgrading."
echo "  • Remove any older MacVibe entries from those lists first to avoid"
echo "    confusion with stale signatures."
echo
echo "Launch with:  open '${DEST}'"

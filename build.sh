#!/usr/bin/env bash
# Builds MacVibe.app from the SwiftPM target and assembles a bundle with the
# Python sidecar placed in Contents/Resources/python-sidecar.
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${CONFIG:-release}"
APP_NAME="MacVibe"
APP_DIR="build/${APP_NAME}.app"

echo "▸ cargo build --release (whisper.cpp sidecar)"
( cd RustSidecar && cargo build --release ) >/dev/null

echo "▸ swift build (-c ${CONFIG})"
swift build -c "${CONFIG}" --product "${APP_NAME}"

BIN_PATH="$(swift build -c "${CONFIG}" --show-bin-path)/${APP_NAME}"
if [[ ! -f "${BIN_PATH}" ]]; then
    echo "✗ binary not found at ${BIN_PATH}" >&2
    exit 1
fi

echo "▸ assembling ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "${BIN_PATH}"           "${APP_DIR}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist    "${APP_DIR}/Contents/Info.plist"

# Bundle the Rust ASR sidecar binary + setup script.
mkdir -p "${APP_DIR}/Contents/Resources/asr-sidecar"
cp RustSidecar/target/release/macvibe-asr "${APP_DIR}/Contents/Resources/asr-sidecar/"
cp RustSidecar/setup_model.sh             "${APP_DIR}/Contents/Resources/asr-sidecar/"
chmod +x "${APP_DIR}/Contents/Resources/asr-sidecar/setup_model.sh"

# Place the whisper model. Two modes:
#   EMBED_MODEL=1  — copy the actual .bin files into the bundle (self-contained,
#                    suitable for ~/Applications install — adds ~1.6 GB to bundle).
#   default        — symlink the source tree's models dir so dev rebuilds don't
#                    duplicate the file. The symlinked bundle ONLY works while
#                    the source tree exists at this path.
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
elif compgen -G "${MODEL_DIR_SRC}/ggml-*.bin" >/dev/null; then
    ln -sfn "${MODEL_DIR_SRC}" "${MODEL_DIR_DST}"
    echo "  (linked source whisper model for dev use)"
else
    mkdir -p "${MODEL_DIR_DST}"
fi

echo "▸ ad-hoc codesign"
codesign --force --deep \
    --sign - \
    --entitlements Resources/MacVibe.entitlements \
    "${APP_DIR}"

echo "✓ built ${APP_DIR}"
echo
echo "Next steps:"
echo "  1. (first time only) Download whisper model:"
echo "       ${APP_DIR}/Contents/Resources/asr-sidecar/setup_model.sh"
echo "  2. Run: open ${APP_DIR}"
echo "  3. Grant Accessibility + Microphone in System Settings when prompted."
echo "     Note: rebuilds change the code signature → re-grant Accessibility."

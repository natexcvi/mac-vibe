#!/usr/bin/env bash
# Downloads a whisper.cpp GGML model into RustSidecar/models/.
# Default: ggml-large-v3-turbo (1.6 GB, ~best speed/accuracy on Apple Silicon).
# Override with: MODEL=ggml-base.en ./setup_model.sh
set -euo pipefail

cd "$(dirname "$0")"

MODEL="${MODEL:-ggml-large-v3-turbo}"
URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${MODEL}.bin"
DEST_DIR="models"
DEST="${DEST_DIR}/${MODEL}.bin"

mkdir -p "${DEST_DIR}"
if [[ -f "${DEST}" ]]; then
    echo "✔ ${DEST} already present"
    exit 0
fi

echo "▸ downloading ${MODEL} from HuggingFace…"
curl -L --fail --progress-bar -o "${DEST}.tmp" "${URL}"
mv "${DEST}.tmp" "${DEST}"
echo "✔ saved ${DEST} ($(du -h "${DEST}" | cut -f1))"

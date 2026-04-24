#!/usr/bin/env bash
# Creates a .venv inside PythonSidecar/ with the dependencies needed to run
# transcribe.py. Uses uv if available (much faster), otherwise plain venv+pip.
set -euo pipefail

cd "$(dirname "$0")"

# Apple Silicon requires an arm64 Python; /usr/local/opt python@3.11 on some
# boxes is x86_64. Prefer /opt/homebrew's python@3.12, else let uv pick one.
PYTHON_BIN="${MACVIBE_PYTHON:-}"
if [[ -z "${PYTHON_BIN}" ]] && [[ -x /opt/homebrew/opt/python@3.12/libexec/bin/python3 ]]; then
    PYTHON_BIN=/opt/homebrew/opt/python@3.12/libexec/bin/python3
fi

if [[ ! -d .venv ]]; then
    if command -v uv >/dev/null 2>&1; then
        if [[ -n "${PYTHON_BIN}" ]]; then
            uv venv .venv --python "${PYTHON_BIN}"
        else
            uv venv .venv --python 3.12
        fi
    else
        "${PYTHON_BIN:-python3}" -m venv .venv
    fi
fi

# shellcheck disable=SC1091
source .venv/bin/activate

if command -v uv >/dev/null 2>&1; then
    uv pip install -r requirements.txt
else
    pip install --upgrade pip
    pip install -r requirements.txt
fi

# VibeVoice's official loader lives in its repo; install it on top of the
# transformers base so we can use the native classes when available. Use the
# venv's pip explicitly (system pip is PEP 668 externally-managed).
VENV_PIP=".venv/bin/pip"
if ! .venv/bin/python -c "import vibevoice" 2>/dev/null; then
    if command -v uv >/dev/null 2>&1; then
        uv pip install "git+https://github.com/microsoft/VibeVoice.git" || true
    else
        "${VENV_PIP}" install "git+https://github.com/microsoft/VibeVoice.git" || true
    fi
fi

echo "✔ PythonSidecar venv ready"

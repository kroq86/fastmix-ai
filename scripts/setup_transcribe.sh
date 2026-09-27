#!/usr/bin/env bash
# One-time setup of the Python worker used for automatic stem transcription.
# Creates .venv-transcribe/ (Python 3.11: basic-pitch 0.4.0 needs <=3.11 wheels).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
uv venv -p 3.11 "$ROOT/.venv-transcribe"
VIRTUAL_ENV="$ROOT/.venv-transcribe" uv pip install -r "$ROOT/tools/transcribe/requirements.txt"
"$ROOT/.venv-transcribe/bin/python" -c "import basic_pitch; print('transcribe worker ready')"

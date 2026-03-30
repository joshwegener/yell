#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL_CHECKSUMS_FILE="${MODEL_CHECKSUMS_FILE:-$SCRIPT_DIR/model-checksums.sh}"
source "$MODEL_CHECKSUMS_FILE"

MODEL_DIR="${MODEL_DIR:-$HOME/.yell/models}"
BASE_URL="${BASE_URL:-https://huggingface.co/ggerganov/whisper.cpp/resolve/main}"
CURL_BIN="${CURL_BIN:-curl}"
DEFAULT_MODELS=(
    "ggml-tiny.en.bin"
    "ggml-base.en.bin"
    "ggml-small.en.bin"
)

mkdir -p "$MODEL_DIR"

download_if_missing() {
    local name="$1"
    local path="$MODEL_DIR/$name"
    local expected_checksum=""

    if ! expected_checksum="$(model_checksum_for "$name")"; then
        if [ -f "$path" ]; then
            echo "No checksum is defined for $name, keeping the existing file." >&2
            return
        fi

        echo "No checksum is defined for $name" >&2
        return 1
    fi

    if [ -f "$path" ]; then
        if model_checksum_matches "$path" "$name"; then
            echo "$name already exists, skipping."
            return
        fi

        echo "$name exists but failed checksum validation, re-downloading..." >&2
        rm -f "$path"
    fi

    echo "Downloading $name..."
    local tmp_path="$path.download"
    rm -f "$tmp_path"
    local curl_progress="--no-progress-meter"
    if [ -t 2 ]; then
        curl_progress="--progress-bar"
    fi
    "$CURL_BIN" -fL --retry 3 "$curl_progress" -o "$tmp_path" "$BASE_URL/$name"
    if ! model_checksum_matches "$tmp_path" "$name"; then
        rm -f "$tmp_path"
        echo "$name failed checksum validation after download (expected $expected_checksum)." >&2
        return 1
    fi
    mv "$tmp_path" "$path"
    echo "Downloaded to $path"
}

MODELS=("$@")
if [ "${#MODELS[@]}" -eq 0 ]; then
    MODELS=("${DEFAULT_MODELS[@]}")
fi

for model in "${MODELS[@]}"; do
    download_if_missing "$model"
done

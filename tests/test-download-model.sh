#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_file_matches() {
    local actual="$1"
    local expected="$2"
    cmp -s "$actual" "$expected" || fail "$actual did not match $expected"
}

assert_equals() {
    local expected="$1"
    local actual="$2"
    [ "$expected" = "$actual" ] || fail "expected '$expected', got '$actual'"
}

FIXTURE_PATH="$TMP_DIR/fixture.bin"
printf 'fixture whisper model\n' > "$FIXTURE_PATH"
FIXTURE_SHA="$(shasum -a 256 "$FIXTURE_PATH" | awk '{print $1}')"

cat > "$TMP_DIR/model-checksums.sh" <<EOF
#!/bin/bash
model_checksum_for() {
    case "\$1" in
        ggml-tiny.en.bin)
            echo "$FIXTURE_SHA"
            ;;
        *)
            return 1
            ;;
    esac
}

model_checksum_matches() {
    local path="\$1"
    local name="\$2"
    local expected actual

    expected="\$(model_checksum_for "\$name")" || return 1
    actual="\$(shasum -a 256 "\$path" | awk '{print \$1}')"
    [ "\$actual" = "\$expected" ]
}
EOF
chmod +x "$TMP_DIR/model-checksums.sh"

CURL_COUNT_FILE="$TMP_DIR/curl-count.txt"
cat > "$TMP_DIR/fake-curl.sh" <<'EOF'
#!/bin/bash
set -euo pipefail

out=""
url=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -fL|-Lf)
            shift
            ;;
        -o|--output)
            out="$2"
            shift 2
            ;;
        --retry)
            shift 2
            ;;
        -f|-L|--no-progress-meter|--progress-bar)
            shift
            ;;
        *)
            url="$1"
            shift
            ;;
    esac
done

[ -n "$out" ] || exit 1
count=0
if [ -f "$TEST_CURL_COUNT_FILE" ]; then
    count="$(cat "$TEST_CURL_COUNT_FILE")"
fi
printf '%s' "$((count + 1))" > "$TEST_CURL_COUNT_FILE"
printf '%s\n' "$url" > "$TEST_CURL_URL_FILE"
cp "$TEST_FIXTURE_PATH" "$out"
EOF
chmod +x "$TMP_DIR/fake-curl.sh"

MODEL_DIR="$TMP_DIR/models"
COMMON_ENV=(
    "MODEL_DIR=$MODEL_DIR"
    "MODEL_CHECKSUMS_FILE=$TMP_DIR/model-checksums.sh"
    "CURL_BIN=$TMP_DIR/fake-curl.sh"
    "BASE_URL=https://example.invalid/models"
    "TEST_FIXTURE_PATH=$FIXTURE_PATH"
    "TEST_CURL_COUNT_FILE=$CURL_COUNT_FILE"
    "TEST_CURL_URL_FILE=$TMP_DIR/curl-url.txt"
)

env "${COMMON_ENV[@]}" "$REPO_DIR/download-model.sh" ggml-tiny.en.bin
assert_file_matches "$MODEL_DIR/ggml-tiny.en.bin" "$FIXTURE_PATH"
assert_equals "1" "$(cat "$CURL_COUNT_FILE")"
assert_equals "https://example.invalid/models/ggml-tiny.en.bin" "$(cat "$TMP_DIR/curl-url.txt")"

env "${COMMON_ENV[@]}" "$REPO_DIR/download-model.sh" ggml-tiny.en.bin
assert_equals "1" "$(cat "$CURL_COUNT_FILE")"

printf 'corrupt cache\n' > "$MODEL_DIR/ggml-tiny.en.bin"
env "${COMMON_ENV[@]}" "$REPO_DIR/download-model.sh" ggml-tiny.en.bin
assert_file_matches "$MODEL_DIR/ggml-tiny.en.bin" "$FIXTURE_PATH"
assert_equals "2" "$(cat "$CURL_COUNT_FILE")"

UNKNOWN_PATH="$MODEL_DIR/ggml-large.bin"
printf 'keep me\n' > "$UNKNOWN_PATH"
env "${COMMON_ENV[@]}" "$REPO_DIR/download-model.sh" ggml-large.bin
assert_file_matches "$UNKNOWN_PATH" <(printf 'keep me\n')

set +e
unknown_output="$(env "${COMMON_ENV[@]}" "$REPO_DIR/download-model.sh" ggml-large-v3.bin 2>&1)"
unknown_status=$?
set -e
assert_equals "1" "$unknown_status"
printf '%s' "$unknown_output" | grep -q "No checksum is defined for ggml-large-v3.bin" || fail "missing checksum error for unknown model"

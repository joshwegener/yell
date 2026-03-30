#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/model-checksums.sh"

APP_NAME="Yell"
BUILD_DIR="build"
WHISPER_DIR="vendor/whisper.cpp"
WHISPER_BUILD="$WHISPER_DIR/build"
WHISPER_REPO_URL="https://github.com/ggml-org/whisper.cpp.git"
WHISPER_REF="${WHISPER_REF:-v1.8.4}"
SDK="$(xcrun --show-sdk-path 2>/dev/null || echo /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk)"

resolve_app_versions() {
    GIT_SHA="$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
    BUILD_VERSION="${BUILD_VERSION:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

    if [ -z "${APP_VERSION:-}" ]; then
        local exact_tag latest_tag
        exact_tag="$(git describe --tags --exact-match 2>/dev/null || true)"
        latest_tag="$(git describe --tags --abbrev=0 2>/dev/null || true)"
        if [ -n "$exact_tag" ]; then
            APP_VERSION="${exact_tag#v}"
        elif [ -n "$latest_tag" ]; then
            APP_VERSION="${latest_tag#v}"
        else
            APP_VERSION="0.0.0"
        fi
    fi
}

ensure_whisper_checkout() {
    if [ -d "$WHISPER_DIR" ] && [ ! -d "$WHISPER_DIR/.git" ]; then
        echo "Expected $WHISPER_DIR to be a git checkout" >&2
        exit 1
    fi

    if [ ! -d "$WHISPER_DIR" ]; then
        echo "Cloning whisper.cpp $WHISPER_REF..."
        git clone --depth 1 --branch "$WHISPER_REF" "$WHISPER_REPO_URL" "$WHISPER_DIR"
    fi

    local target_commit current_commit
    if target_commit="$(git -C "$WHISPER_DIR" rev-parse --verify "$WHISPER_REF^{commit}" 2>/dev/null)"; then
        echo "Using local whisper.cpp ref $WHISPER_REF..."
    else
        echo "Fetching whisper.cpp $WHISPER_REF..."
        git -C "$WHISPER_DIR" fetch --depth 1 origin "$WHISPER_REF"
        target_commit="$(git -C "$WHISPER_DIR" rev-parse FETCH_HEAD)"
    fi
    current_commit="$(git -C "$WHISPER_DIR" rev-parse HEAD 2>/dev/null || true)"

    if [ "$current_commit" != "$target_commit" ]; then
        echo "Checking out whisper.cpp $WHISPER_REF ($target_commit)..."
        git -C "$WHISPER_DIR" checkout --detach "$target_commit"
        rm -rf "$WHISPER_BUILD"
    fi

    echo "Using whisper.cpp $WHISPER_REF ($(git -C "$WHISPER_DIR" rev-parse --short HEAD))"
}

resolve_app_versions
ensure_whisper_checkout

echo "Configuring whisper.cpp..."
(
    cd "$WHISPER_DIR"
    cmake -B build \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
        -DCMAKE_OSX_SYSROOT="$SDK" \
        -DBUILD_SHARED_LIBS=OFF \
        -DWHISPER_BUILD_EXAMPLES=OFF \
        -DWHISPER_BUILD_TESTS=OFF \
        -DGGML_METAL=ON \
        -DGGML_ACCELERATE=ON \
        -DGGML_NATIVE=OFF
    cmake --build build --config Release -j"$(sysctl -n hw.ncpu)"
)

echo "Compiling $APP_NAME $APP_VERSION ($BUILD_VERSION / $GIT_SHA)..."
mkdir -p "$BUILD_DIR"

swiftc \
    -O \
    -whole-module-optimization \
    -target arm64-apple-macosx14.0 \
    -sdk "$SDK" \
    -I include \
    -I "$WHISPER_DIR/include" \
    -I "$WHISPER_DIR/ggml/include" \
    -L "$WHISPER_BUILD/src" \
    -L "$WHISPER_BUILD/ggml/src" \
    -L "$WHISPER_BUILD/ggml/src/ggml-blas" \
    -L "$WHISPER_BUILD/ggml/src/ggml-metal" \
    -lwhisper \
    -lggml \
    -lggml-base \
    -lggml-cpu \
    -lggml-blas \
    -lggml-metal \
    -framework AppKit \
    -framework AVFoundation \
    -framework CoreGraphics \
    -framework Accelerate \
    -framework Carbon \
    -framework Metal \
    -framework MetalKit \
    -framework Foundation \
    -lc++ \
    Sources/*.swift \
    -o "$BUILD_DIR/$APP_NAME"

echo "Creating app bundle..."
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Bundle tiny.en model
TINY_MODEL="$HOME/.yell/models/ggml-tiny.en.bin"
if [ -f "$TINY_MODEL" ]; then
    if ! model_checksum_matches "$TINY_MODEL" "ggml-tiny.en.bin"; then
        echo "Invalid ggml-tiny.en.bin checksum at $TINY_MODEL — run ./download-model.sh ggml-tiny.en.bin" >&2
        exit 1
    fi
    echo "Bundling ggml-tiny.en.bin..."
    cp "$TINY_MODEL" "$APP_BUNDLE/Contents/Resources/ggml-tiny.en.bin"
else
    echo "⚠️  tiny.en model not found at $TINY_MODEL — run ./download-model.sh first"
fi

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Yell</string>
    <key>CFBundleIdentifier</key>
    <string>com.yell.app</string>
    <key>CFBundleName</key>
    <string>Yell</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Yell needs microphone access to record audio for transcription.</string>
    <key>YellGitCommit</key>
    <string>$GIT_SHA</string>
    <key>YellWhisperRef</key>
    <string>$WHISPER_REF</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP_BUNDLE"

echo ""
echo "✅ Built $APP_BUNDLE"
echo ""
echo "To run:  open $APP_BUNDLE"

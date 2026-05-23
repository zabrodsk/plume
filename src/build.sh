#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Plume"
BIN_NAME="Plume"
APP="${APP_NAME}.app"
CONTENTS="${APP}/Contents"
MACOS="${CONTENTS}/MacOS"
RES="${CONTENTS}/Resources"
FRAMEWORKS="${CONTENTS}/Frameworks"
SPARKLE_VERSION="2.9.1"
SPARKLE_CACHE="../.build/sparkle-${SPARKLE_VERSION}"
SPARKLE_FRAMEWORK="${SPARKLE_CACHE}/Sparkle.framework"

ensure_sparkle() {
    if [ -d "${SPARKLE_FRAMEWORK}" ]; then
        return
    fi

    echo "→ fetching Sparkle ${SPARKLE_VERSION}..."
    rm -rf "${SPARKLE_CACHE}"
    mkdir -p "${SPARKLE_CACHE}"
    local archive="${SPARKLE_CACHE}/Sparkle-${SPARKLE_VERSION}.tar.xz"
    curl -L "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz" \
        -o "${archive}"
    tar -xf "${archive}" -C "${SPARKLE_CACHE}"
}

ensure_sparkle

# Generate icon
echo "→ rendering icon..."
swift icon.swift
iconutil -c icns AppIcon.iconset -o AppIcon.icns
rm -rf AppIcon.iconset

# Compile
rm -rf "${APP}"
mkdir -p "${MACOS}" "${RES}" "${FRAMEWORKS}"

echo "→ compiling Swift (universal arm64 + x86_64)..."
SWIFT_SOURCES=(main.swift sshio.swift)
SWIFT_FLAGS=(-O -F "${SPARKLE_CACHE}" -framework Sparkle -Xlinker -rpath -Xlinker "@executable_path/../Frameworks")
swiftc -target arm64-apple-macos12 "${SWIFT_FLAGS[@]}" "${SWIFT_SOURCES[@]}" -o "${MACOS}/${BIN_NAME}-arm64"
swiftc -target x86_64-apple-macos12 "${SWIFT_FLAGS[@]}" "${SWIFT_SOURCES[@]}" -o "${MACOS}/${BIN_NAME}-x86_64" 2>/dev/null || {
    echo "  (x86_64 unavailable — Apple Silicon only)"
    mv "${MACOS}/${BIN_NAME}-arm64" "${MACOS}/${BIN_NAME}"
    rm -f "${MACOS}/${BIN_NAME}-x86_64"
}

if [ -f "${MACOS}/${BIN_NAME}-arm64" ] && [ -f "${MACOS}/${BIN_NAME}-x86_64" ]; then
    echo "→ lipo'ing universal binary..."
    lipo -create "${MACOS}/${BIN_NAME}-arm64" "${MACOS}/${BIN_NAME}-x86_64" \
         -output "${MACOS}/${BIN_NAME}"
    rm -f "${MACOS}/${BIN_NAME}-arm64" "${MACOS}/${BIN_NAME}-x86_64"
fi
chmod +x "${MACOS}/${BIN_NAME}"

# Bundle
echo "→ bundling resources..."
cp Info.plist "${CONTENTS}/Info.plist"
cp index.html "${RES}/index.html"
cp AppIcon.icns "${RES}/AppIcon.icns"
# Vendored markdown renderer stack (v3.1+).
cp -R preview "${RES}/preview"
ditto "${SPARKLE_FRAMEWORK}" "${FRAMEWORKS}/Sparkle.framework"
rm -f AppIcon.icns

# Ad-hoc sign so Gatekeeper doesn't quarantine it locally.
echo "→ ad-hoc signing..."
codesign --force --deep --sign - "${APP}" >/dev/null 2>&1 || \
    echo "  (codesign failed — app will still run locally)"

echo
echo "✓ Built: $(pwd)/${APP}"

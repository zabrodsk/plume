#!/usr/bin/env bash
#
# Plume — release pipeline.
#
# Builds the universal app via src/build.sh, re-signs with Developer ID +
# hardened runtime, packages into Plume.dmg, signs the .dmg, notarizes,
# and staples the ticket. Also produces Plume.zip for back-compat with
# the existing README link.
#
# Prerequisites (one-time):
#   1. Developer ID Application certificate in login Keychain.
#   2. Notary credentials profile "mach-notary" in login Keychain
#      (xcrun notarytool store-credentials mach-notary --apple-id … --team-id …).
#
# Usage: ./dist/release.sh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="${PROJECT_DIR}/src"
DIST_DIR="${PROJECT_DIR}/dist"
APP_NAME="Plume"
APP_PATH="${SRC_DIR}/${APP_NAME}.app"
TEAM_ID="GT2SGCCN5R"
SIGN_IDENTITY="Developer ID Application: Dusan Zabrodsky (${TEAM_ID})"
NOTARY_PROFILE="${NOTARY_PROFILE:-mach-notary}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${SRC_DIR}/Info.plist")"

DMG_PATH="${DIST_DIR}/${APP_NAME}.dmg"
ZIP_PATH="${DIST_DIR}/${APP_NAME}.zip"
SPARKLE_VERSION="2.9.1"
SPARKLE_CACHE="${PROJECT_DIR}/.build/sparkle-${SPARKLE_VERSION}"
SPARKLE_APPCAST_DIR="${DIST_DIR}/sparkle-appcast"

bold() { printf "\033[1m%s\033[0m\n" "$1"; }
fail() { printf "\033[31mERROR:\033[0m %s\n" "$1" >&2; exit 1; }

bold "==> Preflight"
security find-identity -v -p codesigning | grep -q "${SIGN_IDENTITY}" \
  || fail "Signing identity not in Keychain:
       ${SIGN_IDENTITY}"
xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" >/dev/null 2>&1 \
  || fail "Notary profile '${NOTARY_PROFILE}' missing.
       Fix: xcrun notarytool store-credentials ${NOTARY_PROFILE} --apple-id <id> --team-id ${TEAM_ID}"

mkdir -p "${DIST_DIR}"
rm -f "${DMG_PATH}" "${ZIP_PATH}"

bold "==> Build (universal binary, ad-hoc, via src/build.sh)"
(cd "${SRC_DIR}" && ./build.sh)
[ -d "${APP_PATH}" ] || fail "Expected ${APP_PATH}, not built"

bold "==> Re-sign with Developer ID + hardened runtime"
if [ -d "${APP_PATH}/Contents/Frameworks/Sparkle.framework" ]; then
  codesign --force --deep --options=runtime --timestamp \
    --sign "${SIGN_IDENTITY}" "${APP_PATH}/Contents/Frameworks/Sparkle.framework"
fi
codesign --force --options=runtime --timestamp \
  --sign "${SIGN_IDENTITY}" "${APP_PATH}"
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"

bold "==> Build .dmg (drag-to-Applications layout)"
DMG_STAGING="${DIST_DIR}/dmg-staging"
rm -rf "${DMG_STAGING}"
mkdir -p "${DMG_STAGING}"
cp -R "${APP_PATH}" "${DMG_STAGING}/"
ln -s /Applications "${DMG_STAGING}/Applications"
hdiutil create -volname "${APP_NAME}" -srcfolder "${DMG_STAGING}" \
  -ov -format UDZO "${DMG_PATH}"

bold "==> Sign .dmg"
codesign --sign "${SIGN_IDENTITY}" --timestamp "${DMG_PATH}"

bold "==> Submit to Apple notary service (1-5 min)"
xcrun notarytool submit "${DMG_PATH}" \
  --keychain-profile "${NOTARY_PROFILE}" --wait

bold "==> Staple notarization ticket"
xcrun stapler staple "${DMG_PATH}"
xcrun stapler validate "${DMG_PATH}"

bold "==> Verify Gatekeeper acceptance"
spctl --assess --type open --context context:primary-signature -v "${DMG_PATH}"

bold "==> Build .zip (back-compat for existing README link)"
(cd "${SRC_DIR}" && zip -r -q "${ZIP_PATH}" "${APP_NAME}.app")

bold "==> Generate Sparkle appcast"
rm -rf "${SPARKLE_APPCAST_DIR}"
mkdir -p "${SPARKLE_APPCAST_DIR}"
cp "${DMG_PATH}" "${SPARKLE_APPCAST_DIR}/"
cat > "${SPARKLE_APPCAST_DIR}/${APP_NAME}.md" <<NOTES
## Plume ${VERSION}

Patch: opening a markdown file from Finder no longer spawns two windows.

### Fix

- **Launch-via-file**: double-clicking a \`.md\` file in Finder used to create *two* windows (an empty Untitled and another holding the opened file). macOS delivers the file-open event during the launch sequence, before \`applicationDidFinishLaunching\` runs — Plume's launch handler then created its own window unaware that one already existed. Now there's a single source of truth for launch-time window creation, and any pending file URL lands as a tab in that window (or in a tab inside a restored window when state restoration is on).

### From 3.1.0/3.1.1 (still applies)

Plume opens **multiple files at once** with \`⌘T\` (tabs) and \`⌘N\` (windows), and toggles a **rendered Markdown preview** with \`⌘E\` — headings, code with syntax highlighting, tables, footnotes, task lists, LaTeX math. Open windows and unsaved drafts come back on relaunch.
NOTES
"${SPARKLE_CACHE}/bin/generate_appcast" \
  --download-url-prefix "https://github.com/zabrodsk/plume/releases/download/v${VERSION}/" \
  --embed-release-notes \
  --maximum-versions 0 \
  "${SPARKLE_APPCAST_DIR}"
cp "${SPARKLE_APPCAST_DIR}/appcast.xml" "${PROJECT_DIR}/appcast.xml"

echo ""
bold "✅ Released"
printf "   DMG: %s (%s)\n" "${DMG_PATH}" "$(du -h "${DMG_PATH}" | cut -f1)"
printf "   ZIP: %s (%s)\n" "${ZIP_PATH}" "$(du -h "${ZIP_PATH}" | cut -f1)"
printf "   Appcast: %s\n" "${PROJECT_DIR}/appcast.xml"

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

DMG_PATH="${DIST_DIR}/${APP_NAME}.dmg"
ZIP_PATH="${DIST_DIR}/${APP_NAME}.zip"

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

echo ""
bold "✅ Released"
printf "   DMG: %s (%s)\n" "${DMG_PATH}" "$(du -h "${DMG_PATH}" | cut -f1)"
printf "   ZIP: %s (%s)\n" "${ZIP_PATH}" "$(du -h "${ZIP_PATH}" | cut -f1)"

#!/usr/bin/env bash
# Release-build Soundcore Manager for macOS and package a .dmg with hdiutil.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="soundcore-manager"
DISPLAY_NAME="Soundcore Manager"
RELEASE_APP="build/macos/Build/Products/Release/${DISPLAY_NAME}.app"
DIST_DIR="${ROOT}/dist"
VERSION="$(
  # pubspec: version: 1.0.0+1 → 1.0.0
  grep -E '^version:' pubspec.yaml | head -1 | sed -E 's/^version:[[:space:]]*//; s/\+.*//; s/[[:space:]]//g'
)"
VERSION="${VERSION:-0.0.0}"
STAGING="${DIST_DIR}/.dmg-staging"
DMG_RW="${DIST_DIR}/${APP_NAME}-${VERSION}-rw.dmg"
DMG_OUT="${DIST_DIR}/${APP_NAME}-${VERSION}-macos.dmg"
VOL_NAME="${DISPLAY_NAME}"

usage() {
  cat <<'EOF'
Usage: scripts/build-dmg.sh [options]

  Release-build Soundcore Manager for macOS and create a compressed DMG.

Options:
  --skip-build   Reuse existing Release .app (do not flutter build)
  --open         Open the finished DMG in Finder
  -h, --help     Show this help

Output:
  dist/soundcore-manager-<version>-macos.dmg
EOF
}

SKIP_BUILD=0
OPEN_DMG=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build) SKIP_BUILD=1 ;;
    --open)       OPEN_DMG=1 ;;
    -h|--help)    usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

if ! command -v flutter >/dev/null 2>&1; then
  echo "error: flutter not found in PATH" >&2
  exit 1
fi
if ! command -v hdiutil >/dev/null 2>&1; then
  echo "error: hdiutil not found (macOS only)" >&2
  exit 1
fi

echo "==> Project: $ROOT"
echo "==> Version: $VERSION"
echo "==> Output:  $DMG_OUT"

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  echo "==> flutter pub get"
  flutter pub get
  echo "==> flutter build macos --release"
  flutter build macos --release
else
  echo "==> Skipping build (--skip-build)"
fi

if [[ ! -d "$RELEASE_APP" ]]; then
  echo "error: release app not found: $RELEASE_APP" >&2
  echo "       run without --skip-build first" >&2
  exit 1
fi

echo "==> Staging DMG contents"
rm -rf "$STAGING" "$DMG_RW" "$DMG_OUT"
mkdir -p "$STAGING" "$DIST_DIR"

# Copy .app (preserve symlinks / resource forks as much as possible)
ditto "$RELEASE_APP" "${STAGING}/${DISPLAY_NAME}.app"

# Applications symlink for drag-install UX
ln -s /Applications "${STAGING}/Applications"

# Rough size: app size + padding (MB)
APP_KB="$(du -sk "$STAGING" | awk '{print $1}')"
SIZE_MB=$(( APP_KB / 1024 + 50 ))
if [[ "$SIZE_MB" -lt 80 ]]; then
  SIZE_MB=80
fi

echo "==> Creating RW image (${SIZE_MB}MB)"
hdiutil create \
  -volname "$VOL_NAME" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDRW \
  -size "${SIZE_MB}m" \
  "$DMG_RW" >/dev/null

echo "==> Compressing to UDZO"
hdiutil convert "$DMG_RW" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$DMG_OUT" >/dev/null

rm -f "$DMG_RW"
rm -rf "$STAGING"

echo "==> Done"
ls -lh "$DMG_OUT"
shasum -a 256 "$DMG_OUT" | awk '{print "    SHA-256:", $1}'

if [[ "$OPEN_DMG" -eq 1 ]]; then
  open -R "$DMG_OUT"
fi

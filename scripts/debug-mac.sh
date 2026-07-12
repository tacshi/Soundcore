#!/usr/bin/env bash
# Build and run Soundcore Manager for macOS in debug mode.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="Soundcore Manager"
DEBUG_APP="build/macos/Build/Products/Debug/${APP_NAME}.app"

usage() {
  cat <<'EOF'
Usage: scripts/debug-mac.sh [options]

  Debug build of Soundcore Manager for macOS.

Options:
  --build-only   Compile debug .app without launching
  --run          Build then flutter run -d macos (default)
  --open         Build then open the .app bundle directly
  -h, --help     Show this help

Examples:
  ./scripts/debug-mac.sh
  ./scripts/debug-mac.sh --build-only
  ./scripts/debug-mac.sh --open
EOF
}

MODE="run"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-only) MODE="build" ;;
    --run)        MODE="run" ;;
    --open)       MODE="open" ;;
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

echo "==> Project: $ROOT"
echo "==> Mode:    $MODE (debug / macOS)"
echo "==> flutter pub get"
flutter pub get

case "$MODE" in
  build)
    echo "==> flutter build macos --debug"
    flutter build macos --debug
    echo "==> Done: $ROOT/$DEBUG_APP"
    ;;
  open)
    echo "==> flutter build macos --debug"
    flutter build macos --debug
    if [[ ! -d "$DEBUG_APP" ]]; then
      echo "error: expected app not found: $DEBUG_APP" >&2
      exit 1
    fi
    echo "==> Opening $DEBUG_APP"
    open "$DEBUG_APP"
    ;;
  run)
    echo "==> flutter run -d macos --debug"
    flutter run -d macos --debug
    ;;
esac

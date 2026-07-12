#!/usr/bin/env bash
# Build and install Soundcore Manager on an iOS device using Xcode-managed signing.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE="${ROOT}/ios/Runner.xcworkspace"
TEAM_ID="X5X4TD477G"
CONFIGURATION="Release"
DEVICE_ID=""
DEVICE_NAME=""
LAUNCH=0

usage() {
  cat <<'EOF'
Usage: scripts/install-ios.sh [options]

Build Soundcore Manager using Xcode-managed iOS signing, then install it on a
connected physical iOS device.

Options:
  --debug          Build the Debug configuration (default: Release)
  --device UDID    Target a specific connected device
  --launch         Launch the app after installation
  -h, --help       Show this help
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "$1 not found in PATH"
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s\n' "$value"
}

select_device() {
  local output line id name
  output="$(mktemp)"

  printf '==> Discovering connected iOS devices\n'
  xcodebuild -workspace "$WORKSPACE" -scheme Runner -showdestinations >"$output"

  local -a ids=() names=()
  while IFS= read -r line; do
    [[ "$line" == *"platform:iOS"* ]] || continue
    [[ "$line" == *"Simulator"* || "$line" == *"placeholder"* ]] && continue
    id="$(trim "$(sed -E 's/.*id:([^,}]+).*/\1/' <<<"$line")")"
    name="$(trim "$(sed -E 's/.*name:([^,}]+).*/\1/' <<<"$line")")"
    [[ -n "$id" && -n "$name" ]] || continue
    ids+=("$id")
    names+=("$name")
  done <"$output"
  rm -f "$output"

  ((${#ids[@]} > 0)) || die "no connected physical iOS device found"

  if [[ -n "$DEVICE_ID" ]]; then
    for i in "${!ids[@]}"; do
      if [[ "${ids[$i]}" == "$DEVICE_ID" ]]; then
        DEVICE_NAME="${names[$i]}"
        printf '==> Device: %s (%s)\n' "$DEVICE_NAME" "$DEVICE_ID"
        return
      fi
    done
    die "device '$DEVICE_ID' is not connected"
  fi

  [[ -t 0 ]] || die "device selection requires an interactive terminal; pass --device UDID"

  printf 'Select a device:\n'
  for i in "${!ids[@]}"; do
    printf '  %d) %s (%s)\n' "$((i + 1))" "${names[$i]}" "${ids[$i]}"
  done

  local selection selected_index
  while true; do
    printf 'Enter selection [1-%d]: ' "${#ids[@]}"
    read -r selection

    [[ "$selection" =~ ^[0-9]+$ ]] || {
      printf 'Invalid selection.\n'
      continue
    }

    if ((selection >= 1 && selection <= ${#ids[@]})); then
      selected_index=$((selection - 1))
      DEVICE_ID="${ids[$selected_index]}"
      DEVICE_NAME="${names[$selected_index]}"
      printf '==> Device: %s (%s)\n' "$DEVICE_NAME" "$DEVICE_ID"
      return
    fi

    printf 'Invalid selection.\n'
  done
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug) CONFIGURATION="Debug" ;;
    --device)
      [[ $# -ge 2 ]] || die "--device requires a UDID"
      DEVICE_ID="$2"
      shift
      ;;
    --launch) LAUNCH=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

require_command flutter
require_command xcodebuild
require_command xcrun
[[ -d "$WORKSPACE" ]] || die "Xcode workspace not found: $WORKSPACE"

cd "$ROOT"
select_device

printf '==> Preparing Flutter iOS project\n'
flutter pub get
flutter build ios --config-only "--$(tr '[:upper:]' '[:lower:]' <<<"$CONFIGURATION")"

DERIVED_DATA="${ROOT}/build/ios/install"
printf '==> Building %s with automatic signing for team %s\n' "$CONFIGURATION" "$TEAM_ID"
xcodebuild \
  -workspace "$WORKSPACE" \
  -scheme Runner \
  -configuration "$CONFIGURATION" \
  -destination "id=${DEVICE_ID}" \
  -derivedDataPath "$DERIVED_DATA" \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  build

APP_PATH="${DERIVED_DATA}/Build/Products/${CONFIGURATION}-iphoneos/Runner.app"
[[ -d "$APP_PATH" ]] || die "built app not found: $APP_PATH"

printf '==> Installing Soundcore Manager\n'
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"

if [[ "$LAUNCH" -eq 1 ]]; then
  BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Info.plist")"
  printf '==> Launching %s\n' "$BUNDLE_ID"
  xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID"
fi

printf '==> Installed successfully\n'

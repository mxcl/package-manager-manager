#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
configuration="${CONFIGURATION:-release}"
app_name="Package Manager Manager"
executable="PMMApp"
identifier="${PRODUCT_BUNDLE_IDENTIFIER:-dev.mxcl.pmm}"
version="${MARKETING_VERSION:-0.1.0}"
build="${CURRENT_PROJECT_VERSION:-1}"
app="${APP_PATH:-$root/dist/$app_name.app}"
icon="$root/Sources/PMMApp/Resources/AppIcon.icon"
run=false
install=false

usage() {
  printf 'Usage: %s [--install] [--run]\n' "${0##*/}"
}

while (($#)); do
  case "$1" in
    --install) install=true ;;
    --run) run=true ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
  shift
done

kill_existing() {
  pkill -x "$executable" 2>/dev/null || true
  for _ in {1..50}; do
    pgrep -x "$executable" >/dev/null || return 0
    sleep 0.1
  done
  pkill -9 -x "$executable" 2>/dev/null || true
}

swift build -c "$configuration" --product "$executable"
bin_dir="$(swift build -c "$configuration" --show-bin-path)"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

cp "$bin_dir/$executable" "$app/Contents/MacOS/$executable"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/assets"

xcrun actool "$icon" \
  --compile "$work/assets" \
  --platform macosx \
  --target-device mac \
  --minimum-deployment-target 26.0 \
  --app-icon AppIcon \
  --include-all-app-icons \
  --enable-on-demand-resources NO \
  --output-partial-info-plist "$work/IconInfo.plist" >/dev/null

cp "$work/assets/Assets.car" "$app/Contents/Resources/Assets.car"

cat > "$work/Info.plist.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>$app_name</string>
  <key>CFBundleExecutable</key>
  <string>$executable</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>$identifier</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$app_name</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$version</string>
  <key>CFBundleSupportedPlatforms</key>
  <array>
    <string>MacOSX</string>
  </array>
  <key>CFBundleVersion</key>
  <string>$build</string>
  <key>LSMinimumSystemVersion</key>
  <string>26.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
EOF

plutil -convert binary1 -o "$app/Contents/Info.plist" "$work/Info.plist.xml"
codesign --force --sign - "$app" >/dev/null

final_app="$app"
if $install; then
  final_app="/Applications/$app_name.app"
  kill_existing
  rm -rf "$final_app"
  mv "$app" "$final_app"
  rmdir "$root/dist" 2>/dev/null || true
fi

printf '%s\n' "Built $final_app"

if $run; then
  kill_existing
  open "$final_app"
fi

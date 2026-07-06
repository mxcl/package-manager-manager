#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
configuration="${CONFIGURATION:-release}"
app_name="Package Manager Manager"
executable="PMMApp"
helper_app_name="Package Manager Manager Menu"
helper_executable="PMMMenuBar"
identifier="${PRODUCT_BUNDLE_IDENTIFIER:-dev.mxcl.pmm}"
helper_identifier="${HELPER_BUNDLE_IDENTIFIER:-$identifier.menu}"
version="${MARKETING_VERSION:-0.1.0}"
build="${CURRENT_PROJECT_VERSION:-1}"
app="${APP_PATH:-$root/dist/$app_name.app}"
helper_app="$root/dist/$helper_app_name.app"
dmg_path="${DMG_PATH:-$root/dist/$app_name-$version.dmg}"
icon="$root/Sources/PMMApp/Resources/AppIcon.icon"
run=false
install=false
dmg=false
notarize=false
publish=false
mount=""

usage() {
  printf 'Usage: %s [--install] [--run] [--dmg] [--notarize] [--publish]\n' "${0##*/}"
}

while (($#)); do
  case "$1" in
    --install) install=true ;;
    --run) run=true ;;
    --dmg) dmg=true ;;
    --notarize) dmg=true; notarize=true ;;
    --publish) dmg=true; publish=true ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
  shift
done

if $publish && ! command -v gh >/dev/null; then
  printf '%s\n' 'gh is required for --publish' >&2
  exit 64
fi

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  sign_identity="$CODESIGN_IDENTITY"
else
  sign_identity="$(
    security find-identity -v -p codesigning |
      awk -F '"' '/Developer ID Application/ { print $2; exit }'
  )"
  if [[ -z "$sign_identity" ]]; then
    sign_identity="$(
      security find-identity -v -p codesigning |
        awk -F '"' '/Apple Development/ { print $2; exit }'
    )"
  fi
  if [[ -z "$sign_identity" ]]; then
    sign_identity="-"
  fi
fi
if [[ -z "${APPLE_TEAM_ID:-}" && "$sign_identity" =~ \(([A-Z0-9]+)\)$ ]]; then
  export APPLE_TEAM_ID="${BASH_REMATCH[1]}"
fi
if $notarize; then
  export APPLE_TEAM_ID="${APPLE_TEAM_ID:-${DEVELOPMENT_TEAM:-}}"
  if [[ -z "$APPLE_TEAM_ID" ]]; then
    printf '%s\n' 'APPLE_TEAM_ID or DEVELOPMENT_TEAM is required for --notarize' >&2
    exit 64
  fi
  if [[ "$sign_identity" == "-" ]]; then
    printf '%s\n' 'CODESIGN_IDENTITY is required for --notarize' >&2
    exit 64
  fi
fi
codesign_args=(--force --sign "$sign_identity")
if [[ "$sign_identity" != "-" ]]; then
  codesign_args+=(--options runtime --timestamp)
fi

kill_existing() {
  pkill -x "$executable" 2>/dev/null || true
  pkill -x "$helper_executable" 2>/dev/null || true
  for _ in {1..50}; do
    { pgrep -x "$executable" >/dev/null || pgrep -x "$helper_executable" >/dev/null; } || return 0
    sleep 0.1
  done
  pkill -9 -x "$executable" 2>/dev/null || true
  pkill -9 -x "$helper_executable" 2>/dev/null || true
}

cleanup() {
  if [[ -n "$mount" ]]; then
    hdiutil detach "$mount" -quiet 2>/dev/null || true
  fi
  rm -rf "$work"
}

swift build -c "$configuration" --product "$executable"
swift build -c "$configuration" --product "$helper_executable"
bin_dir="$(swift build -c "$configuration" --show-bin-path)"

rm -rf "$app" "$helper_app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Library/LoginItems"
mkdir -p "$helper_app/Contents/MacOS"

cp "$bin_dir/$executable" "$app/Contents/MacOS/$executable"
cp "$bin_dir/$helper_executable" "$helper_app/Contents/MacOS/$helper_executable"

work="$(mktemp -d)"
trap cleanup EXIT
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
cat > "$work/HelperInfo.plist.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>$helper_app_name</string>
  <key>CFBundleExecutable</key>
  <string>$helper_executable</string>
  <key>CFBundleIdentifier</key>
  <string>$helper_identifier</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$helper_app_name</string>
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
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
EOF

plutil -convert binary1 -o "$helper_app/Contents/Info.plist" "$work/HelperInfo.plist.xml"
codesign "${codesign_args[@]}" "$helper_app" >/dev/null
mv "$helper_app" "$app/Contents/Library/LoginItems/$helper_app_name.app"
codesign "${codesign_args[@]}" "$app" >/dev/null

if $dmg; then
  dmg_root="$work/dmg"
  rm -rf "$dmg_path" "$dmg_root"
  mkdir -p "$dmg_root"
  cp -R "$app" "$dmg_root/$app_name.app"
  ln -s /Applications "$dmg_root/Applications"
  hdiutil create -volname "$app_name" -srcfolder "$dmg_root" -ov -format UDZO "$dmg_path" >/dev/null
fi

if $notarize; then
  "$root/scripts/build-notarize-dmg.sh" "$dmg_path"
  xcrun stapler staple "$dmg_path"
fi

if $publish; then
  tag="${RELEASE_TAG:-v$version}"
  gh release create "$tag" "$dmg_path" --title "$app_name $version" --notes ""
fi

final_app="$app"
if $install; then
  final_app="/Applications/$app_name.app"
  kill_existing
  rm -rf "$final_app"
  if $notarize; then
    mount="$work/mount"
    mkdir -p "$mount"
    hdiutil attach "$dmg_path" -nobrowse -quiet -mountpoint "$mount"
    ditto "$mount/$app_name.app" "$final_app"
    hdiutil detach "$mount" -quiet
    mount=""
    rm -rf "$app"
  else
    mv "$app" "$final_app"
  fi
  rmdir "$root/dist" 2>/dev/null || true
fi

printf '%s\n' "Built $final_app"
if $dmg; then
  printf '%s\n' "Created $dmg_path"
fi

if $run; then
  kill_existing
  open "$final_app"
fi

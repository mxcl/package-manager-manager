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
version="${MARKETING_VERSION:-0.4.0}"
build="${CURRENT_PROJECT_VERSION:-1}"
app="${APP_PATH:-$root/dist/$app_name.app}"
helper_app="$root/dist/$helper_app_name.app"
dmg_path=""
icon="$root/Sources/PMMApp/Resources/AppIcon.icon"
run=false
install=false
dmg=false
notarize=false
publish=false
mount=""
release_notes_path=""

usage() {
  printf 'Usage: %s [--install] [--run] [--dmg] [--notarize] [--publish]\n' "${0##*/}"
}

die() {
  printf '%s\n' "$1" >&2
  exit 64
}

require_tool() {
  command -v "$1" >/dev/null || die "$1 is required for --publish"
}

script_version() {
  sed -n 's/^version="${MARKETING_VERSION:-\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)}"$/\1/p' "$root/scripts/build.sh"
}

latest_release_tag() {
  local release_tag
  release_tag="$(
    gh release list \
      --exclude-drafts \
      --limit 1 \
      --json tagName \
      --jq '.[0].tagName'
  )" || die "Unable to list GitHub releases"
  [[ -n "$release_tag" && "$release_tag" != "null" ]] || return 1
  printf '%s\n' "$release_tag"
}

ensure_git_tag_available() {
  local tag="$1"
  git -C "$root" rev-parse --verify --quiet "$tag^{commit}" >/dev/null && return 0
  git -C "$root" fetch --quiet origin "refs/tags/$tag:refs/tags/$tag" ||
    die "Unable to fetch release tag $tag"
}

version_gt() {
  local left="$1" right="$2"
  local left_major left_minor left_patch right_major right_minor right_patch

  [[ "$left" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$right" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    die "Release publishing requires X.Y.Z versions"
  IFS=. read -r left_major left_minor left_patch <<<"$left"
  IFS=. read -r right_major right_minor right_patch <<<"$right"

  if ((10#$left_major != 10#$right_major)); then
    ((10#$left_major > 10#$right_major))
  elif ((10#$left_minor != 10#$right_minor)); then
    ((10#$left_minor > 10#$right_minor))
  else
    ((10#$left_patch > 10#$right_patch))
  fi
}

ensure_release_worktree_state() {
  git -C "$root" diff --cached --quiet ||
    die "Index has staged changes; commit or stash them before publishing"
  git -C "$root" diff --quiet -- scripts/build.sh ||
    die "scripts/build.sh has unstaged changes; commit or stash them before publishing"
}

generate_release_plan() {
  local current_version="$1"
  local plan_path notes_path version_path previous_tag compare_range prompt target_ref

  require_tool codex
  require_tool gh

  plan_path="$(mktemp "${TMPDIR:-/tmp}/pmm-release-plan.XXXXXX")"
  notes_path="$(mktemp "${TMPDIR:-/tmp}/pmm-release-notes.XXXXXX")"
  version_path="$(mktemp "${TMPDIR:-/tmp}/pmm-release-version.XXXXXX")"
  target_ref="$(git -C "$root" rev-parse HEAD)"

  if previous_tag="$(latest_release_tag)"; then
    ensure_git_tag_available "$previous_tag"
    compare_range="$previous_tag..$target_ref"
    prompt="Plan the next Package Manager Manager release.

Repository: $root
Previous release tag: $previous_tag
Current script version: $current_version
Compare range: $compare_range

Inspect the git history and diff for that range. Choose the next SemVer version based on the changes since the previous release.
Use patch for compatible fixes, minor for new user-visible behavior, and major only for intentional breaking changes.
Write concise GitHub release notes in Markdown focused on behavior, fixes, user-visible improvements, packaging, and operational changes.
Do not edit files or create commits.
Output exactly this format, with no code fence, no title, no preamble, no commit hashes, no contributor list, and no GitHub auto-generated notes references:
1. Release Notes
<release notes markdown>
2. New Semantic Version
<X.Y.Z>"
  else
    prompt="Plan the initial Package Manager Manager release.

Repository: $root
Current script version: $current_version
Target ref: $target_ref

Inspect the repository and recent git history. Choose the next SemVer version.
Write concise GitHub release notes in Markdown focused on behavior, fixes, user-visible improvements, packaging, and operational changes.
Do not edit files or create commits.
Output exactly this format, with no code fence, no title, no preamble, no commit hashes, no contributor list, and no GitHub auto-generated notes references:
1. Release Notes
<release notes markdown>
2. New Semantic Version
<X.Y.Z>"
  fi

  printf '%s\n' "Generating release plan with Codex" >&2
  codex exec \
    --cd "$root" \
    --sandbox read-only \
    --config approval_policy=\"never\" \
    --color never \
    --ephemeral \
    --output-last-message "$plan_path" \
    "$prompt" \
    >&2 || die "Codex release planning failed"

  [[ -s "$plan_path" ]] || die "Codex generated an empty release plan"

  awk '
    /^[[:space:]]*(1\.)?[[:space:]]*Release Notes[[:space:]]*$/ { in_notes = 1; next }
    /^[[:space:]]*(2\.)?[[:space:]]*New Semantic Version[[:space:]]*$/ { exit }
    in_notes { print }
  ' "$plan_path" >"$notes_path"

  awk '
    /^[[:space:]]*(2\.)?[[:space:]]*New Semantic Version[[:space:]]*$/ { in_version = 1; next }
    in_version && match($0, /[0-9]+\.[0-9]+\.[0-9]+/) {
      print substr($0, RSTART, RLENGTH)
      exit
    }
  ' "$plan_path" >"$version_path"

  [[ -s "$notes_path" ]] || die "Codex release plan did not include release notes"
  [[ -s "$version_path" ]] || die "Codex release plan did not include an X.Y.Z version"

  printf '%s\n' "1. Release Notes" >&2
  sed 's/^/  /' "$notes_path" >&2
  printf '%s\n' "2. New Semantic Version" >&2
  sed 's/^/  /' "$version_path" >&2

  printf '%s\n%s\n' "$notes_path" "$version_path"
}

bump_script_version() {
  local new_version="$1"

  [[ "$new_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    die "Release publishing requires an X.Y.Z version, got: $new_version"

  VERSION="$new_version" perl -0pi -e '
    my $version = $ENV{VERSION};
    s/^version="\$\{MARKETING_VERSION:-[0-9]+\.[0-9]+\.[0-9]+\}"$/version="\${MARKETING_VERSION:-$version}"/m
      or die "Unable to update default version in scripts/build.sh\n";
  ' "$root/scripts/build.sh"
}

commit_release_version() {
  local new_version="$1"
  local tag="v$new_version"

  git -C "$root" add scripts/build.sh
  git -C "$root" diff --cached --quiet &&
    die "Release version file was unchanged after version bump"

  git -C "$root" commit -m "$tag" >&2
}

push_current_branch() {
  local branch

  branch="$(git -C "$root" rev-parse --abbrev-ref HEAD)"
  [[ "$branch" != "HEAD" ]] || die "Cannot push release commit from detached HEAD"
  if ! git -C "$root" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' >/dev/null 2>&1; then
    git -C "$root" remote get-url origin >/dev/null 2>&1 ||
      die "Current branch has no upstream and no origin remote"
    git -C "$root" push --set-upstream origin "$branch" >&2
    return
  fi
  git -C "$root" push >&2
}

while (($#)); do
  case "$1" in
    --install) install=true ;;
    --run) run=true ;;
    --dmg) dmg=true ;;
    --notarize) dmg=true; notarize=true ;;
    --publish) dmg=true; notarize=true; publish=true ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
  shift
done

if $publish; then
  require_tool git
  require_tool gh
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null ||
    die "scripts/build.sh must run inside a git repository"
  git -C "$root" rev-parse --verify HEAD >/dev/null 2>&1 ||
    die "Create an initial commit before publishing"
  if ! git -C "$root" remote get-url origin >/dev/null 2>&1 && [[ -z "${GH_REPO:-}" ]]; then
    die "Set a git origin remote or GH_REPO before publishing"
  fi

  ensure_release_worktree_state
  current_version="$(script_version)"
  [[ -n "$current_version" ]] || die "Unable to read default version from scripts/build.sh"
  release_plan="$(generate_release_plan "$current_version")"
  release_notes_path="$(printf '%s\n' "$release_plan" | sed -n '1p')"
  version_path="$(printf '%s\n' "$release_plan" | sed -n '2p')"
  planned_version="$(<"$version_path")"

  version_gt "$planned_version" "$current_version" ||
    die "Codex proposed $planned_version, which is not newer than current version $current_version"
  if git -C "$root" rev-parse --verify --quiet "v$planned_version^{commit}" >/dev/null; then
    die "Tag v$planned_version already exists"
  fi

  bump_script_version "$planned_version"
  version="$planned_version"
  commit_release_version "$planned_version"
  push_current_branch
fi

dmg_path="${DMG_PATH:-$root/dist/package-manager-manager-$version.dmg}"

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
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>
      <string>$identifier</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>pkgmgrmgr</string>
      </array>
    </dict>
  </array>
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
  gh release create "$tag" "$dmg_path" \
    --target "$(git -C "$root" rev-parse HEAD)" \
    --title "$app_name $version" \
    --notes-file "$release_notes_path"
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

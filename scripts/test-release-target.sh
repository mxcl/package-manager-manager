#!/bin/bash
set -euo pipefail

script="$(cd "$(dirname "$0")" && pwd)/build.sh"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
git -C "$root" init --quiet
git -C "$root" config user.name 'Release Test'
git -C "$root" config user.email 'release-test@example.invalid'

commit_release_version() {
  git -C "$root" commit --quiet --allow-empty -m "v$1"
}

push_current_branch() {
  pushed_sha="$(git -C "$root" rev-parse HEAD)"
}

gh() {
  [[ "$1 $2" == 'release create' ]]
  while (($#)); do
    if [[ "$1" == --target ]]; then
      [[ "$2" == "$pushed_sha" ]] || {
        printf 'FAIL: release target changed after the release commit was pushed\n' >&2
        return 1
      }
      return 0
    fi
    shift
  done
  return 1
}

planned_version=0.26.0
eval "$(sed -n '/^    commit_release_version "\$planned_version"$/,/^    push_current_branch$/p' "$script")"
# Simulate another task committing while the build and notarization run.
git -C "$root" commit --quiet --allow-empty -m 'Concurrent change'

publish=true
clobber=false
version="$planned_version"
app_name='Package Manager Manager'
dmg_path="$root/release.dmg"
release_notes_path="$root/notes.md"
unset RELEASE_TAG
eval 'if $publish; then
'"$(sed -n '/^  tag="${RELEASE_TAG:-v\$version}"$/,/^fi$/p' "$script")"
printf 'PASS: release targets the pushed version commit despite HEAD moving\n'

#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
app='/Applications/Package Manager Manager.app'
remote_host=pangolin
ssh_options=(-o BatchMode=yes -o ConnectTimeout=10)
revision="$(git rev-parse --short HEAD)"
remote_stage="/Applications/.pmm-install.$revision.$$.app"
remote_backup="/Applications/.pmm-previous.$revision.$$.app"

trap 'printf "Deployment failed at line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

# Do not interrupt remote-control package operations during replacement.
if pgrep -u "$(id -u)" -x pmmctl >/dev/null; then
  echo 'Local pmmctl is busy; wait for it to finish.' >&2
  exit 1
fi
ssh "${ssh_options[@]}" "$remote_host" 'bash -s' <<'PREFLIGHT'
set -euo pipefail
[[ "$(uname -sm)" == 'Darwin arm64' ]]
[[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 26 ]]
[[ -w /Applications ]]
if pgrep -u "$(id -u)" -x pmmctl >/dev/null; then
  echo 'pangolin pmmctl is busy; wait for it to finish.' >&2
  exit 1
fi
PREFLIGHT

# No notarization or publication: Apple account credentials are unnecessary.
CONFIGURATION=release /bin/bash "$root/scripts/build.sh" --install --run
/usr/bin/codesign --verify --deep --strict "$app"

# build.sh moves dist's app into /Applications when --install is used.
rsync -a --delete -e 'ssh -o BatchMode=yes -o ConnectTimeout=10' "$app/" "$remote_host:$remote_stage/"
ssh "${ssh_options[@]}" "$remote_host" bash -s -- "$remote_stage" "$remote_backup" <<'INSTALL'
set -euo pipefail
stage="$1"
backup="$2"
app='/Applications/Package Manager Manager.app'
[[ "$stage" == /Applications/.pmm-install.*.app ]]
[[ "$backup" == /Applications/.pmm-previous.*.app ]]
[[ ! -e "$backup" ]]
/usr/bin/codesign --verify --deep --strict "$stage"
if pgrep -u "$(id -u)" -x pmmctl >/dev/null; then
  echo 'pangolin pmmctl became busy; staged app retained.' >&2
  exit 1
fi
for process in PMMApp PMMMenuBar; do
  pkill -u "$(id -u)" -x "$process" 2>/dev/null || true
  for _ in {1..50}; do
    pgrep -u "$(id -u)" -x "$process" >/dev/null || break
    sleep 0.1
  done
  if pgrep -u "$(id -u)" -x "$process" >/dev/null; then
    echo "$process did not stop; installation unchanged." >&2
    exit 1
  fi
done
rollback() {
  if [[ -d "$backup" ]]; then
    rm -rf "$app"
    mv "$backup" "$app"
  fi
}
trap rollback EXIT
if [[ -e "$app" ]]; then mv "$app" "$backup"; fi
mv "$stage" "$app"
/usr/bin/codesign --verify --deep --strict "$app"
trap - EXIT
rm -rf "$backup"
open "$app"
INSTALL

for executable in 'Contents/MacOS/PMMApp' 'Contents/Helpers/pmmctl' \
  'Contents/Library/LoginItems/Package Manager Manager Menu.app/Contents/MacOS/PMMMenuBar'; do
  local_hash="$(shasum -a 256 "$app/$executable" | awk '{print $1}')"
  # These fixed bundle paths deliberately expand locally for the remote command.
  # shellcheck disable=SC2029
  remote_hash="$(ssh "${ssh_options[@]}" "$remote_host" "shasum -a 256 '$app/$executable'" | awk '{print $1}')"
  [[ "$local_hash" == "$remote_hash" ]] || { echo "Hash mismatch: $executable" >&2; exit 1; }
done

# Check executable paths as well as names, so a build-directory process cannot pass.
verify_running() {
  local app='/Applications/Package Manager Manager.app' process pid expected found
  for process in PMMApp PMMMenuBar; do
    expected="$app/Contents/MacOS/PMMApp"
    if [[ "$process" == PMMMenuBar ]]; then
      expected="$app/Contents/Library/LoginItems/Package Manager Manager Menu.app/Contents/MacOS/PMMMenuBar"
    fi
    found=false
    for _ in {1..50}; do
      for pid in $(pgrep -u "$(id -u)" -x "$process" || true); do
        if [[ "$(ps -p "$pid" -o comm=)" == "$expected" ]]; then found=true; break; fi
      done
      $found && break
      sleep 0.2
    done
    $found || { echo "$process is not running from the installed bundle." >&2; return 1; }
  done
}
verify_running
printf 'This Mac: installed and running PMM (%s).\n' "$revision"
printf -v verification_command '%q' "$(declare -f verify_running)"$'\nverify_running'
ssh -n "${ssh_options[@]}" "$remote_host" "/bin/bash -ec $verification_command"
printf 'pangolin: installed and running the same verified PMM binaries (%s).\n' "$revision"

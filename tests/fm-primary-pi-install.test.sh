#!/usr/bin/env bash
# Executable-interface tests for reversible primary recovery convenience files.
set -eu
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T=$(mktemp -d "${TMPDIR:-/tmp}/fm-primary-install.XXXXXX")
T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT
DEST="$T/home"
SOURCE_HOME="$T/firstmate-home"
mkdir -p "$DEST" "$SOURCE_HOME"
SCRIPT="$ROOT/bin/fm-primary-pi-install.sh"
export FM_PRIMARY_INSTALL_HOME="$DEST" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$SOURCE_HOME"
PLIST="$DEST/Library/LaunchAgents/dev.firstmate.primary-herdr.plist"
HELPER="$DEST/.local/bin/firstmate-attach"

# Portable octal mode. Platform-detected, never the `stat -f || stat -c` fallback:
# GNU `stat -f` is --file-system, so it reads '%Lp' as a missing file and still
# writes a filesystem dump for the real path, which the fallback mode then trails.
file_mode() {
  if [ "$(uname)" = Darwin ]; then stat -f %Lp "$1"; else stat -c %a "$1"; fi
}

out=$("$SCRIPT" install) || fail "install failed: $out"
assert_present "$PLIST" 'installer must write the one-shot next-login plist'
assert_present "$HELPER" 'installer must write the phone/local attach helper'
assert_grep '<key>RunAtLoad</key>' "$PLIST" 'plist must run once after login'
assert_grep '<false/>' "$PLIST" 'plist must not keep a daemon alive'
assert_grep "$ROOT/bin/fm-primary-pi.sh" "$PLIST" 'plist must use the exact tracked script'
assert_grep '<string>server-ensure</string>' "$PLIST" 'plist must only ensure the recorded named server'
assert_grep "<string>$SOURCE_HOME</string>" "$PLIST" 'plist must bind the canonical Firstmate home'
assert_no_grep 'recover' "$PLIST" 'next-login job must not auto-launch Pi'
assert_grep "exec env FM_HOME='$SOURCE_HOME' '$ROOT/bin/fm-primary-pi.sh' recover" "$HELPER" 'attach helper must bind the home and use exact-path recovery'
if command -v plutil >/dev/null 2>&1; then
  plutil -lint "$PLIST" >/dev/null || fail 'installed LaunchAgent must be valid plist XML'
fi
[ "$(file_mode "$PLIST")" = 600 ] || fail 'plist mode must be 0600'
[ "$(file_mode "$HELPER")" = 700 ] || fail 'attach helper mode must be 0700'
pass 'install writes bounded one-shot server ensure and exact recovery helper'

first_plist=$(shasum -a 256 "$PLIST" | awk '{print $1}')
first_helper=$(shasum -a 256 "$HELPER" | awk '{print $1}')
"$SCRIPT" install >/dev/null
[ "$first_plist" = "$(shasum -a 256 "$PLIST" | awk '{print $1}')" ] || fail 'reinstall changed plist content'
[ "$first_helper" = "$(shasum -a 256 "$HELPER" | awk '{print $1}')" ] || fail 'reinstall changed helper content'
status=$("$SCRIPT" status)
assert_contains "$status" 'launch-agent=installed' 'status must recognize installer-owned plist'
assert_contains "$status" 'attach-helper=installed' 'status must recognize installer-owned helper'
assert_contains "$status" 'enabled=not-managed' 'status must state that launchctl is out of scope'
pass 'install and status are idempotent without enabling anything'

"$SCRIPT" uninstall >/dev/null
assert_absent "$PLIST" 'uninstall must remove installer-owned plist'
assert_absent "$HELPER" 'uninstall must remove installer-owned helper'
"$SCRIPT" uninstall >/dev/null
pass 'uninstall is reversible and idempotent'

mkdir -p "${PLIST%/*}" "${HELPER%/*}"
printf 'foreign\n' > "$PLIST"
set +e
out=$("$SCRIPT" install 2>&1); rc=$?
set -e
[ "$rc" -ne 0 ] || fail 'installer replaced a foreign plist'
assert_contains "$out" 'refusing to replace foreign' 'foreign file refusal must be clear'
assert_grep 'foreign' "$PLIST" 'foreign plist must remain untouched'
rm "$PLIST"
printf 'foreign\n' > "$T/foreign"
ln -s "$T/foreign" "$HELPER"
set +e
out=$("$SCRIPT" install 2>&1); rc=$?
set -e
[ "$rc" -ne 0 ] || fail 'installer replaced a symlink helper'
assert_contains "$out" 'refusing to replace foreign or symlink' 'symlink refusal must be clear'
assert_present "$HELPER" 'symlink helper must remain untouched'
assert_absent "$PLIST" 'foreign helper preflight must happen before plist publication'
rm "$HELPER"
rmdir "${HELPER%/*}" "$DEST/.local" 2>/dev/null || true
mkdir "$T/outside"
ln -s "$T/outside" "$DEST/.local"
set +e
out=$("$SCRIPT" install 2>&1); rc=$?
set -e
[ "$rc" -ne 0 ] || fail 'installer followed a symlinked destination parent'
assert_contains "$out" 'contains a symlink or noncanonical component' 'parent symlink refusal must be clear'
assert_absent "$PLIST" 'parent-directory preflight must happen before plist publication'
pass 'foreign files and symlink destinations are never replaced, followed, or removed'

printf 'all fm-primary-pi-install executable-interface tests passed\n'

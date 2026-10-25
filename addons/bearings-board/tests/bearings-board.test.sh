#!/usr/bin/env bash
# Wrapper test: a stub Firstmate checkout stands in for the real board. Covers
# build and path passthrough, argument forwarding, the recursion guard, and install
# and uninstall round trips including their failure paths, dry runs, hook cleanup,
# and the hook's file, mode and links surviving that round trip.
set -eu

ADDON=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WRAPPER="$ADDON/bin/fm-bearings-board.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/bearings-board-test.XXXXXX")
trap 'rm -rf -- "$TMP"' EXIT
export HOME=$TMP/home XDG_DATA_HOME=$TMP/data

fail() { printf 'not ok: %s\n' "$*" >&2; exit 1; }
FMH="$TMP/fm"
mkdir -p "$FMH/bin" "$FMH/state" "$FMH/config"
cat > "$FMH/bin/fm-bearings-board.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FM_HOME/state/build-args"
case "$1" in
  build) printf 'built\n' > "$FM_HOME/state/board.html" ;;
  path) printf '%s/state/board.html\n' "$FM_HOME" ;;
esac
STUB
chmod +x "$FMH/bin/fm-bearings-board.sh"
printf 'old\n' > "$FMH/config/bearings-board-command"
export FM_CODE_ROOT="$FMH" FM_HOME="$FMH"

echo '{"projects":[]}' > "$TMP/good.json"
"$WRAPPER" build "$TMP/good.json" || fail "good payload refused"
grep -q built "$FMH/state/board.html" || fail "checkout build did not run"
[ -z "$(sed -n 3p "$FMH/state/build-args")" ] || fail "unexpected extra argument forwarded"
"$WRAPPER" build "$TMP/good.json" --flag || fail "payload with a flag refused"
[ "$(sed -n 3p "$FMH/state/build-args")" = --flag ] || fail "extra argument dropped"
[ "$("$WRAPPER" path)" = "$FMH/state/board.html" ] || fail "path is not the checkout's board"
FM_CODE_ROOT="$ADDON" "$WRAPPER" build "$TMP/good.json" >/dev/null 2>&1 && fail "wrapper re-entered itself"

LAUNCHER="$FMH/state/bearings-board-thin"
rm -rf -- "$FMH/state"; : > "$FMH/state"
"$ADDON/install.sh" "$FMH" >/dev/null 2>&1 && fail "install survived an unusable state dir"
[ "$(cat "$FMH/config/bearings-board-command")" = old ] || fail "failed install changed the hook"
rm -f -- "$FMH/state"; mkdir -p "$FMH/state"

"$ADDON/install.sh" "$FMH" >/dev/null || fail "install failed"
grep -q "$LAUNCHER" "$FMH/config/bearings-board-command" || fail "hook not pointed at the launcher"
"$LAUNCHER" path | grep -q board.html || fail "launcher does not run the checkout board"
"$ADDON/uninstall.sh" "$FMH" >/dev/null || fail "uninstall failed"
[ ! -e "$LAUNCHER" ] || fail "launcher left behind"
[ "$(cat "$FMH/config/bearings-board-command")" = old ] || fail "hook not restored"
[ -z "$(ls "$FMH/config/"*.bak-bearings-board-thin-* 2>/dev/null)" ] || fail "backup left behind after restore"

# Rerunning install to update is supported: the hook install wrote stays pointed at the
# launcher, the backup recorded by the first install is kept, and uninstall still
# restores the operator's content with no backup left behind.
"$ADDON/install.sh" "$FMH" >/dev/null || fail "install before a rerun failed"
"$ADDON/install.sh" "$FMH" >/dev/null || fail "rerun over a hook install wrote failed"
[ "$(cat "$FMH/config/bearings-board-command")" = "$LAUNCHER" ] || fail "rerun changed the hook install wrote"
"$ADDON/uninstall.sh" "$FMH" >/dev/null || fail "uninstall after a rerun failed"
[ "$(cat "$FMH/config/bearings-board-command")" = old ] || fail "uninstall after a rerun lost the original hook content"
[ ! -e "$LAUNCHER" ] || fail "launcher left behind after a rerun"
[ -z "$(ls "$FMH/config/"*.bak-bearings-board-thin-* 2>/dev/null)" ] || fail "backup left behind after a rerun"

# A home hook is often a symlink into shared config: the round trip must write through
# the link and leave the link and the shared file's mode as they were.
printf 'old\n' > "$FMH/config/shared-board-command"
chmod 600 "$FMH/config/shared-board-command"
rm -f -- "$FMH/config/bearings-board-command"
ln -s shared-board-command "$FMH/config/bearings-board-command"
"$ADDON/install.sh" "$FMH" >/dev/null || fail "install over a symlinked hook failed"
[ -L "$FMH/config/bearings-board-command" ] || fail "install replaced the hook symlink"
[ "$(cat "$FMH/config/shared-board-command")" = "$LAUNCHER" ] || fail "install did not write through the hook symlink"
[ "$(stat -c %a "$FMH/config/shared-board-command")" = 600 ] || fail "install changed the shared hook mode"
"$ADDON/uninstall.sh" "$FMH" >/dev/null || fail "uninstall of a symlinked hook failed"
[ -L "$FMH/config/bearings-board-command" ] || fail "uninstall replaced the hook symlink"
[ "$(cat "$FMH/config/shared-board-command")" = old ] || fail "uninstall did not restore the shared hook content"
[ "$(stat -c %a "$FMH/config/shared-board-command")" = 600 ] || fail "uninstall changed the shared hook mode"
[ ! -e "$LAUNCHER" ] || fail "launcher left behind after a symlinked hook"
rm -f -- "$FMH/config/shared-board-command" "$FMH/config/bearings-board-command"

# A plain hook keeps its mode across the same round trip.
printf 'old\n' > "$FMH/config/bearings-board-command"
chmod 600 "$FMH/config/bearings-board-command"
"$ADDON/install.sh" "$FMH" >/dev/null || fail "install over a mode-0600 hook failed"
[ "$(stat -c %a "$FMH/config/bearings-board-command")" = 600 ] || fail "install changed the hook mode"
"$ADDON/uninstall.sh" "$FMH" >/dev/null || fail "uninstall of a mode-0600 hook failed"
[ "$(stat -c %a "$FMH/config/bearings-board-command")" = 600 ] || fail "uninstall changed the hook mode"
[ "$(cat "$FMH/config/bearings-board-command")" = old ] || fail "mode-0600 hook content not restored"
chmod 644 "$FMH/config/bearings-board-command"

# Dry runs report what they would do and write nothing, install and uninstall alike.
"$ADDON/install.sh" --dry-run "$FMH" >/dev/null || fail "install dry run failed"
[ ! -e "$LAUNCHER" ] || fail "install dry run wrote the launcher"
[ ! -e "$FMH/state/bearings-board-thin.install" ] || fail "install dry run wrote the record"
[ "$(cat "$FMH/config/bearings-board-command")" = old ] || fail "install dry run changed the hook"
[ -z "$(ls "$FMH/config/"*.bak-bearings-board-thin-* 2>/dev/null)" ] || fail "install dry run wrote a backup"
"$ADDON/install.sh" "$FMH" >/dev/null || fail "install before a dry uninstall failed"
"$ADDON/uninstall.sh" --dry-run "$FMH" >/dev/null || fail "uninstall dry run failed"
[ -x "$LAUNCHER" ] || fail "uninstall dry run removed the launcher"
[ "$(cat "$FMH/config/bearings-board-command")" = "$LAUNCHER" ] || fail "uninstall dry run changed the hook"
"$ADDON/uninstall.sh" "$FMH" >/dev/null || fail "uninstall after a dry run failed"
[ "$(cat "$FMH/config/bearings-board-command")" = old ] || fail "hook not restored after a dry run"

"$ADDON/install.sh" "$FMH" >/dev/null || fail "second install failed"
printf 'exec %s "$@"\n' "$LAUNCHER" > "$FMH/config/bearings-board-command"
"$ADDON/uninstall.sh" "$FMH" >/dev/null || fail "uninstall of an edited hook failed"
grep -q "$LAUNCHER" "$FMH/config/bearings-board-command" || fail "edited hook was overwritten"
[ -x "$LAUNCHER" ] || fail "launcher removed from under a surviving hook"

# Hand-wire the hook as install's message suggests, rerun install, then uninstall:
# the hook is the operator's, so it survives, and the launcher it names is kept.
rm -f -- "$FMH/config/bearings-board-command" "$LAUNCHER" "$FMH/config/"*.bak-bearings-board-thin-*
"$ADDON/install.sh" "$FMH" >/dev/null || fail "install without a hook failed"
[ ! -e "$FMH/config/bearings-board-command" ] || fail "install created a hook"
printf '%s\n' "$LAUNCHER" > "$FMH/config/bearings-board-command"
"$ADDON/install.sh" "$FMH" >/dev/null || fail "install rerun over a hand-wired hook failed"
[ "$(cat "$FMH/config/bearings-board-command")" = "$LAUNCHER" ] || fail "install rewrote a hand-wired hook"
"$ADDON/uninstall.sh" "$FMH" >/dev/null || fail "uninstall after the rerun failed"
[ "$(cat "$FMH/config/bearings-board-command" 2>/dev/null)" = "$LAUNCHER" ] || fail "uninstall removed a hook install never wrote"
[ -x "$LAUNCHER" ] || fail "launcher removed from under a hand-wired hook"
rm -f -- "$FMH/config/bearings-board-command" "$LAUNCHER"

# A backup cleaned up before uninstall must not abort it: install wrote that hook, so it
# goes, and the launcher with it.
printf 'old\n' > "$FMH/config/bearings-board-command"
"$ADDON/install.sh" "$FMH" >/dev/null || fail "install before backup removal failed"
rm -f -- "$FMH/config/"*.bak-bearings-board-thin-*
"$ADDON/uninstall.sh" "$FMH" >/dev/null || fail "uninstall without its backup failed"
[ ! -e "$LAUNCHER" ] || fail "launcher left behind without a backup"
[ ! -e "$FMH/config/bearings-board-command" ] || fail "hook install wrote left behind without a backup"

# A hook that already names the launcher in exec form is left as it is: install writes no
# backup for it, and uninstall keeps both the hook and the launcher it names.
printf 'old\n' > "$FMH/config/bearings-board-command"
"$ADDON/install.sh" "$FMH" >/dev/null || fail "install before an exec-form hook failed"
printf 'exec %s "$@"\n' "$LAUNCHER" > "$FMH/config/bearings-board-command"
"$ADDON/install.sh" "$FMH" >/dev/null || fail "install over an exec-form hook failed"
[ "$(cat "$FMH/config/bearings-board-command")" = "exec $LAUNCHER \"\$@\"" ] || fail "install rewrote an exec-form hook"
"$ADDON/uninstall.sh" "$FMH" >/dev/null || fail "uninstall of an exec-form hook failed"
[ "$(cat "$FMH/config/bearings-board-command")" = "exec $LAUNCHER \"\$@\"" ] || fail "uninstall changed an exec-form hook"
[ -x "$LAUNCHER" ] || fail "launcher removed from under a hook that names it"
rm -f -- "$FMH/config/bearings-board-command" "$LAUNCHER" "$FMH/config/"*.bak-bearings-board-thin-*
echo "ok: wrapper build, forwarding, recursion guard, and install round trips"

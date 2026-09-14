#!/usr/bin/env bash
# Token-free live regression for worker launch through real Herdr and ble.sh.
#
# The test runs complete fm-spawn.sh launches in a generated non-default Herdr
# lab. The lab helper alone owns provisioning, manual Herdr calls, and cleanup;
# the production adapter is allowed through a validating client shim only when
# each pane operation carries the same explicit trailing lab session.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_BLESH_HERDR_LAUNCH_LIVE_E2E herdr blesh-share git bash jq

TMP_ROOT=$(fm_test_tmproot fm-blesh-launch-herdr-live)
HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name herdr-blesh-launch)
REAL_HERDR=$(command -v herdr)
REAL_BASH=$(command -v bash)
BLESH_SHARE=$(blesh-share)
SHIM="$TMP_ROOT/shim"
HOME_DIR="$TMP_ROOT/home"
PROJ_DIR="$TMP_ROOT/project"
WT_DIR="$TMP_ROOT/worktree"
MARKERS="$TMP_ROOT/markers"
RCFILE="$TMP_ROOT/bashrc"
SHELL_WRAPPER="$TMP_ROOT/interactive-bash"
HERDR_LOG="$TMP_ROOT/herdr.log"
REPEATS=${FM_BLESH_HERDR_REPEATS:-20}

case "$REPEATS" in
  ''|*[!0-9]*) fail "FM_BLESH_HERDR_REPEATS must be a positive integer" ;;
  0) fail "FM_BLESH_HERDR_REPEATS must be a positive integer" ;;
esac
[ -x "$HERDR_LAB_HELPER" ] || fail "Herdr lab helper is not executable"
[ -f "$BLESH_SHARE/ble.sh" ] || fail "blesh-share did not resolve a ble.sh installation"
mkdir -p "$SHIM" "$MARKERS"

cleanup_live() {
  local status=0
  PATH="$SHIM:$PATH" FM_EXPECT_HERDR_SESSION="$HERDR_LAB_SESSION" \
    FM_HERDR_LAB_STATE_DIR="$TMP_ROOT/lab-state" \
    "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=$?
  fm_test_cleanup
  return "$status"
}
trap cleanup_live EXIT

cat > "$SHIM/herdr" <<EOF
#!/usr/bin/env bash
set -u
printf '%s\037' "\$@" >> "${HERDR_LOG}"
printf '\n' >> "${HERDR_LOG}"
case "\${1:-} \${2:-}" in
  'status --json') ;;
  *)
    [ "\$#" -ge 2 ] || { echo 'test shim: missing explicit Herdr session' >&2; exit 97; }
    penultimate=
    last=
    for arg in "\$@"; do penultimate=\$last; last=\$arg; done
    [ "\$penultimate" = --session ] && [ "\$last" = "\${FM_EXPECT_HERDR_SESSION:?}" ] \
      || { echo 'test shim: wrong or missing trailing Herdr lab session' >&2; exit 97; }
    ;;
esac
exec "$REAL_HERDR" "\$@"
EOF
cat > "$SHELL_WRAPPER" <<EOF
#!/usr/bin/env bash
exec "$REAL_BASH" --noprofile --rcfile "$RCFILE" -i
EOF
cat > "$RCFILE" <<EOF
if [ "\${FM_BLESH_BUSY:-0}" = 1 ]; then
  sleep 0.4
fi
. "$BLESH_SHARE/ble.sh" --noattach
ble-attach
PS1='fm-blesh-test$ '
EOF
cat > "$SHIM/treehouse" <<'SH'
#!/usr/bin/env bash
cd "${FM_BLESH_WORKTREE:?}" || exit 1
exec "${SHELL:?}"
SH
cat > "$SHIM/pi" <<'SH'
#!/usr/bin/env bash
mkdir -p "${FM_BLESH_MARKERS:?}"
printf 'started\n' > "$FM_BLESH_MARKERS/${FM_TASK_ID:?}"
SH
chmod +x "$SHIM/herdr" "$SHELL_WRAPPER" "$SHIM/treehouse" "$SHIM/pi"
: > "$HERDR_LOG"

PATH="$SHIM:$PATH" FM_EXPECT_HERDR_SESSION="$HERDR_LAB_SESSION" \
  FM_HERDR_LAB_STATE_DIR="$TMP_ROOT/lab-state" \
  env -u TMUX -u TMUX_PANE SHELL="$SHELL_WRAPPER" FM_BLESH_BUSY=1 \
    FM_BLESH_WORKTREE="$WT_DIR" FM_BLESH_MARKERS="$MARKERS" \
    "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"

mkdir -p "$HOME_DIR/data" "$HOME_DIR/projects" "$HOME_DIR/state" "$HOME_DIR/config"
printf 'pi\n' > "$HOME_DIR/config/crew-harness"
printf 'off\n' > "$HOME_DIR/config/herdr-presentation-spaces"
touch "$HOME_DIR/state/.last-watcher-beat"
git init -q "$PROJ_DIR"
git -C "$PROJ_DIR" config user.email test@example.invalid
git -C "$PROJ_DIR" config user.name test
touch "$PROJ_DIR/seed"
git -C "$PROJ_DIR" add seed
git -C "$PROJ_DIR" commit -qm seed
git -C "$PROJ_DIR" worktree add -q -b live-worktree "$WT_DIR"

run_one() {  # <ordinal>
  local ordinal=$1 id out status pane capture i=0
  id="blesh-herdr-$ordinal"
  mkdir -p "$HOME_DIR/data/$id"
  cat > "$HOME_DIR/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise token-free worker launch through Herdr and ble.sh.

## Firstmate spec
Start the fake worker and change no files.
EOF
  out=$(env -u TMUX -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_BLESH_WORKTREE="$WT_DIR" FM_BLESH_MARKERS="$MARKERS" \
    FM_EXPECT_HERDR_SESSION="$HERDR_LAB_SESSION" HERDR_SESSION="$HERDR_LAB_SESSION" \
    FM_HERDR_LAB_STATE_DIR="$TMP_ROOT/lab-state" SHELL="$SHELL_WRAPPER" PATH="$SHIM:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$PROJ_DIR" --scout --harness pi --backend herdr 2>&1)
  status=$?
  expect_code 0 "$status" "Herdr ble.sh spawn $ordinal should return success: $out"
  while [ "$i" -lt 100 ] && [ ! -f "$MARKERS/$id" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  pane=$(sed -n 's/^window=//p' "$HOME_DIR/state/$id.meta")
  pane=${pane#*:}
  if [ ! -f "$MARKERS/$id" ]; then
    capture=$(PATH="$SHIM:$PATH" FM_EXPECT_HERDR_SESSION="$HERDR_LAB_SESSION" \
      FM_HERDR_LAB_STATE_DIR="$TMP_ROOT/lab-state" \
      "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane read "$pane" --source recent --lines 200 2>/dev/null || true)
    case "$capture" in
      *'-- MULTILINE --'*) fail "Herdr ble.sh spawn $ordinal entered multiline mode" ;;
    esac
    fail "Herdr ble.sh spawn $ordinal did not start the fake worker: $out"
  fi
  PATH="$SHIM:$PATH" FM_EXPECT_HERDR_SESSION="$HERDR_LAB_SESSION" \
    FM_HERDR_LAB_STATE_DIR="$TMP_ROOT/lab-state" \
    "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane close "$pane" >/dev/null \
    || fail "could not remove Herdr test pane $ordinal"
}

ordinal=1
while [ "$ordinal" -le "$REPEATS" ]; do
  run_one "$ordinal"
  ordinal=$((ordinal + 1))
done

ctrl_j_count=$(grep -c $'pane\037send-keys\037[^\037]*\037ctrl+j\037' "$HERDR_LOG" || true)
[ "$ctrl_j_count" -ge $((REPEATS * 4)) ] \
  || fail "Herdr launch log recorded only $ctrl_j_count ctrl+j shell accepts for $REPEATS complete spawns"
if grep $'pane\037send-keys\037[^\037]*\037C-j\037' "$HERDR_LOG" >/dev/null; then
  fail "Herdr launch used the invalid literal C-j spelling"
fi
pass "real Herdr and ble.sh executed $REPEATS/$REPEATS complete token-free worker launches with explicit lab binding and ctrl+j"

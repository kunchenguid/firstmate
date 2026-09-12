#!/usr/bin/env bash
# Real-Herdr E2E for fm-herdr-recovery.sh: two scripted seats in one isolated
# lab session, one parked at a real-rendered directory trust dialog and one at
# a real-rendered command-approval prompt for an allowlisted read. The tool
# must recover both through the real pane read/send-keys plumbing while the
# lab helper keeps the fleet default session untouched.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo 'skip: herdr not found'; exit 0; }
command -v jq >/dev/null 2>&1 || { echo 'skip: jq not found'; exit 0; }
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }

REAL_HERDR=$(command -v herdr)
HERDR_ORIGINAL_PATH=$PATH
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-recovery-e2e.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$FAKEBIN" "$HOME_DIR/state"

HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-gcm7b-reco)
export HERDR_LAB_HELPER HERDR_LAB_SESSION REAL_HERDR HERDR_ORIGINAL_PATH
cleanup() {
  local status=$?
  env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=1
  rm -rf "$TMP_ROOT"
  exit "$status"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || fail 'could not provision the lab session'

# Shim: strip the tool's trailing --session pair and route everything through
# the guarded lab helper, the same transport the other Herdr E2Es use.
cat > "$FAKEBIN/herdr" <<SH
#!/usr/bin/env bash
set -u
args=("\$@")
last=\$((\${#args[@]} - 1))
flag=\$((last - 1))
if [ "\${#args[@]}" -ge 2 ] \\
  && [ "\${args[\$flag]}" = --session ] \\
  && [ "\${args[\$last]}" = "$HERDR_LAB_SESSION" ]; then
  unset "args[\$last]" "args[\$flag]"
fi
set -- "\${args[@]}"
for arg in "\$@"; do
  case "\$arg" in --session|--session=*) exit 9 ;; esac
done
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "\$@"
SH
chmod +x "$FAKEBIN/herdr"

lab() { env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }

TRUST_DIALOG=$TMP_ROOT/trust-dialog
APPROVAL_DIALOG=$TMP_ROOT/approval-dialog
# Every rendered line stays narrow (herdr 0.7.4 panes are ~54 columns and pane
# read returns hard-wrapped rows): a line that wraps mid-token would hand the
# classifier a spliced path it must refuse, and a wrapped Reason/option line
# would inject a non-command head into the screened block. The approval
# command therefore reads the inbox by its home-relative path, which the
# classifier resolves from the tool's runner context (the tool runs from the
# home below).
cat > "$TRUST_DIALOG" <<'EOF'

  Do you trust the contents of this directory? Working with untrusted contents comes with higher risk of prompt
  injection. Trusting the directory allows project-local config, hooks, and exec policies to load.

> 1. Yes, continue
  2. No, quit

  Press enter to continue
EOF
cat > "$APPROVAL_DIALOG" <<'EOF'

  Would you like to run the following command?

  Environment: local

  Reason: re-reading the routed inbox.

  $ timeout 15s cat state/fm-e2e-b.inbox/001.msg

> 1. Yes, proceed (y)
  2. Yes, and don't ask again (p)
  3. No, and tell Codex what to do (esc)

  Press enter to confirm or esc to cancel
EOF
mkdir -p "$HOME_DIR/state/fm-e2e-b.inbox"
printf 'recovery instruction for the e2e seat\n' > "$HOME_DIR/state/fm-e2e-b.inbox/001.msg"

# Seat script: park blocked at a real-rendered dialog, consume one Enter, then
# report working again through herdr's real agent-state reporting.
# report-agent carries only flags that exist across the supported herdr range
# (0.7.x has no --seq); the tool reads pane list/pane get agent_status.
# The report call pins REAL_HERDR, the exact binary this script verified and
# the lab helper itself drives: a pane's login shell builds its own PATH, so
# the ambient `herdr` inside the pane can be missing entirely (CI installs
# herdr under RUNNER_TEMP/bin via GITHUB_PATH) or a protocol-mismatched
# version, and a silent failure here would leave the seats never blocked.
# The <PANE_ID> positional leads the flags: herdr 0.7.4's own CLI parser
# rejects report-agent's pane id after the options (0.9.x accepts both), the
# same pane-first order every other real-herdr test uses. Report errors are
# logged per seat so a future regression names its cause.
# The screen and its scrollback are cleared before the dialog is rendered: the
# recovery tool screens the whole 40-line pane read, and the pane's own shell
# echoes the launching "bash <seat script>" line behind a "$ " prompt on a
# runner whose PS1 is the bare default (observed on CI, not on a developer
# shell with a themed prompt). That echoed line is a "$"-prefixed command
# candidate carrying a denied word, so the classifier refused the approval seat
# with 'command names a denied tool or topic' - correctly, fail-closed, on
# fixture noise. Clearing first leaves the dialog as the only pane content and
# keeps the test about the dialog rather than about the runner's prompt.
# The dialog is also rendered before `rep blocked`: the tool's first pane read
# must never be able to observe agent_status=blocked on a pane whose visible
# text is not yet the dialog, since the classifier would correctly fail closed
# on that not-yet-dialog content and flake the e2e on a loaded runner.
make_seat_script() { # <script-path> <pane-id> <dialog-file>
  local report_log=${1%.sh}.report.log
  cat > "$1" <<SEAT
#!/usr/bin/env bash
set -u
P=$2
SRC=fm-herdr-recovery-e2e
LAB=$HERDR_LAB_SESSION
HERDR_BIN=$REAL_HERDR
LOG=$report_log
rep() {
  "\$HERDR_BIN" pane report-agent "\$P" --source "\$SRC" --agent codex --state "\$1" --session "\$LAB" >>"\$LOG" 2>&1
}
printf '\033[H\033[2J\033[3J'
cat "$3"
rep blocked
read -r
rep working
printf 'seat recovered\n'
sleep 600
SEAT
  chmod +x "$1"
}

add_seat() { # <id> <dialog-file>
  local id=$1 dialog=$2
  local label="recovery-e2e-$id" out pane script
  out=$(lab workspace create --cwd "$TMP_ROOT" --label "$label" --no-focus) || fail "could not create workspace for $id"
  pane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id')
  script=$TMP_ROOT/$id-seat.sh
  make_seat_script "$script" "$pane" "$dialog"
  lab pane run "$pane" "bash $script" >/dev/null 2>&1 || fail "could not start the seat script for $id"
  {
    printf 'version=1\n'
    printf 'task_id=%s\n' "$id"
    printf 'window=%s:%s\n' "$HERDR_LAB_SESSION" "$pane"
    printf 'backend=herdr\n'
    printf 'herdr_session=%s\n' "$HERDR_LAB_SESSION"
    printf 'herdr_workspace_id=%s\n' "$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id')"
    printf 'herdr_tab_id=%s\n' "$(printf '%s' "$out" | jq -r '.result.tab.tab_id')"
    printf 'herdr_pane_id=%s\n' "$pane"
    printf 'endpoint_task_id=%s\n' "$id"
    printf 'harness=codex\n'
  } > "$HOME_DIR/state/$id.meta"
}

add_seat fm-e2e-a "$TRUST_DIALOG"
add_seat fm-e2e-b "$APPROVAL_DIALOG"

# Wait until both scripted seats report blocked through the real pane API.
# Budget matches the sibling herdr e2es (90 x 0.5s): a freshly created pane can
# take a while to run its command on a loaded CI runner.
attempt=0
statuses=''
while [ "$attempt" -lt 90 ]; do
  statuses=$(lab pane list | jq -r '.result.panes[]? | "\(.pane_id)\t\(.agent_status // "none")"' 2>/dev/null) || statuses=''
  if [ "$(printf '%s' "$statuses" | grep -c blocked)" -ge 2 ]; then
    break
  fi
  sleep 0.5
  attempt=$((attempt + 1))
done
[ "$(printf '%s' "$statuses" | grep -c blocked)" -ge 2 ] || fail "scripted seats never reached blocked$(printf '\n%s\n' "$TMP_ROOT"/*.report.log 2>/dev/null | while IFS= read -r f; do [ -f "$f" ] && printf '\n--- %s ---\n%s' "$f" "$(cat "$f")"; done)"

# Run from the home so the approval command's home-relative inbox token is
# verifiable in the tool's runner context, exactly like an operator running
# the recovery from inside the home.
OUT=$(cd "$HOME_DIR" && env -u FM_HOME -u FM_STATE_OVERRIDE \
  PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" \
  bash "$ROOT/bin/fm-herdr-recovery.sh" --home "$HOME_DIR")
RC=$?
printf '%s\n' "$OUT"
# The tool classifies exactly what the pane renders, so a verdict this test did
# not expect is only diagnosable with the pane text the tool saw; print it for
# every seat rather than leaving the next failure to be guessed at.
dump_panes() {
  local id pane
  for id in fm-e2e-a fm-e2e-b; do
    pane=$(sed -n 's/^herdr_pane_id=//p' "$HOME_DIR/state/$id.meta" 2>/dev/null)
    [ -n "$pane" ] || continue
    printf '\n--- pane read: %s (%s) ---\n' "$id" "$pane"
    lab pane read "$pane" --lines 40 2>&1 || true
  done
}
[ "$RC" -eq 0 ] || fail "recovery run exited $RC, expected 0$(dump_panes)"
printf '%s' "$OUT" | grep -Eq "seat fm-e2e-a harness=codex pane=$HERDR_LAB_SESSION:[^ ]+ before=blocked after=working enters=1 recovered" \
  || fail 'the trust-dialog seat was not recovered with exactly one Enter'
printf '%s' "$OUT" | grep -Eq "seat fm-e2e-b harness=codex pane=$HERDR_LAB_SESSION:[^ ]+ before=blocked after=working enters=1 recovered" \
  || fail 'the approval seat was not recovered with exactly one Enter'
printf '%s' "$OUT" | grep -Fq 'summary: seats=2 recovered=2 needs-human=0 no-action=0' \
  || fail 'the summary did not report both seats recovered'
pass 'both scripted seats were recovered through the real Herdr pane plumbing'

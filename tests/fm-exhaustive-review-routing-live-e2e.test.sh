#!/usr/bin/env bash
# Credentialed behavior regression for the exhaustive-review routing skill.
#
# This drives a real Pi primary turn through the checked-in AGENTS.md, skills, fm-brief.sh, fm-spawn.sh, Treehouse, and tmux interfaces.
# The only test double is the spawned worker executable, which consumes fm-spawn's typed brief in the actual isolated project worktree and records its GSD review handoff.
set -u

if [ "${FM_EXHAUSTIVE_REVIEW_ROUTING_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_EXHAUSTIVE_REVIEW_ROUTING_LIVE_E2E=1 to run the credentialed exhaustive-review routing regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_SHA=$(git -C "$ROOT" rev-parse HEAD) || exit 1
TASK_ID="exhaustive-review-e2e-$$"
TMP_BASE=${TMPDIR:-/tmp}
LAB=$(mktemp -d "${TMP_BASE%/}/fm-exhaustive-review-routing-live.XXXXXX")
ORIGINAL_PATH=$PATH
REAL_PI=$(command -v pi || true)
REAL_TMUX=$(command -v tmux || true)
CASE_DIR=
CASE_APP=
CASE_PRIMARY_ROOT=
CASE_HOME=
CASE_TMUX_TMP=
CASE_WORKER=
CASE_TASK_TMP="/tmp/fm-$TASK_ID"
CASE_GSD_LOG=
CASE_BRIEF=
CASE_META=
CASE_TRANSCRIPT=
CASE_APP_SHA=

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

cleanup_active_case() {
  if [ -n "${CASE_TMUX_TMP:-}" ] && [ -n "${REAL_TMUX:-}" ]; then
    TMUX_TMPDIR="$CASE_TMUX_TMP" "$REAL_TMUX" kill-server >/dev/null 2>&1 || true
  fi
  if [ -n "${CASE_WORKER:-}" ] && [ -n "${CASE_APP:-}" ] && [ -d "$CASE_APP" ]; then
    ( cd "$CASE_APP" && treehouse return --force "$CASE_WORKER" ) >/dev/null 2>&1 || true
  fi
  [ -n "${CASE_TMUX_TMP:-}" ] && rm -rf "$CASE_TMUX_TMP"
  [ -n "${CASE_TASK_TMP:-}" ] && rm -rf "$CASE_TASK_TMP"
  CASE_TMUX_TMP=
  CASE_WORKER=
}

cleanup() {
  cleanup_active_case
  [ -n "${LAB:-}" ] && rm -rf "$LAB"
}
trap cleanup EXIT

[ -n "$REAL_PI" ] || fail "pi not found"
[ -n "$REAL_TMUX" ] || fail "tmux not found"
command -v git >/dev/null 2>&1 || fail "git not found"
command -v treehouse >/dev/null 2>&1 || fail "treehouse not found"
. "$ROOT/bin/fm-quota-axi-lib.sh"
fm_quota_axi_compatible || fail "quota-axi $FM_QUOTA_AXI_MIN or newer is required for the real primary routing turn"

make_app() {
  local app=$1 origin=$2
  git clone -q --no-checkout "$ROOT" "$app" || fail "could not clone the project review fixture"
  git -C "$app" checkout -q -B main "$SOURCE_SHA" || fail "could not check out the project review fixture"
  git -C "$app" config user.email fmtest@example.invalid
  git -C "$app" config user.name fmtest
  ( cd "$app" && treehouse init >/dev/null ) || fail "could not initialize the project worktree pool"
  [ -f "$app/treehouse.toml" ] || fail "treehouse did not create a project configuration"
  grep -Fxq '.treehouse/' "$app/.gitignore" || printf '%s\n' '.treehouse/' >> "$app/.gitignore"
  git -C "$app" add .gitignore treehouse.toml
  git -C "$app" commit -q -m "test: project review fixture" || fail "could not commit project review fixture"
  git init -q --bare --initial-branch=main "$origin" || fail "could not initialize project fixture origin"
  git -C "$app" remote set-url origin "$origin" || fail "could not set the project fixture origin"
  git -C "$app" push -q -u origin main || fail "could not push project fixture baseline"
  CASE_APP_SHA=$(git -C "$app" rev-parse HEAD) || fail "could not resolve immutable project SHA"
}

make_primary_root() {
  local root=$1 mode=$2 skill
  skill="$root/.agents/skills/firstmate-exhaustive-review/SKILL.md"
  git clone -q --no-checkout "$ROOT" "$root" || fail "could not create primary instruction fixture"
  git -C "$root" checkout -q --detach "$SOURCE_SHA" || fail "could not check out primary instruction fixture"
  git -C "$root" config user.email fmtest@example.invalid
  git -C "$root" config user.name fmtest
  if ! git -C "$ROOT" diff --quiet "$SOURCE_SHA" --; then
    git -C "$ROOT" diff --binary "$SOURCE_SHA" | git -C "$root" apply --binary \
      || fail "could not apply the primary instruction source overlay"
    git -C "$root" add -A
    git -C "$root" commit -q -m "test: source instruction overlay" \
      || fail "could not commit the primary instruction source overlay"
  fi
  [ "$mode" = broken ] || return 0
  cat > "$skill" <<'MD'
---
name: firstmate-exhaustive-review
description: Broken negative-control fixture.
user-invocable: false
metadata:
  internal: true
---

# firstmate-exhaustive-review

## Ownership and dispatch

Route the captain's exhaustive-review request through one configured project worker.
The primary supervises that worker and creates its task brief before launching it through `bin/fm-spawn.sh` under the applicable `AGENTS.md` section 4 rules.
The worker performs its configured review workflow in the project worktree.
MD
  git -C "$root" add "$skill"
  git -C "$root" commit -q -m "test: break exhaustive-review routing policy" \
    || fail "could not commit the broken routing-policy fixture"
}

make_primary_home() {
  local home=$1
  mkdir -p "$home/config" "$home/data" "$home/projects" "$home/state"
  cat > "$home/config/crew-dispatch.json" <<'JSON'
{
  "default": {
    "harness": "pi",
    "model": "openai-codex/gpt-5.6-terra",
    "effort": "high"
  }
}
JSON
  printf '%s\n' tmux > "$home/config/backend"
  cat > "$home/data/projects.md" <<'MD'
- app [direct-PR] - isolated exhaustive-review fixture (added 2026-08-23)
MD
}

make_launch_boundary() {
  local fakebin=$1
  mkdir -p "$fakebin"
  cat > "$fakebin/pi" <<'SH'
#!/usr/bin/env bash
set -eu

case "${1:-}" in
  -h|--help)
    printf '%s\n' 'Usage: pi [options] [message]'
    exit 0
    ;;
esac

prompt=
for arg in "$@"; do
  prompt=$arg
done
log=$(git rev-parse --git-path fm-exhaustive-review-routing.log)
case "$log" in
  /*) ;;
  *) log="$PWD/$log" ;;
esac
mkdir -p "$(dirname "$log")"
sha=$(git rev-parse HEAD)
{
  printf 'worker_cwd=%s\n' "$(pwd -P)"
  printf 'worker_sha=%s\n' "$sha"
  printf 'launch_payload=%s\n' "${prompt%%$'\n'*}"
} > "$log"

if ! printf '%s\n' "$prompt" | grep -Fq 'FIRSTMATE_OP: v1 launch-brief:'; then
  printf 'REJECTED_UNTYPED_BRIEF\n' >> "$log"
  exit 90
fi
if ! printf '%s\n' "$prompt" | grep -qi 'firstmate-exhaustive-review' \
  || ! printf '%s\n' "$prompt" | grep -Eqi 'immutable.*sha' \
  || ! printf '%s\n' "$prompt" | grep -Eqi 'canonical.*ledger'; then
  printf 'REJECTED_MISSING_ROUTING_POLICY\n' >> "$log"
  exit 91
fi

run_gsd_review() {
  printf 'gsd_command=$gsd-code-review --sha %s\n' "$1" >> "$log"
  printf 'GSD_REVIEW_HANDOFF\n' >> "$log"
}
run_gsd_review "$sha"
SH
  chmod +x "$fakebin/pi"
}

wait_for_file() {
  local path=$1 description=$2 attempt
  for attempt in $(seq 1 300); do
    [ -s "$path" ] && return 0
    sleep 0.1
  done
  fail "$description: $(tail -20 "$CASE_TRANSCRIPT" 2>/dev/null || true)"
}

meta_value() {
  local key=$1
  sed -n "s/^$key=//p" "$CASE_META" | head -1
}

assert_meta() {
  local expected=$1
  grep -Fxq "$expected" "$CASE_META" || fail "worker metadata is missing $expected: $(tr '\n' ';' < "$CASE_META") primary transcript: $(tail -40 "$CASE_TRANSCRIPT" 2>/dev/null || true)"
}

assert_brief_task_is_filled() {
  local task_line
  task_line=$(awk 'found { print; exit } /^# Task$/ { found=1 }' "$CASE_BRIEF")
  [ -n "$task_line" ] && [ "$task_line" != '{TASK}' ] \
    || fail "primary left the generated task brief unfilled"
}

worker_contract_is_complete() {
  local worker_cwd
  worker_cwd=$(cd "$CASE_WORKER" && pwd -P) || return 1
  grep -Fxq "worker_cwd=$worker_cwd" "$CASE_GSD_LOG" \
    && grep -Fxq "worker_sha=$CASE_APP_SHA" "$CASE_GSD_LOG" \
    && grep -Fxq "gsd_command=\$gsd-code-review --sha $CASE_APP_SHA" "$CASE_GSD_LOG" \
    && grep -Fxq 'GSD_REVIEW_HANDOFF' "$CASE_GSD_LOG"
}

assert_real_route() {
  [ -s "$CASE_BRIEF" ] || fail "primary did not create a task brief through fm-brief.sh"
  [ -s "$CASE_META" ] || fail "primary did not create worker metadata through fm-spawn.sh"
  [ -n "$CASE_WORKER" ] && [ -d "$CASE_WORKER" ] || fail "fm-spawn did not create an isolated worker worktree"
  [ "$CASE_WORKER" != "$CASE_APP" ] || fail "fm-spawn routed the worker into the primary project checkout"
  assert_meta 'harness=pi'
  assert_meta 'model=openai-codex/gpt-5.6-terra'
  assert_meta 'effort=high'
  assert_meta 'kind=ship'
  assert_meta 'mode=direct-PR'
  assert_meta 'yolo=off'
  grep -Fq 'Delivery contract: mode=direct-PR' "$CASE_BRIEF" \
    || fail "real fm-brief.sh did not preserve the registry delivery contract"
  assert_brief_task_is_filled
  [ "$(git -C "$CASE_WORKER" rev-parse HEAD)" = "$CASE_APP_SHA" ] \
    || fail "worker worktree is not at the immutable project baseline"
  [ -z "$(git -C "$CASE_PRIMARY_ROOT" status --porcelain)" ] \
    || fail "primary altered its Firstmate instruction checkout"
  [ -z "$(git -C "$CASE_APP" status --porcelain)" ] \
    || fail "primary altered the project checkout"
  [ -z "$(git -C "$CASE_WORKER" status --porcelain)" ] \
    || fail "worker review altered the project worktree"
}

run_case() {
  local name=$1 mode=$2 fakebin prompt
  cleanup_active_case
  CASE_DIR="$LAB/$name"
  CASE_APP="$CASE_DIR/app"
  CASE_PRIMARY_ROOT="$CASE_DIR/primary-root"
  CASE_HOME="$CASE_DIR/primary-home"
  CASE_TMUX_TMP="/tmp/fm-tmux-$TASK_ID-$name"
  CASE_WORKER=
  CASE_GSD_LOG=
  CASE_BRIEF="$CASE_HOME/data/$TASK_ID/brief.md"
  CASE_META="$CASE_HOME/state/$TASK_ID.meta"
  CASE_TRANSCRIPT="$CASE_DIR/primary.out"
  CASE_APP_SHA=
  fakebin="$CASE_DIR/bin"
  mkdir -p "$CASE_DIR" "$CASE_TMUX_TMP"
  make_app "$CASE_APP" "$CASE_DIR/app-origin.git"
  make_primary_root "$CASE_PRIMARY_ROOT" "$mode"
  make_primary_home "$CASE_HOME"
  make_launch_boundary "$fakebin"

  prompt=$(cat <<PROMPT
Captain request: conduct an exhaustive review of the project at $CASE_APP.
Fixture fact: use task ID $TASK_ID for this request.
Fixture fact: the authoritative Firstmate config directory for this isolated session is $CASE_HOME/config; read its crew-dispatch profile before selecting the worker.
PROMPT
)
  (
    unset NO_MISTAKES_GATE NO_MISTAKES_RUN_ID TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_SESSION
    export FM_GATE_REFUSE_BYPASS=1
    export FM_HOME="$CASE_HOME"
    export FM_ROOT_OVERRIDE="$CASE_PRIMARY_ROOT"
    export FM_DATA_OVERRIDE="$CASE_HOME/data"
    export FM_STATE_OVERRIDE="$CASE_HOME/state"
    export FM_CONFIG_OVERRIDE="$CASE_HOME/config"
    export FM_PROJECTS_OVERRIDE="$CASE_HOME/projects"
    export TMUX_TMPDIR="$CASE_TMUX_TMP"
    export PATH="$fakebin:$ORIGINAL_PATH"
    cd "$CASE_PRIMARY_ROOT" || exit 1
    "$REAL_PI" --print --approve --no-session --no-extensions \
      --no-skills --skill .agents/skills --tools bash \
      --model openai-codex/gpt-5.6-terra --thinking high "$prompt"
  ) > "$CASE_TRANSCRIPT" 2>&1 || fail "primary skill turn failed: $(tail -20 "$CASE_TRANSCRIPT")"

  wait_for_file "$CASE_META" "primary did not execute the real worker spawn interface"
  CASE_WORKER=$(meta_value worktree)
  [ -n "$CASE_WORKER" ] || fail "worker metadata did not name a worktree"
  CASE_GSD_LOG=$(cd "$CASE_WORKER" && git rev-parse --git-path fm-exhaustive-review-routing.log) \
    || fail "could not resolve the worker handoff log"
  case "$CASE_GSD_LOG" in
    /*) ;;
    *) CASE_GSD_LOG="$CASE_WORKER/$CASE_GSD_LOG" ;;
  esac
  wait_for_file "$CASE_GSD_LOG" "spawned worker did not process the real launch brief"
}

run_case green intact
assert_real_route
worker_contract_is_complete || fail "worker did not hand off the real project SHA to GSD: $(tr '\n' ';' < "$CASE_GSD_LOG")"
pass "real Pi primary used fm-brief and fm-spawn to hand off the immutable project SHA from an isolated worker"

run_case red broken
assert_real_route
if worker_contract_is_complete; then
  fail "negative control passed after removing the exhaustive-review routing policy"
fi
grep -Fxq 'REJECTED_MISSING_ROUTING_POLICY' "$CASE_GSD_LOG" \
  || fail "negative control did not record missing immutable-SHA and canonical-ledger policy: $(tr '\n' ';' < "$CASE_GSD_LOG")"
pass "removing the routing policy produced required red evidence at the worker boundary"

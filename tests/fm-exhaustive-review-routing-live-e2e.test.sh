#!/usr/bin/env bash
# Credentialed behavior regression for the exhaustive-review routing skill.
#
# This drives the public Pi skill-loading interface through an actual primary
# agent turn. That agent must dispatch through the normal brief and spawn
# interfaces, and the spawn shim starts the separate configured worker runtime
# which invokes the GSD review shim against an immutable commit. The logs prove
# the reviewed work stays below the Firstmate worker boundary without inspecting
# instruction-source bytes.
set -u

if [ "${FM_EXHAUSTIVE_REVIEW_ROUTING_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_EXHAUSTIVE_REVIEW_ROUTING_LIVE_E2E=1 to run the credentialed exhaustive-review routing regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OWNER="$ROOT/.agents/skills/firstmate-exhaustive-review/SKILL.md"
TASK_ID=exhaustive-review-e2e
TMP_BASE=${TMPDIR:-/tmp}
LAB=$(mktemp -d "${TMP_BASE%/}/fm-exhaustive-review-routing-live.XXXXXX")
PRIMARY="$LAB/primary"
WORKER="$LAB/worker"
APP="$LAB/app"
FAKEBIN="$LAB/fakebin"
PRIMARY_TRANSCRIPT="$LAB/primary.out"
WORKER_TRANSCRIPT="$LAB/worker.out"
BRIEF_LOG="$LAB/brief.log"
SPAWN_LOG="$LAB/spawn.log"
GSD_LOG="$LAB/gsd.log"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

cleanup() {
  rm -rf "$LAB"
}
trap cleanup EXIT

command -v pi >/dev/null 2>&1 || fail "pi not found"
command -v git >/dev/null 2>&1 || fail "git not found"
[ -f "$OWNER" ] || fail "firstmate-exhaustive-review skill not found"

mkdir -p "$PRIMARY/.agents/skills/firstmate-exhaustive-review" \
  "$WORKER/.agents/skills/firstmate-exhaustive-review" "$PRIMARY/bin" "$APP" "$FAKEBIN"
cp "$OWNER" "$PRIMARY/.agents/skills/firstmate-exhaustive-review/SKILL.md"
cp "$OWNER" "$WORKER/.agents/skills/firstmate-exhaustive-review/SKILL.md"
printf '%s\n' 'fixture source' > "$APP/source.txt"
git -C "$APP" init -q
git -C "$APP" config user.email fmtest@example.invalid
git -C "$APP" config user.name fmtest
git -C "$APP" add source.txt
git -C "$APP" commit -q -m "test: review fixture" || fail "could not commit project review fixture"
git -C "$WORKER" init -q
git -C "$WORKER" config user.email fmtest@example.invalid
git -C "$WORKER" config user.name fmtest
git -C "$WORKER" add .agents
git -C "$WORKER" commit -q -m "test: worker skill fixture" || fail "could not commit worker skill fixture"
IMMUTABLE_SHA=$(git -C "$WORKER" rev-parse HEAD) || fail "could not resolve immutable worker SHA"
export APP BRIEF_LOG FAKEBIN GSD_LOG IMMUTABLE_SHA PRIMARY SPAWN_LOG TASK_ID WORKER WORKER_TRANSCRIPT

cat > "$PRIMARY/bin/fm-brief.sh" <<'SH'
#!/usr/bin/env bash
set -eu
[ "${1:-}" = "$TASK_ID" ] || exit 64
case " $* " in
  *' --mode direct-PR '*) ;;
  *) exit 65 ;;
esac
printf 'cwd=%s\nargv=%s\n' "$PWD" "$*" > "$BRIEF_LOG"
SH
chmod +x "$PRIMARY/bin/fm-brief.sh"

cat > "$FAKEBIN/gsd-code-review" <<'SH'
#!/usr/bin/env bash
set -eu
printf 'cwd=%s\nargv=%s\n' "$PWD" "$*" > "$GSD_LOG"
[ "$PWD" = "$WORKER" ] || exit 71
[ "${1:-}" = "--sha" ] || exit 72
[ "${2:-}" = "$IMMUTABLE_SHA" ] || exit 73
[ "$#" -eq 2 ] || exit 74
printf 'sha=%s\n' "$2" >> "$GSD_LOG"
printf 'GSD_REVIEW_EXECUTED\n'
SH
chmod +x "$FAKEBIN/gsd-code-review"

cat > "$PRIMARY/bin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
set -eu

value_for() {
  local option=$1 value
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      "$option")
        [ "$#" -ge 2 ] || return 1
        printf '%s\n' "$2"
        return 0
        ;;
      "$option"=*)
        printf '%s\n' "${1#*=}"
        return 0
        ;;
    esac
    shift
  done
  return 1
}

[ "${1:-}" = "$TASK_ID" ] || exit 81
[ "${2:-}" = "$APP" ] || exit 82
[ "$(value_for --mode "$@")" = "direct-PR" ] || exit 83
[ "$(value_for --yolo "$@")" = "off" ] || exit 84
[ "$(value_for --harness "$@")" = "pi" ] || exit 85
[ "$(value_for --model "$@")" = "openai-codex/gpt-5.6-terra" ] || exit 86
[ "$(value_for --effort "$@")" = "high" ] || exit 87
[ "$(value_for --backend "$@")" = "herdr" ] || exit 88
printf 'cwd=%s\nargv=%s\n' "$PWD" "$*" > "$SPAWN_LOG"

(
  cd "$WORKER"
  PATH="$FAKEBIN:$PATH" gsd-code-review --sha "$IMMUTABLE_SHA"
) > "$WORKER_TRANSCRIPT" 2>&1
grep -Fxq 'GSD_REVIEW_EXECUTED' "$WORKER_TRANSCRIPT"
SH
chmod +x "$PRIMARY/bin/fm-spawn.sh"

primary_prompt=$(cat <<'PROMPT'
You are the primary Firstmate handling a captain request for an exhaustive review.
Load the firstmate-exhaustive-review skill available through the current Pi skill directory before acting.
The intake has already resolved the task ID as exhaustive-review-e2e, project as the APP environment path, mode as direct-PR, yolo as off, and the configured dispatch profile as harness pi, model openai-codex/gpt-5.6-terra, effort high, and backend herdr.
Create the task brief with bin/fm-brief.sh and then dispatch the worker only with bin/fm-spawn.sh using those resolved values.
The spawn shim starts the worker GSD review itself, so do not invoke gsd-code-review directly, use no generic delegation tool, and do not edit files.
After the spawn command returns, reply with exactly PRIMARY_DISPATCH_DONE.
PROMPT
)
(
  cd "$PRIMARY"
  PATH="$FAKEBIN:$PATH" pi --print --approve --no-session --no-context-files --no-extensions \
    --no-skills --skill .agents/skills --tools bash \
    --model openai-codex/gpt-5.6-terra --thinking high "$primary_prompt"
) > "$PRIMARY_TRANSCRIPT" 2>&1 || fail "primary skill turn failed: $(tail -20 "$PRIMARY_TRANSCRIPT")"

grep -Fxq 'PRIMARY_DISPATCH_DONE' "$PRIMARY_TRANSCRIPT" \
  || fail "primary did not confirm the worker dispatch: $(tail -20 "$PRIMARY_TRANSCRIPT")"
[ -s "$BRIEF_LOG" ] || fail "primary did not execute the normal brief interface"
[ -s "$SPAWN_LOG" ] || fail "primary did not execute the normal worker spawn interface"
[ -s "$GSD_LOG" ] || fail "worker did not execute the GSD review interface: $(tail -20 "$WORKER_TRANSCRIPT")"
grep -Fxq "cwd=$WORKER" "$GSD_LOG" || fail "GSD review did not run inside the worker directory: $(tr '\n' ';' < "$GSD_LOG")"
grep -Fxq "sha=$IMMUTABLE_SHA" "$GSD_LOG" || fail "GSD review did not receive the immutable worker SHA"
git -C "$WORKER" status --porcelain | grep -q . && fail "worker review changed its source tree"
git -C "$APP" status --porcelain | grep -q . && fail "primary review changed the project source tree"
pass "real Pi primary dispatched the configured worker, and only that worker ran the immutable-SHA GSD review"

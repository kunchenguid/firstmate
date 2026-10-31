#!/usr/bin/env bash
# tests/fm-model-pin-readback-live-e2e.test.sh - opt-in guard proving the vendor
# facts bin/fm-spawn.sh's pinned-model assertion reads a model back through:
#   - Pi writes each assistant turn's provider and model into its own session
#     record, and a resume launched with a different --model runs its new turn on
#     that model while the records it inherited keeps naming the old one. Reading
#     the resumed turn is therefore the only read that answers "what model came
#     up", and a changed pin is a legitimate re-pin rather than a refusal.
#   - Claude Code writes a launch's transcript at
#     <config-dir>/projects/<slug>/<session-id>.jsonl, which is the address a
#     pinned launch's own --session-id makes readable, and stamps assistant
#     records with the model the API reported for that response.
#
# Why this file exists: both facts are vendor-emitted, and the portable
# regressions in tests/fm-control-relaunch.test.sh and
# tests/fm-spawn-dispatch-profile.test.sh can only replay the assumption they were
# written with. pi 1.4.0 and claude 2.1.314 are the releases recorded in
# docs/verification/runtime-backends.md "Pinned model on a resumed session"; this
# guard is the command that refreshes that record, and it fails naming the harness
# and version rather than passing over a moved surface:
#   FM_MODEL_PIN_READBACK_LIVE=1 bin/fm-test-run.sh \
#     tests/fm-model-pin-readback-live-e2e.test.sh
#
# Pi is asked on this host's own default model and then resumed onto a second
# model of the same provider, and Claude once on the cheap pin below, so the guard
# spends a few tokens and is opt-in; an absent harness is reported by name and
# none of its half runs.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_MODEL_PIN_READBACK_LIVE pi jq

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB=$(fm_test_tmproot fm-model-pin-readback)
PI=$(command -v pi)
PI_VERSION=$("$PI" --version 2>/dev/null | head -1 | tr -d '\r')
[ -n "$PI_VERSION" ] || PI_VERSION=unknown
WHO="pi $PI_VERSION"
# The Claude half's pin. A host whose Claude is authorized for another model can
# name it here; the guard reports which model answered either way.
CLAUDE_PIN=${FM_MODEL_PIN_READBACK_CLAUDE_MODEL:-claude-haiku-4-5}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

# The provider and model of every assistant turn in a session record, oldest
# first, as `<provider>/<model>`. This is the field pair the assertion reads: Pi
# writes the turn as `.type == "message"` with a provider, Claude Code writes it
# as `.type == "assistant"` with a provider named only when it reports one.
assistant_models() {  # <session-record>
  jq -r 'select((.type == "message" or .type == "assistant")
      and .message.role == "assistant")
    | (.message.provider // "") + "/" + (.message.model // "")' "$1" 2>/dev/null
}

# --- Pi: a resumed turn reports the pin, and the history it inherited does not --

pi_ask() {  # <session-dir> <model-or-empty> <prompt> [extra launch arguments...]
  local sessions=$1 model=$2 prompt=$3
  shift 3
  local -a args=(--print --no-tools --no-extensions --no-skills --no-context-files
    --session-dir "$sessions")
  [ -z "$model" ] || args+=(--model "$model")
  # A harness left on the caller's stdin would swallow the candidate list a
  # while-read loop is feeding from a process substitution.
  "$PI" "${args[@]}" "$@" "$prompt" </dev/null >/dev/null
}

PI_SESSIONS=$LAB/pi-sessions
# A model this host's credentials answer is discovered by asking: a stored
# credential can report ready and still fail to refresh, and a provider can
# refuse one model or hold it behind a concurrency cap while answering another,
# so a real turn is the only probe. The host's own default model is tried first,
# then the catalog in its own order; FM_MODEL_PIN_READBACK_PI_MODEL names the
# first model outright.
pi_models() {  # -> "provider/model" candidates, in the catalog's own order
  "$PI" --list-models 2>/dev/null |
    awk 'NR > 1 && $1 != "" && $2 != "" { print $1 "/" $2 }'
}

pi_first_turn() {  # <model-or-empty> -> 0 when a session record now exists
  rm -rf "$PI_SESSIONS"
  mkdir -p "$PI_SESSIONS"
  pi_ask "$PI_SESSIONS" "$1" 'reply with exactly: OK' 2>"$LAB/pi-last-error" || return 1
  PI_RECORD=$(find "$PI_SESSIONS" -type f -name '*.jsonl' -print -quit 2>/dev/null)
  [ -n "$PI_RECORD" ]
}

# A provider can refuse one arriving turn with a concurrency cap and answer the
# next, so a single refusal is not the harness's verdict. Twice is enough to tell
# a transient refusal from a model this host cannot run.
pi_try_turn() {  # <model-or-empty> -> 0 when a session record now exists
  pi_first_turn "$1" && return 0
  sleep 2
  pi_first_turn "$1"
}

PI_STARTED=0
if [ -n "${FM_MODEL_PIN_READBACK_PI_MODEL:-}" ]; then
  pi_try_turn "$FM_MODEL_PIN_READBACK_PI_MODEL" && PI_STARTED=1
else
  pi_try_turn '' && PI_STARTED=1
  while [ "$PI_STARTED" -eq 0 ] && IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    pi_try_turn "$candidate" && PI_STARTED=1
  done < <(pi_models | awk -F/ '!seen[$1]++' | head -n 8)
fi
[ "$PI_STARTED" -eq 1 ] || {
  tail -n 2 "$LAB/pi-last-error" >&2 2>/dev/null
  fail "$WHO answered no model this guard could read; set FM_MODEL_PIN_READBACK_PI_MODEL to one its credentials answer"
}
PI_RECORD=$(find "$PI_SESSIONS" -type f -name '*.jsonl' -print -quit 2>/dev/null)
[ -n "$PI_RECORD" ] || fail "$WHO wrote no session record under the session dir it was given"
PI_FIRST=$(assistant_models "$PI_RECORD" | tail -n 1)
case "$PI_FIRST" in
  '' | / | */) fail "$WHO recorded no assistant provider/model in $PI_RECORD, which is the field the assertion reads" ;;
esac
PI_PROVIDER=${PI_FIRST%%/*}

# The pin to resume onto: the first other model this host actually answers, with
# the A provider's own catalog tried before the rest. Readiness is spent on the
# real resume rather than on an auth probe, because a credential can report ready
# and still fail to refresh on use (a Pi OAuth store carried from another host is
# the case here).
PI_PIN_MODEL=''
PI_RESUMED=''
while IFS= read -r candidate; do
  [ -n "$candidate" ] || continue
  [ "$candidate" = "$PI_FIRST" ] && continue
  pi_ask "$PI_SESSIONS" "$candidate" 'reply with exactly: DONE' \
    --session "$PI_RECORD" 2>/dev/null || {
    sleep 2
    pi_ask "$PI_SESSIONS" "$candidate" 'reply with exactly: DONE' \
      --session "$PI_RECORD" 2>/dev/null
  } || continue
  PI_PIN_MODEL=$candidate
  PI_RESUMED=$(assistant_models "$PI_RECORD" | tail -n 1)
  break
done < <(
  {
    pi_models | awk -v provider="$PI_PROVIDER" 'index($0, provider "/") == 1'
    # Then one model per other provider: a provider whose stored credential cannot
    # refresh would otherwise spend every remaining attempt on its own catalog.
    pi_models | awk -F/ '!seen[$1]++'
  } | head -n 12
)
[ -n "$PI_PIN_MODEL" ] ||
  fail "$WHO resumed onto no other model this host answers, so nothing was proven about a re-pin"
PI_INHERITED=$(assistant_models "$PI_RECORD" | head -n 1)
[ "$PI_INHERITED" = "$PI_FIRST" ] ||
  fail "$WHO rewrote the inherited turn's model from $PI_FIRST to $PI_INHERITED; the assertion separates history from the resumed turn"
[ "$PI_RESUMED" = "$PI_PIN_MODEL" ] ||
  fail "$WHO resumed a session pinned to $PI_PIN_MODEL but its newest turn reports '$PI_RESUMED'"
printf '# %s: inherited turn %s, resumed turn %s in one record\n' \
  "$WHO" "$PI_INHERITED" "$PI_RESUMED"
pass "$WHO: a resumed session's own turn carries the model it was pinned to, over an inherited record naming another"

# --- Claude: a pinned launch's transcript is readable at its own session id ----

CLAUDE=$(command -v claude 2>/dev/null || true)
if [ -z "$CLAUDE" ]; then
  printf '# claude is not installed; the Claude half of this guard did not run\n'
else
  CLAUDE_VERSION=$("$CLAUDE" --version 2>/dev/null | head -1 | tr -d '\r')
  [ -n "$CLAUDE_VERSION" ] || CLAUDE_VERSION=unknown
  CLAUDE_WHO="claude $CLAUDE_VERSION"
  CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR:-${HOME:-$PWD}/.claude}
  CLAUDE_SESSION_ID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null ||
    uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]')
  case "$CLAUDE_SESSION_ID" in
    ????????-????-????-????-????????????) ;;
    *) fail "$CLAUDE_WHO check could not mint a session id to launch with" ;;
  esac
  ( cd "$LAB" && "$CLAUDE" --print --model "$CLAUDE_PIN" --session-id "$CLAUDE_SESSION_ID" \
    'reply with exactly: OK' ) >"$LAB/claude.out" 2>&1 || true
  CLAUDE_RECORD=$(find "$CLAUDE_CONFIG_DIR/projects" -type f \
    -name "$CLAUDE_SESSION_ID.jsonl" -print -quit 2>/dev/null)
  [ -n "$CLAUDE_RECORD" ] || {
    tail -n 5 "$LAB/claude.out" >&2 2>/dev/null
    fail "$CLAUDE_WHO wrote no <config-dir>/projects/*/$CLAUDE_SESSION_ID.jsonl for a launch carrying --session-id, which is the address the assertion reads"
  }
  CLAUDE_REPORTED=$(assistant_models "$CLAUDE_RECORD" | tail -n 1)
  case "$CLAUDE_REPORTED" in
    '' | / | */)
      fail "$CLAUDE_WHO wrote no assistant model to $CLAUDE_RECORD, which is the field the assertion reads"
      ;;
    '<synthetic>' | */'<synthetic>')
      # A session that ran no model (an exhausted limit, a refused request)
      # records <synthetic>. The assertion reads that as no statement, never as a
      # model that ran, so there is nothing here to compare a pin against.
      printf '# %s recorded <synthetic> for pin %s, so no model ran and the assertion would record unverified\n' \
        "$CLAUDE_WHO" "$CLAUDE_PIN"
      ;;
  esac
  case "$CLAUDE_REPORTED" in
    *'<synthetic>'*) ;;
    "$CLAUDE_PIN" | "$CLAUDE_PIN"-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9])
      printf '# %s reported %s for pin %s\n' "$CLAUDE_WHO" "$CLAUDE_REPORTED" "$CLAUDE_PIN"
      ;;
    *)
      fail "$CLAUDE_WHO reported '$CLAUDE_REPORTED' for a launch pinned to $CLAUDE_PIN; the assertion would record a mismatch"
      ;;
  esac
  pass "$CLAUDE_WHO: a pinned launch reads back the model its own session id addresses"
fi

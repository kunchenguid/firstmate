#!/usr/bin/env bash
# fm-spawn-gate-lib.sh - the ONE owner of fm-spawn's pre-launch gate chain and
# of the account a spawned agent is launched on.
#
# Usage (sourced by bin/fm-spawn.sh, never executed):
#   . bin/fm-spawn-gate-lib.sh
#   fm_spawn_konto_aufloesen <kind> <harness> <konto-flag|""> <projektpfad>
#       -> "<speicher><TAB><CLAUDE_CONFIG_DIR|->" on stdout, 0 on success;
#          1 with a loud, actionable refusal on stderr otherwise.
#          "-<TAB>-" means: this harness runs on no Anthropic account.
#   fm_spawn_gates_check task=<id> project=<name> kind=<ship|scout|secondmate>
#                        [account=<speicher>] [brief=<pfad>] [subject=<text>]
#       -> 0 free, 1 blocked (the refusal is already printed, loud, with the
#          source it comes from and the way out).
#
# WHY. Every rollback of 24.-25.08. had the rule in place and no READER at the
# point of action: fm-spawn read only state/.fleet-stop, so a pinned captain
# order (O-0083, account seat), a live reservation, an open captain remark, and
# a ship brief with no acceptance block all passed unseen, and the account came
# from whatever CLAUDE_CONFIG_DIR the invoking session happened to carry. This
# file is that missing reader: it asks the four existing gates in a fixed order
# and refuses at the FIRST one that holds, and it resolves the account from the
# ledger instead of inheriting it.
#
# Gate chain (fixed order, first block wins):
#   (a) order      - fm_order_gate_check (bin/fm-order-gate-lib.sh)
#   (b) reservation- fm_reservierung_check (bin/fm-reservierung-lib.sh)
#   (c) remark     - fm_brett_vollzug_check (bin/fm-brett-vollzug.sh)
#   (d) acceptance - bin/fm-abnahme.sh check-brief (ship spawns only)
#
# Arming (this header is the single owner of the two flags it names):
#   state/.tor-order-scharf         arms (a). Missing = silent passage.
#   state/.tor-reservierung-scharf  arms (b). Missing = silent passage.
#   (c) and (d) are gate SCRIPTS that own and check their own flags
#   (state/.tor-bemerkung-scharf, state/.tor-abnahme-scharf); this file never
#   double-flags them - it only asks, and prints what they answer.
# An unarmed sub-gate is not asked at all, so it writes no Tor-Log line either:
# "built but standing down" must stay distinguishable from "looked and passed".
#
# Loudness (L33/L14): a sub-gate that cannot READ its own source (unreadable
# order book, unreadable reservation) is a refusal, not a pass - a gate never
# guesses what the captain meant. A missing gate script is the one exception:
# it is an unbuilt gate, warned about once and passed, because failing closed on
# a tool that was never installed would stop the fleet over nothing.
#
# Account contract (AGENTS.md "Accounts and day close": the account is a managed
# state, never inherited):
#   - claude:    role offiziere-worker from config/konten.tsv (every spawn this
#                tool makes is a worker or an officer; the firstmate seat is
#                moved by bin/fm-sitzwechsel.sh, never by a spawn). The resolved
#                storage path becomes the launch's CLAUDE_CONFIG_DIR prefix.
#   - claude-ox: its launch template pins the wrapper `claude1`, which exports
#                its own store; the storage is resolved BACK from that wrapper
#                name through the ledger, so the account is still recorded and
#                still gate-checkable, and no prefix is added.
#   - anything else (codex, pi, grok, ...): no Anthropic account, "-".
#   - --konto <speicher> overrides the role lookup for claude, and for claude-ox
#     it must name the storage its wrapper already pins (anything else would
#     record an account the launch does not use).
#   - a missing config/konten.tsv is a LOUD abort - never a silent fall back to
#     the inherited CLAUDE_CONFIG_DIR, which is exactly the drift that put a
#     worker on the firstmate seat.
#   - before the launch, fm_konto_startfaehig decides whether a session can
#     really start on that seat; a seat that would drop the agent into the
#     onboarding wizard fails LOUD here with the instruction, instead of hanging
#     silently in a pane nobody watches.
#
# This file is a LIBRARY: it only ever returns, never exits, so a caller under
# `set -e` takes every verdict as a return value (`if ! fm_spawn_gates_check ...`).

FM_SPAWN_GATE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-tor-log-lib.sh
. "$FM_SPAWN_GATE_LIB_DIR/fm-tor-log-lib.sh"
# shellcheck source=bin/fm-order-gate-lib.sh
. "$FM_SPAWN_GATE_LIB_DIR/fm-order-gate-lib.sh"
# shellcheck source=bin/fm-reservierung-lib.sh
. "$FM_SPAWN_GATE_LIB_DIR/fm-reservierung-lib.sh"
# shellcheck source=bin/fm-konten-lib.sh
. "$FM_SPAWN_GATE_LIB_DIR/fm-konten-lib.sh"

fm_spawn_gate_home() { # -> the home whose state/ and ledger are read
  if [ -n "${FM_HOME:-}" ]; then
    printf '%s' "$FM_HOME"
  else
    (cd "$FM_SPAWN_GATE_LIB_DIR/.." && pwd)
  fi
}

fm_spawn_gate_state() { # -> that home's state directory
  if [ -n "${FM_STATE_OVERRIDE:-}" ]; then
    printf '%s' "$FM_STATE_OVERRIDE"
  else
    printf '%s/state' "$(fm_spawn_gate_home)"
  fi
}

fm_spawn_gate_armed() { # <tor> -> 0 when state/.tor-<tor>-scharf exists
  [ -f "$(fm_spawn_gate_state)/.tor-$1-scharf" ]
}

# fm_spawn_brief_subject <brief>: the remark gate matches on a subject line, and
# a brief has no subject FIELD - its title is the first bold run of its task
# section. No bold run means no subject, and the gate then matches on task= only
# (a weak guessed subject would block foreign work by accident).
fm_spawn_brief_subject() {
  local brief=$1
  [ -n "$brief" ] && [ -f "$brief" ] || return 0
  sed -n 's/.*\*\*\([^*][^*]*\)\*\*.*/\1/p' "$brief" | head -n 1
  return 0
}

# fm_spawn_konto_fuer_wrapper <wrapper>: the storage whose launcher is <wrapper>.
fm_spawn_konto_fuer_wrapper() {
  local gesucht=$1 speicher wrapper
  while IFS= read -r speicher; do
    [ -n "$speicher" ] || continue
    wrapper=$(fm_konto_wrapper "$speicher" 2>/dev/null) || continue
    if [ "$wrapper" = "$gesucht" ]; then
      printf '%s\n' "$speicher"
      return 0
    fi
  done < <(fm_konten_speicher 2>/dev/null)
  return 1
}

fm_spawn_konto_aufloesen() { # <kind> <harness> <konto-flag> <projektpfad>
  local kind=${1:-} harness=${2:-} konto_arg=${3:-} projekt=${4:-}
  local akte speicher pfad prefix='-'

  case "$harness" in
    claude|claude-ox) ;;
    *)
      if [ -n "$konto_arg" ]; then
        echo "error: --konto names an Anthropic storage from config/konten.tsv and applies only to the claude harness family; harness '$harness' runs on no such account" >&2
        return 1
      fi
      printf -- '-\t-\n'
      return 0
      ;;
  esac

  akte=$(fm_konten_akte)
  if [ ! -f "$akte" ]; then
    echo "error: spawn refused - the account ledger $akte is missing, so this spawn's account cannot be resolved." >&2
    echo "       The account is a managed state, never inherited (AGENTS.md, Accounts and day close): falling back to the invoking session's CLAUDE_CONFIG_DIR is what put a worker on the firstmate seat." >&2
    echo "       Anweisung: restore config/konten.tsv in this home (one row per storage: speicher/pfad/anthropic_konto/rolle/bemerkung), then respawn." >&2
    fm_tor_log spawn konten-akte rot - "kind=$kind harness=$harness akte=$akte"
    return 1
  fi

  if [ "$harness" = claude-ox ]; then
    # The claude-ox launch template pins the wrapper `claude1`, which exports its
    # own CLAUDE_CONFIG_DIR; resolve that wrapper back to its ledger row so the
    # account is recorded and gate-checkable without a second, contradicting
    # prefix on the launch.
    if ! speicher=$(fm_spawn_konto_fuer_wrapper claude1); then
      echo "error: spawn refused - no row in $akte carries the wrapper 'claude1', which the claude-ox launch pins." >&2
      echo "       Anweisung: add the konto-1 row to the ledger (or launch on --harness claude with an explicit --konto), then respawn." >&2
      fm_tor_log spawn konto-ox-wrapper rot - "kind=$kind harness=$harness"
      return 1
    fi
    if [ -n "$konto_arg" ] && [ "$konto_arg" != "$speicher" ]; then
      echo "error: spawn refused - --konto $konto_arg contradicts claude-ox, whose wrapper 'claude1' pins $speicher; recording an account the launch does not use is worse than no record." >&2
      echo "       Anweisung: drop --konto for claude-ox, or spawn --harness claude --konto $konto_arg." >&2
      fm_tor_log spawn konto-ox-wrapper rot - "kind=$kind harness=$harness konto=$konto_arg"
      return 1
    fi
  elif [ -n "$konto_arg" ]; then
    speicher=$konto_arg
    if ! fm_konten_feld "$speicher" 1 >/dev/null; then
      echo "error: spawn refused - --konto $speicher is not a storage in $akte (the reason is above)." >&2
      echo "       Anweisung: pass a speicher key the ledger lists, or drop --konto to take the offiziere-worker seat." >&2
      fm_tor_log spawn konto-unbekannt rot - "kind=$kind harness=$harness konto=$speicher"
      return 1
    fi
  else
    # Every spawn this tool makes is a worker or an officer. The firstmate seat
    # is never taken by a spawn; it moves only through bin/fm-sitzwechsel.sh.
    if ! speicher=$(fm_konto_fuer_rolle offiziere-worker); then
      echo "error: spawn refused - no storage in $akte carries the role offiziere-worker, so this spawn has no seat." >&2
      echo "       Anweisung: give one row the role offiziere-worker (or pass --konto <speicher> for this one launch), then respawn." >&2
      fm_tor_log spawn konto-rolle rot - "kind=$kind harness=$harness rolle=offiziere-worker"
      return 1
    fi
  fi

  if ! pfad=$(fm_konto_pfad "$speicher"); then
    echo "error: spawn refused - storage $speicher has no readable path in $akte (the reason is above)." >&2
    fm_tor_log spawn konto-pfad rot - "kind=$kind harness=$harness konto=$speicher"
    return 1
  fi

  if ! fm_konto_startfaehig "$speicher" "$projekt"; then
    echo "error: spawn refused - account $speicher ($pfad) cannot START a session in $projekt; the missing half is named above." >&2
    echo "       Anweisung: run '$(fm_konto_wrapper "$speicher" 2>/dev/null || printf 'claude')' once in $projekt, finish onboarding and accept the trust dialog, then respawn. A silent launch here parks the agent in the setup wizard where nobody sees it." >&2
    fm_tor_log spawn konto-startfaehig rot - "kind=$kind harness=$harness konto=$speicher projekt=$projekt"
    return 1
  fi

  [ "$harness" = claude-ox ] || prefix=$pfad
  fm_tor_log spawn konto-startfaehig gruen - "kind=$kind harness=$harness konto=$speicher projekt=$projekt"
  printf '%s\t%s\n' "$speicher" "$prefix"
  return 0
}

# fm_spawn_bemerkung_check <task> [subject]: ask the remark gate. It is SOURCED
# in a subshell, not run as a CLI, because it carries script-level names (usage,
# die_usage, STATE) that must never land in fm-spawn's namespace - and a subshell
# is also what keeps its own locals out of this library's.
fm_spawn_bemerkung_check() {
  local task=$1 subject=${2:-}
  (
    # Deliberately not followed by ShellCheck (source=/dev/null): that script is
    # a CLI, and its top-level assignments (FM_HOME, STATE, SCRIPT_DIR) exist
    # only inside this subshell - following them would report every later use of
    # those names in a sourcing caller as "modified in a subshell".
    # shellcheck source=/dev/null
    . "$FM_SPAWN_GATE_LIB_DIR/fm-brett-vollzug.sh"
    bctx=("task=$task")
    [ -z "$subject" ] || bctx+=("subject=$subject")
    fm_brett_vollzug_check "${bctx[@]}"
  )
}

fm_spawn_gates_check() { # task= project= kind= [account=] [brief=] [subject=]
  local task='' project='' kind='' account='' brief='' subject='' subject_set=0
  local arg key val
  for arg in "$@"; do
    key=${arg%%=*}
    val=${arg#*=}
    case "$key" in
      task) task=$val ;;
      project) project=$val ;;
      kind) kind=$val ;;
      account) account=$val ;;
      brief) brief=$val ;;
      subject) subject=$val; subject_set=1 ;;
      *) echo "error: fm_spawn_gates_check got unknown context '$arg' (keys: task project kind account brief subject)" >&2; return 1 ;;
    esac
  done
  if [ -z "$task" ]; then
    echo "error: fm_spawn_gates_check needs task=<id>" >&2
    return 1
  fi
  # "-" is fm_spawn_konto_aufloesen's "this harness has no account": an order
  # about accounts must not match a launch that runs on none.
  [ "$account" != - ] || account=''
  if [ "$subject_set" -eq 0 ]; then
    subject=$(fm_spawn_brief_subject "$brief")
  fi

  local out rc id wort wort_id ref

  # (a) captain orders. The wording is the truth; the enforce line is only its
  # machine-readable half, so the refusal quotes the order itself.
  if fm_spawn_gate_armed order; then
    local octx=(spawn "task=$task")
    [ -z "$project" ] || octx+=("project=$project")
    [ -z "$account" ] || octx+=("account=$account")
    rc=0
    out=$(fm_order_gate_check "${octx[@]}") || rc=$?
    if [ "$rc" -eq 2 ]; then
      echo "SPAWN-TOR ROT (order): the order book could not be read (reason above); a gate never guesses what the captain meant." >&2
      echo "  Ausweg: repair the order file it names (bin/fm-order.sh show), then respawn." >&2
      return 1
    fi
    if [ "$rc" -ne 0 ]; then
      echo "SPAWN-TOR ROT (order): a standing captain order shuts this spawn." >&2
      id=''
      while IFS=$'\t' read -r wort_id wort; do
        [ -n "$wort_id" ] || continue
        [ -n "$id" ] || id=$wort_id
        printf '  %s (Wortlaut): "%s"\n' "$wort_id" "$wort" >&2
      done <<< "${out%$'\n'}"
      printf '  Kontext: spawn task=%s project=%s account=%s\n' "$task" "${project:--}" "${account:--}" >&2
      printf '  Ausweg: record a captain allow-order or close %s (bin/fm-order.sh), then respawn.\n' "${id:-O-xxxx}" >&2
      return 1
    fi
  fi

  # (b) reservations. The holder of a reservation is not blocked by his own, so
  # the task id travels as holder=.
  if fm_spawn_gate_armed reservierung; then
    local rctx=(spawn "task=$task" "holder=$task")
    [ -z "$project" ] || rctx+=("project=$project")
    rc=0
    out=$(fm_reservierung_check "${rctx[@]}") || rc=$?
    if [ "$rc" -eq 2 ]; then
      echo "SPAWN-TOR ROT (reservierung): a reservation could not be read (reason above); a gate never guesses what is reserved." >&2
      echo "  Ausweg: repair the reservation file it names under state/reservierungen/, then respawn." >&2
      return 1
    fi
    if [ "$rc" -ne 0 ]; then
      echo "SPAWN-TOR ROT (reservierung): a live reservation holds this ground." >&2
      while IFS=$'\t' read -r ref wort; do
        [ -n "$ref" ] || continue
        printf '  %s: %s\n' "$ref" "$wort" >&2
      done <<< "${out%$'\n'}"
      printf '  Kontext: spawn task=%s project=%s\n' "$task" "${project:--}" >&2
      echo "  Ausweg: wait for the reservation to expire, or have its holder release it (state/reservierungen/), then respawn." >&2
      return 1
    fi
  fi

  # (c) open captain remarks. That script owns its own arming flag and prints the
  # remark text and its exit itself; it is sourced in a SUBSHELL because it
  # carries script-level names (usage, die_usage, STATE) that must never land in
  # the caller's namespace.
  if [ -f "$FM_SPAWN_GATE_LIB_DIR/fm-brett-vollzug.sh" ]; then
    if ! fm_spawn_bemerkung_check "$task" "$subject"; then
      echo "SPAWN-TOR ROT (bemerkung): an open captain remark holds this task; its text and its way out are printed above." >&2
      return 1
    fi
  else
    echo "warning: bin/fm-brett-vollzug.sh is missing - the remark gate could not be asked for $task" >&2
  fi

  # (d) acceptance block of a ship brief. Yellow (legacy / unverifiable kind) is
  # a warning and passes: an old brief must be finishable, never silently green.
  if [ "$kind" = ship ] && [ -x "$FM_SPAWN_GATE_LIB_DIR/fm-abnahme.sh" ]; then
    local actx=(check-brief "$task")
    [ -z "$brief" ] || actx+=(--brief "$brief")
    rc=0
    out=$(FM_HOME="$(fm_spawn_gate_home)" FM_STATE_OVERRIDE="$(fm_spawn_gate_state)" \
      "$FM_SPAWN_GATE_LIB_DIR/fm-abnahme.sh" "${actx[@]}" 2>&1) || rc=$?
    case "$rc" in
      0) ;;
      3)
        echo "warning: acceptance gate is YELLOW for $task - launching, but the brief's acceptance points need the firstmate's hand:" >&2
        [ -z "$out" ] || printf '%s\n' "$out" >&2
        ;;
      *)
        echo "SPAWN-TOR ROT (abnahme): the ship brief for $task does not carry a usable acceptance block." >&2
        [ -z "$out" ] || printf '%s\n' "$out" >&2
        echo "  Ausweg: add the '## Abnahme (maschinenlesbar)' block to the brief (bin/fm-abnahme.sh --help), then respawn." >&2
        return 1
        ;;
    esac
  fi

  return 0
}

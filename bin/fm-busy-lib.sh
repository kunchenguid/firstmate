#!/usr/bin/env bash
# fm-busy-lib.sh - the ONE owner of firstmate's semantic busy-state contract.
#
# Design source: the captain-approved semantic busy-state redesign
# (2026-07-28): each harness adapter reports turn lifecycle through a
# machine-readable semantic source it owns, classification always exposes
# which source produced it, and missing, malformed, stale, unsupported, or
# unverified semantic data is UNKNOWN - never idle. Endpoint death is the only
# process-level override and yields dead, never busy. Child processes, CPU,
# process sleep state, marker mtimes, and the old global UI-regex OR are not
# state signals here; state/<id>.turn-ended files remain wake NOTIFICATIONS
# owned by the watcher, not current-state truth.
#
# Record file: state/<id>.busy-state - exactly one line, atomically replaced
# by bin/fm-busy-event.sh (the only writer):
#
#   v1 gen=<token> seq=<uint> state=<busy|idle|unknown> source=<token> event=<token> ts=<epoch>
#
# Gen sidecar: state/<id>.busy-gen - one token minted when the task's busy
# wiring is armed (fm-spawn, or a documented recovery re-arm). Every event
# must present the current gen; an event or record carrying any other gen is
# a stale incarnation and is rejected (written events) or classified unknown
# (read records). seq is a strictly increasing integer per gen, advanced
# under the writer's lock, so an out-of-order apply can never regress a
# newer record.
#
# Semantic sources written by adapters (fm_busy_sources_for_harness owns the
# per-harness trust table; a record whose source is not trusted for the
# task's recorded harness classifies unknown, so one adapter's writer can
# never classify another adapter):
#   pi-ext           Pi/pi-signed per-task extension (agent_start/agent_settled)
#   opencode-plugin  OpenCode per-task plugin (session.status)
#   claude-hook      Claude lifecycle hooks (UserPromptSubmit/Stop/StopFailure/SessionEnd)
#   codex-hook, codex-appserver  reserved: Codex, gated by
#                    fm_busy_codex_semantic_source
#   kimi-wire, kimi-hook  reserved: standalone Kimi, gated by fm_busy_kimi_verified
# Firstmate-owned sources accepted for every converted adapter:
#   fm-spawn         the launch-brief turn seeded at spawn
#   fm-interrupt     a firstmate-controlled interruption of the worker
#   fm-recovery      a documented recovery reset after relaunch
# Classifier-only sources (never written into a record):
#   endpoint-gone, herdr-native, grok-regex, missing, malformed,
#   gen-mismatch, source-mismatch, kimi-unverified, codex-unverified,
#   capture-failed, no-target
#
# Classification (fm_busy_classify): busy | idle | unknown | dead, always
# with the producing source as the second token. Precedence:
#   1. dead endpoint (fm_busy_classify_live only) -> dead endpoint-gone
#   2. standalone Kimi before verification       -> unknown kimi-unverified
#   3. a valid, gen-matching, source-trusted record -> its state and source
#   4. no record at all: herdr's native busy verdict is trusted as busy
#      (generation state is sufficient for busy, not for idle), then the
#      Grok-only temporary regex fallback classifies a grok task from its
#      rendered tail, then unknown missing
#   5. malformed, stale, or untrusted records -> unknown, never a fallback
# The Grok arm is the ONLY rendered-text classification that survives the
# redesign, because Grok's structured lifecycle was not credited-live-verified
# in the approved audit; it is scoped to harness=grok and can never classify
# another adapter. The delivery guards in bin/fm-tmux-lib.sh match rendered
# footers for submit acknowledgement and away-mode supervisor injection only;
# neither is a recorded worker state source.
#
# Codex negotiation (fm_busy_codex_appserver_observable,
# fm_busy_codex_hooks_verified): the approved contract prefers Codex's
# app-server turn lifecycle with capability negotiation, and sanctions its
# stable lifecycle hooks as the intermediate. Neither is usable on the
# installed binary, so Codex classifies unknown codex-unverified rather than
# falling back to idle, and fm-spawn installs no Codex busy wiring.
# docs/verification/supervision.md owns the evidence for both probes.
#
# Sourcing: set -u and set -e safe; no subshell-unfriendly globals.

FM_BUSY_LIB_VERSION=v1

# Standalone-Kimi verification gate. Empty means no installed Kimi version
# has passed live verification, so every standalone Kimi task classifies
# unknown kimi-unverified and fm-spawn wires no Kimi busy events. Kimi's
# rendered moon-phase spinner is deliberately NOT a state source here: the
# approved redesign forbids inventing a Kimi UI signature, and that spinner
# is locale- and emoji-font-sensitive.
#
# Preferred source, in order: Wire mode's JSON-RPC `prompt` request lifetime,
# whose outstanding request exactly brackets a turn and returns finished,
# cancelled, or max_steps_reached (so it covers interruption, which `Stop`
# does not); then the documented lifecycle hooks, which must include
# `Interrupt` because Kimi documents that `Stop` does not fire on interrupts.
#
# To open the gate: install Kimi, live-verify the chosen source brackets a
# real turn on a firstmate-launched worker including the interrupt path,
# record the version, exact commands, and observed output in
# docs/verification/supervision.md, add the verified version string(s) here,
# and land the wiring in fm-spawn behind this same gate in the same change.
FM_BUSY_KIMI_VERIFIED_VERSIONS=""

fm_busy_kimi_verified() {
  [ -n "$FM_BUSY_KIMI_VERIFIED_VERSIONS" ]
}

# fm_busy_codex_appserver_observable: capability/version negotiation for the
# Codex app-server turn lifecycle. Returns 0 only when a pane worker's turns
# are observable through the app-server protocol on the installed binary.
# codex-cli 0.145.0 verdict (live, 2026-07-28): NOT observable. The v2
# protocol does define the needed turn lifecycle (turn/started plus a
# turn/completed status of completed, interrupted, failed, or inProgress),
# but an interactive TUI worker neither starts nor attaches to the
# app-server daemon, and `codex app-server daemon start` refuses outside the
# managed standalone install, so no client can observe a pane worker's turns.
fm_busy_codex_appserver_observable() {
  return 1
}

# fm_busy_codex_hooks_verified: the sanctioned intermediate - Codex's stable
# hooks engine (UserPromptSubmit to open a turn, Stop and SessionEnd to close
# it). Returns 0 only once those hooks are live-verified to fire for a
# firstmate-launched worker. codex-cli 0.145.0 verdict (live, 2026-07-28):
# NOT verified. Firstmate-written project hooks under <worktree>/.codex/
# never fired in an interactive pane whose directory trust was granted, nor
# under `codex exec`, in either case with --dangerously-bypass-hook-trust,
# while global hooks fired in the same runs. Codex additionally exposes no
# StopFailure hook, so an API-error turn end would need separate coverage
# even after the discovery problem is solved.
fm_busy_codex_hooks_verified() {
  return 1
}

# fm_busy_codex_semantic_source: 0 when ANY verified Codex semantic source
# exists. fm-spawn arms and wires Codex only behind this gate, and the
# classifier reports unknown codex-unverified until it opens.
fm_busy_codex_semantic_source() {
  fm_busy_codex_appserver_observable || fm_busy_codex_hooks_verified
}

fm_busy_record_path() {  # <state-dir> <id>
  printf '%s/%s.busy-state' "$1" "$2"
}

fm_busy_gen_path() {  # <state-dir> <id>
  printf '%s/%s.busy-gen' "$1" "$2"
}

# fm_busy_token_valid: conservative token charset shared by gen, source, and
# event fields. Anything else is malformed.
fm_busy_token_valid() {  # <value>
  case "${1:-}" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# fm_busy_current_gen: the task's armed gen token, or failure when the busy
# contract has never been armed for this task.
fm_busy_current_gen() {  # <state-dir> <id>
  local gen_file gen
  gen_file=$(fm_busy_gen_path "$1" "$2")
  [ -f "$gen_file" ] || return 1
  IFS= read -r gen < "$gen_file" 2>/dev/null || gen=
  fm_busy_token_valid "$gen" || return 1
  printf '%s' "$gen"
}

# fm_busy_sources_for_harness: the semantic sources trusted to classify a
# task recorded with <harness>. One line, space-separated, possibly empty.
# The firstmate-owned sources are appended for every converted adapter.
# Grok deliberately trusts nothing: it has no semantic writer yet, and its
# temporary rendered-tail fallback lives in the classifier, not in records.
fm_busy_sources_for_harness() {  # <harness>
  local adapter=
  case "${1:-}" in
    claude*) adapter=claude-hook ;;
    codex*)
      fm_busy_codex_semantic_source || { printf ''; return 0; }
      adapter='codex-hook codex-appserver'
      ;;
    opencode*) adapter=opencode-plugin ;;
    pi|pi-signed) adapter=pi-ext ;;
    kimi*)
      fm_busy_kimi_verified || { printf ''; return 0; }
      adapter='kimi-wire kimi-hook'
      ;;
    *) printf ''; return 0 ;;
  esac
  printf '%s fm-spawn fm-interrupt fm-recovery' "$adapter"
}

fm_busy_source_trusted() {  # <harness> <source>
  local trusted
  trusted=$(fm_busy_sources_for_harness "$1")
  case " $trusted " in
    *" $2 "*) return 0 ;;
  esac
  return 1
}

# fm_busy_record_read: parse and validate state/<id>.busy-state against the
# armed gen. Prints "<state> <source> <event> <seq>" for a valid record.
# Non-zero returns name the reason on stdout instead:
#   missing      no record file (or no armed gen and no record)
#   malformed    unparseable line, bad tokens, or a missing armed gen for an
#                existing record
#   gen-mismatch a record from a stale incarnation
fm_busy_record_read() {  # <state-dir> <id>
  local state=$1 id=$2 rec gen line extra ver f
  local r_gen='' r_seq='' r_state='' r_source='' r_event='' r_ts=''
  rec=$(fm_busy_record_path "$state" "$id")
  if [ ! -f "$rec" ]; then
    printf 'missing'
    return 1
  fi
  if ! gen=$(fm_busy_current_gen "$state" "$id"); then
    # A record without an armed gen has no incarnation to bind to.
    printf 'malformed'
    return 1
  fi
  # shellcheck disable=SC2034 # extra exists only to prove the record is one line
  { IFS= read -r line && ! IFS= read -r extra; } < "$rec" 2>/dev/null || {
    printf 'malformed'
    return 1
  }
  # `read -a` rather than `set --`: it never glob-expands a field and never
  # touches the caller's positional parameters or shell options.
  local -a fields
  IFS=' ' read -r -a fields <<< "$line"
  ver=${fields[0]:-}
  [ "$ver" = "$FM_BUSY_LIB_VERSION" ] || { printf 'malformed'; return 1; }
  for f in "${fields[@]:1}"; do
    case "$f" in
      gen=*) r_gen=${f#gen=} ;;
      seq=*) r_seq=${f#seq=} ;;
      state=*) r_state=${f#state=} ;;
      source=*) r_source=${f#source=} ;;
      event=*) r_event=${f#event=} ;;
      ts=*) r_ts=${f#ts=} ;;
      *) printf 'malformed'; return 1 ;;
    esac
  done
  fm_busy_token_valid "$r_gen" || { printf 'malformed'; return 1; }
  fm_busy_token_valid "$r_source" || { printf 'malformed'; return 1; }
  fm_busy_token_valid "$r_event" || { printf 'malformed'; return 1; }
  case "$r_seq" in ''|*[!0-9]*) printf 'malformed'; return 1 ;; esac
  case "$r_ts" in ''|*[!0-9]*) printf 'malformed'; return 1 ;; esac
  case "$r_state" in busy|idle|unknown) : ;; *) printf 'malformed'; return 1 ;; esac
  if [ "$r_gen" != "$gen" ]; then
    printf 'gen-mismatch'
    return 1
  fi
  printf '%s %s %s %s' "$r_state" "$r_source" "$r_event" "$r_seq"
}

# fm_busy_grok_tail_busy: the Grok-only temporary rendered-tail fallback.
# Consumes the tail on stdin; 0 when Grok's verified busy signature matches.
# FM_BUSY_REGEX still globally overrides the signature, mirroring the
# historical operator escape hatch.
fm_busy_grok_tail_busy() {
  grep -v '^[[:space:]]*$' | tail -12 \
    | grep -qiE "${FM_BUSY_REGEX:-${FM_TMUX_GROK_BUSY_REGEX_DEFAULT:-Ctrl\\+c:cancel}}"
}

# fm_busy_classify: semantic classification for a task whose endpoint the
# caller has already established as present. Prints "<verdict> <source>":
# busy|idle|unknown plus the producing source (see header). Never probes
# process state. <tail40> is optional pre-captured plain output used only by
# the Grok arm; when absent the Grok arm captures through fm_backend_capture
# if available, else reports unknown capture-failed.
fm_busy_classify() {  # <backend> <target> <harness> <id> <state-dir> [tail40]
  local backend=$1 target=$2 harness=$3 id=$4 state=$5 tail40=${6-}
  local out rc r_state r_source native
  case "$harness" in
    kimi*)
      if ! fm_busy_kimi_verified; then
        printf 'unknown kimi-unverified'
        return 0
      fi
      ;;
    codex*)
      if ! fm_busy_codex_semantic_source; then
        printf 'unknown codex-unverified'
        return 0
      fi
      ;;
  esac
  out=$(fm_busy_record_read "$state" "$id") && rc=0 || rc=$?
  if [ "$rc" = 0 ]; then
    r_state=${out%% *}
    out=${out#* }
    r_source=${out%% *}
    if fm_busy_source_trusted "$harness" "$r_source"; then
      printf '%s %s' "$r_state" "$r_source"
    else
      printf 'unknown source-mismatch'
    fi
    return 0
  fi
  case "$out" in
    malformed|gen-mismatch)
      printf 'unknown %s' "$out"
      return 0
      ;;
  esac
  # No record at all. A native herdr busy verdict is semantic enough to trust
  # for BUSY (streaming means a turn is running); native idle is narrower
  # than turn state (a long foreground tool call reads idle) and stays
  # unknown here.
  if [ "$backend" = herdr ] && command -v fm_backend_busy_state >/dev/null 2>&1; then
    native=$(fm_backend_busy_state "$backend" "$target" 2>/dev/null || true)
    if [ "$native" = busy ]; then
      printf 'busy herdr-native'
      return 0
    fi
  fi
  case "$harness" in
    grok*)
      if [ -z "$tail40" ]; then
        if command -v fm_backend_capture >/dev/null 2>&1; then
          tail40=$(fm_backend_capture "$backend" "$target" 40 2>/dev/null) || {
            printf 'unknown capture-failed'
            return 0
          }
        else
          printf 'unknown capture-failed'
          return 0
        fi
      fi
      if printf '%s' "$tail40" | fm_busy_grok_tail_busy; then
        printf 'busy grok-regex'
      else
        printf 'idle grok-regex'
      fi
      return 0
      ;;
  esac
  printf 'unknown missing'
}

# fm_busy_classify_live: fm_busy_classify behind the one process-level
# override - a gone endpoint is dead, never busy. Requires fm-backend.sh to
# be sourced for fm_backend_target_exists.
fm_busy_classify_live() {  # <backend> <target> <harness> <id> <state-dir> [expected-label]
  local backend=$1 target=$2 harness=$3 id=$4 state=$5 label=${6-}
  if [ -z "$target" ]; then
    printf 'unknown no-target'
    return 0
  fi
  if ! fm_backend_target_exists "$backend" "$target" "$label" 2>/dev/null; then
    printf 'dead endpoint-gone'
    return 0
  fi
  fm_busy_classify "$backend" "$target" "$harness" "$id" "$state"
}

# fm_busy_classify_meta: classify a task from its recorded metadata, so every
# consumer resolves backend, target, and harness the same way instead of
# re-deriving them. Requires fm-backend.sh to be sourced. <tail40> is
# optional pre-captured plain output reused by the Grok arm.
fm_busy_classify_meta() {  # <meta-file> <id> <state-dir> [tail40]
  local meta=$1 id=$2 state=$3 tail40=${4-} backend target harness
  [ -f "$meta" ] || { printf 'unknown missing'; return 0; }
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  harness=$(fm_meta_get "$meta" harness)
  if [ -z "$target" ]; then
    printf 'unknown no-target'
    return 0
  fi
  fm_busy_classify "$backend" "$target" "$harness" "$id" "$state" "$tail40"
}

# fm_busy_is_busy: boolean view for callers that only gate on provable
# activity. 0 iff the classification verdict is exactly busy; idle, unknown,
# and dead all return 1, so an unknown can never be silently promoted to
# either boolean pole - callers that must distinguish idle from unknown read
# the full classification instead.
fm_busy_is_busy() {  # <backend> <target> <harness> <id> <state-dir> [tail40]
  local verdict
  verdict=$(fm_busy_classify "$@")
  [ "${verdict%% *}" = busy ]
}
